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

/// Sweeps addresses with ICMP echo requests over a single unprivileged datagram socket.
///
/// macOS lets any process open SOCK_DGRAM/IPPROTO_ICMP, so a sweep does not need to fork and exec
/// one ping(8) per address — that spawn cost, not the network, is what made a wide range take
/// minutes. Everything here blocks, so callers must reach it through BlockingWork.
///
/// Measured against this project's own LAN, and the source for the figures quoted elsewhere:
/// a burst of 254 requests comes back at around 24 ms per host where the same hosts answer a
/// spaced request in about 5 (ping(8) reports 3–6 ms for them). Over a VPN-routed /24 a burst
/// reached 8 of 16 live hosts, while probing those same addresses one at a time reached every
/// one of them.
final class ICMPPinger: @unchecked Sendable {
    /// How many addresses to send to before pausing to read replies.
    ///
    /// Each window costs its own reply wait, so the count of windows — not the count of packets —
    /// is what sets the floor on a sweep's runtime. A fixed window would cut a /16 into 256 of
    /// them and spend a minute waiting; this keeps any range to at most ~16 windows while still
    /// splitting a small one finely enough that rows appear as they are found.
    static func sendWindow(for addresses: Int) -> Int {
        min(max(256, addresses / 16), 4096)
    }

    private let descriptor: Int32
    private var sequence: UInt16 = 0
    // When each address was last sent to, for turning a reply into a round-trip time. Keyed by
    // address rather than by sequence number because a pass only re-sends to addresses that have
    // stayed silent, so the last send is always the one a reply belongs to.
    private var sentAt: [String: DispatchTime] = [:]
    private let stopLock = NSLock()
    private var stopped = false

    init?() {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard descriptor >= 0 else { return nil }
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

    /// Sends to every address, then reads replies until `timeout` elapses.
    ///
    /// `pacing` is the gap between sends. Zero saturates the socket, which a switched LAN absorbs;
    /// a tunnel or a rate-limited router does not, and drops most of the burst. The same host that
    /// is lost in a burst answers every time when probed on its own.
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

    private var isStopped: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopped
    }

    func probe(_ addresses: some Sequence<String>, timeout: TimeInterval, pacing: TimeInterval = 0) -> SweepResult {
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
    /// is no shorter idle gap that ends it sooner. It returns early only if poll fails.
    func drain(for duration: TimeInterval) -> SweepResult {
        var result = SweepResult()
        let deadline = Date().addingTimeInterval(duration)

        while true {
            collect(into: &result)
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, !isStopped else { break }
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&event, 1, Int32(remaining * 1000)) > 0 else { break }
        }
        return result
    }

    /// Drains every reply already queued, without waiting for more.
    private func collect(into result: inout SweepResult) {
        while let (address, arrival) = receive() {
            result.responded.insert(address)
            // A host can answer more than once; the first reply is the one that was not waiting
            // behind a retry, so it is the honest figure to keep.
            guard result.latencies[address] == nil,
                  let milliseconds = roundTrip(to: address, at: arrival) else { continue }
            result.latencies[address] = milliseconds
        }
    }

    /// One reply if the socket has one waiting, with the moment it was read. nil when empty.
    private func receive() -> (address: String, arrival: DispatchTime)? {
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let capacity = buffer.count
            let count = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    recvfrom(descriptor, &buffer, capacity, 0, address, &length)
                }
            }
            if count < 0 {
                // EINTR says nothing about whether more replies are coming; EAGAIN means the
                // socket is empty right now. Treating either as the end of the sweep threw away
                // every host that had not answered yet — the difference between finding 2 and 16.
                if errno == EINTR { continue }
                return nil
            }
            let arrival = DispatchTime.now()
            guard count > 0 else { continue }
            guard isEchoReply(buffer, count: count) else { continue }
            return (IPv4.string(UInt32(bigEndian: from.sin_addr.s_addr)), arrival)
        }
    }

    private func roundTrip(to address: String, at arrival: DispatchTime) -> Double? {
        guard let sent = sentAt[address], arrival.uptimeNanoseconds >= sent.uptimeNanoseconds else { return nil }
        return Double(arrival.uptimeNanoseconds - sent.uptimeNanoseconds) / 1_000_000
    }

    private func send(to address: String, sequence: UInt16) {
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, address, &destination.sin_addr) == 1 else { return }

        let packet = Self.echoRequest(sequence: sequence)
        for attempt in 0..<2 {
            let sent = packet.withUnsafeBytes { raw in
                withUnsafePointer(to: &destination) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { target in
                        sendto(descriptor, raw.baseAddress, raw.count, 0,
                               target, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent > 0 { return }
            // A full send buffer (ENOBUFS) means the window outran the interface, not that the
            // host is unreachable; the address would otherwise be reported as silent.
            guard attempt == 0, errno == ENOBUFS else { return }
            usleep(2000)
        }
    }

    /// A datagram ICMP socket hands back the IPv4 header along with the payload, so the ICMP type
    /// sits after IHL words rather than at offset zero.
    private func isEchoReply(_ buffer: [UInt8], count: Int) -> Bool {
        guard count >= 20, buffer[0] >> 4 == 4 else { return false }
        let headerLength = Int(buffer[0] & 0x0F) * 4
        guard headerLength >= 20, count >= headerLength + 8 else { return false }
        return buffer[headerLength] == 0
    }

    // The identifier is left at zero and neither it nor the sequence number is checked on the way
    // back; replies are accepted on source address alone. This socket is handed replies it never
    // asked for (see SweepResult), and the address filter the caller applies only removes the
    // ones from outside the range — a reply to another socket's request from an address inside
    // it is indistinguishable here, and gets timed against whatever this sweep last sent there.
    // Checking the identifier would not fix it either, since the ones we receive are not ours to
    // begin with. What survives is the question actually being asked: something answered at this
    // address.
    private static func echoRequest(sequence: UInt16) -> [UInt8] {
        var packet: [UInt8] = [8, 0, 0, 0, 0, 0, UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        packet.append(contentsOf: [UInt8](repeating: 0x61, count: 24))
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xFF)
        return packet
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { sum += UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return UInt16(truncatingIfNeeded: ~sum)
    }
}
