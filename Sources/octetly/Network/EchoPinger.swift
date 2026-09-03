import Darwin
import Foundation

/// Who answered, and how quickly where that is known.
///
/// The two are separate because a macOS ICMP datagram socket is handed echo replies this process
/// never asked for — replies to another socket's requests, or to requests from a previous run
/// still in flight. Those addresses did answer something, so they count as alive, but there is no
/// send of ours to time them against and reporting 0 ms would be a fabrication.
struct SweepResult: Sendable {
    var responded: Set<String> = []
    var latencies: [String: Double] = [:]

    mutating func formUnion(_ other: SweepResult) {
        responded.formUnion(other.responded)
        latencies.merge(other.latencies) { existing, _ in existing }
    }

    func filter(_ isIncluded: (String) -> Bool) -> SweepResult {
        SweepResult(responded: responded.filter(isIncluded),
                    latencies: latencies.filter { isIncluded($0.key) })
    }
}

/// The half of a sweep that does not depend on whether ICMP or ICMPv6 is carrying it: the send
/// loop and its pacing, the reply drain, the errno cases, and Stop.
///
/// Subclasses supply the two operations that genuinely differ — building an echo request for one
/// address, and turning one datagram back into the address it came from. Everything else is here
/// because it is the same rule on both sockets, and a rule that lives in two places is one that
/// gets fixed in one of them.
///
/// Everything here blocks, so callers must reach it through BlockingWork.
class EchoPinger: @unchecked Sendable {
    let descriptor: Int32
    private var sequence: UInt16 = 0
    // When each address was last sent to, for turning a reply into a round-trip time. Keyed by
    // address rather than by sequence number, which makes every figure best-effort: what comes
    // out is the interval since this sweep last sent there, and three things can make that not
    // the interval the reply actually took. The timing pass re-sends to hosts that have already
    // answered. A reply to an earlier round can land during a later one. And the socket is handed
    // replies to other processes' requests as well, which belong to no send of ours at all (see
    // SweepResult). Matching on the sequence number would fix the first two and not the third,
    // and would cost the row its Ping value in every case it could not resolve — so the number is
    // the one available rather than the one proven.
    private var sentAt: [String: DispatchTime] = [:]
    private let stopLock = NSLock()
    private var stopped = false

    init(descriptor: Int32) {
        self.descriptor = descriptor
        var flags = fcntl(descriptor, F_GETFL, 0)
        flags |= O_NONBLOCK
        _ = fcntl(descriptor, F_SETFL, flags)

        // The default receive buffer is 8 KB — around 97 replies. A wide range where many hosts
        // answer at once would overflow it while the sweep is still sending, and the replies that
        // did not fit are simply gone.
        var receiveBuffer: Int32 = 1 << 20
        setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &receiveBuffer,
                   socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close(descriptor) }

    // MARK: - Supplied per protocol

    /// Sends one echo request, through `sendDatagram`.
    func send(to address: String, sequence: UInt16) {
        preconditionFailure("EchoPinger.send(to:sequence:) is for a subclass to supply")
    }

    /// One reply if the socket has one waiting, with the moment it was read. nil when empty.
    func receive() -> (address: String, arrival: DispatchTime)? {
        preconditionFailure("EchoPinger.receive() is for a subclass to supply")
    }

    // MARK: - The sweep

    /// Sends to every address, reading whatever has come back as it goes, then waits out `timeout`
    /// for the rest.
    ///
    /// `pacing` is the gap between sends. Zero saturates the socket, which a switched LAN absorbs;
    /// a tunnel or a rate-limited router does not, and drops most of the burst. The same host that
    /// is lost in a burst answers every time when probed on its own.
    func probe(_ addresses: some Sequence<String>, timeout: TimeInterval,
               pacing: TimeInterval = 0) -> SweepResult {
        var result = SweepResult()
        for address in addresses {
            if isStopped { return result }
            probeOne(address)
            // Read anything already back before sending the next one. Waiting until the whole
            // window has gone out charges every round-trip time with the rest of the send loop.
            collect(into: &result)
            if pacing > 0 {
                usleep(useconds_t(pacing * 1_000_000))
                collect(into: &result)
            }
        }
        result.formUnion(drain(for: timeout))
        return result
    }

    func probeOne(_ address: String) {
        sequence &+= 1
        sentAt[address] = DispatchTime.now()
        send(to: address, sequence: sequence)
    }

    /// Collects replies that came in after a window closed.
    ///
    /// Normally runs for the whole of `duration`: poll is given whatever is left of it, so there
    /// is no shorter idle gap that ends it sooner. It ends early on Stop, and on a poll that fails
    /// for a reason other than a signal.
    func drain(for duration: TimeInterval) -> SweepResult {
        var result = SweepResult()
        let deadline = Date().addingTimeInterval(duration)

        while true {
            collect(into: &result)
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, !isStopped else { break }
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, Int32(remaining * 1000))
            // A signal landing mid-wait is not the end of the replies. The deadline above is what
            // ends this loop; reading -1 as "nothing more is coming" would end a pass early and
            // lose every host that had not answered by then.
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { break }
        }
        return result
    }

    /// Stops the send loop at its next address.
    ///
    /// The loop is synchronous and runs on BlockingWork, where Task.isCancelled reads false, so
    /// cancelling the scan cannot reach it on its own. A paced pass spends seconds inside a single
    /// call — long enough for Stop to look ignored while probes keep going out.
    func stop() {
        stopLock.lock()
        stopped = true
        stopLock.unlock()
    }

    var isStopped: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopped
    }

    /// Drains every reply already queued, without waiting for more.
    private func collect(into result: inout SweepResult) {
        while let (address, arrival) = receive() {
            result.responded.insert(address)
            // One value per address per pass: the first that can be computed is kept, and further
            // replies still count as answers but do not re-time it. Nothing makes that first value
            // the more accurate of the two — `sentAt` above says why none of them is — it is that
            // a single figure has to be chosen, and re-timing on every duplicate would settle on
            // whichever reply happened to arrive last for no better reason.
            guard result.latencies[address] == nil,
                  let milliseconds = roundTrip(to: address, at: arrival) else { continue }
            result.latencies[address] = milliseconds
        }
    }

    private func roundTrip(to address: String, at arrival: DispatchTime) -> Double? {
        guard let sent = sentAt[address], arrival.uptimeNanoseconds >= sent.uptimeNanoseconds else {
            return nil
        }
        return Double(arrival.uptimeNanoseconds - sent.uptimeNanoseconds) / 1_000_000
    }

    // MARK: - Socket calls both sockets make the same way

    /// Sends one packet, retrying once where the failure says nothing about the host.
    ///
    /// ENOBUFS means the window outran the interface and EINTR means a signal landed in the middle
    /// of the call. Neither means the address is unreachable, and giving up on either would report
    /// the host as silent. The pause is for ENOBUFS alone — there is no buffer to drain after a
    /// signal, only a call to make again.
    final func sendDatagram<Address>(_ packet: [UInt8], to destination: inout Address) {
        for attempt in 0..<2 {
            let sent = packet.withUnsafeBytes { raw in
                withUnsafePointer(to: &destination) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { target in
                        sendto(descriptor, raw.baseAddress, raw.count, 0,
                               target, socklen_t(MemoryLayout<Address>.size))
                    }
                }
            }
            if sent > 0 { return }
            guard attempt == 0 else { return }
            switch errno {
            case ENOBUFS: usleep(2000)
            case EINTR: break
            default: return
            }
        }
    }

    /// Reads one datagram and the address it came from, or nil when the socket is empty.
    ///
    /// EINTR says nothing about whether more replies are coming; EAGAIN means the socket is empty
    /// right now. Treating either as the end of the sweep threw away every host that had not
    /// answered yet — the difference between finding 2 and 16.
    ///
    /// The retry is bounded, and both bounds matter: an unbounded one holds this thread inside a
    /// single call for as long as signals keep arriving, where neither the caller's deadline nor
    /// Stop can be looked at. Giving up loses nothing — `drain` polls and calls straight back in.
    final func receiveDatagram<Address>(into buffer: inout [UInt8], from source: inout Address) -> Int? {
        for _ in 0..<Self.interruptedRetryLimit {
            if isStopped { return nil }
            var length = socklen_t(MemoryLayout<Address>.size)
            let capacity = buffer.count
            let count = withUnsafeMutablePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    recvfrom(descriptor, &buffer, capacity, 0, address, &length)
                }
            }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            return count
        }
        return nil
    }

    /// How many times in a row a signal may interrupt one read before it gives up and lets the
    /// caller look at its deadline again.
    private static let interruptedRetryLimit = 16
}
