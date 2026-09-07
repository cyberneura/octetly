import Darwin
import Foundation

/// Sweeps IPv4 addresses with ICMP echo requests over a single unprivileged datagram socket.
///
/// macOS lets any process open SOCK_DGRAM/IPPROTO_ICMP, so a sweep does not need to fork and exec
/// one ping(8) per address — that spawn cost, not the network, is what made a wide range take
/// minutes. The sweep itself is `EchoPinger`'s; this is the IPv4 packet and nothing else.
///
/// Measured against this project's own LAN, and the source for the figures quoted elsewhere:
/// a burst of 254 requests comes back at around 24 ms per host where the same hosts answer a
/// spaced request in about 5 (ping(8) reports 3–6 ms for them). Over a VPN-routed /24 a burst
/// reached 8 of 16 live hosts, while probing those same addresses one at a time reached every
/// one of them.
final class ICMPPinger: EchoPinger, @unchecked Sendable {
    /// How many addresses to send to before pausing to read replies.
    ///
    /// Each window costs its own reply wait, so the count of windows — not the count of packets —
    /// is what sets the floor on a sweep's runtime. A fixed window would cut a /16 into 256 of
    /// them and spend a minute waiting; counting by range keeps one to at most ~16 windows while
    /// still splitting a small range finely enough that rows appear as they are found.
    ///
    /// `pacing` is what keeps the second half of that true once a pass is spread out, and it is
    /// allowed to raise the window count past that ~16. Rows and the progress bar only move when a
    /// window closes, and a window of 256 addresses paced at 25 ms spends over 7 s inside one call
    /// — which made a routed /24 a single window, so the list sat empty for that long and then
    /// filled all at once, three times over.
    ///
    /// Splitting is not free, and the cost is per window rather than per packet: one reply wait
    /// (`ScanEngine.windowReplyTimeout`, 50 ms) always, plus one `arp -anl` — measured at 20–40 ms —
    /// on each window that found something, which on a sparse range is fewer than all of them. A
    /// routed /24 goes from 1 window to 7 and a /22 from 4 to 26, so between 0.3 s and 0.5 s a pass
    /// on the /24 and between 1.1 s and 2 s on the /22.
    ///
    /// The sends are the same addresses at the same gap, except across a window boundary, where the
    /// reply wait and any ARP read fall between two sends that would otherwise have been `pacing`
    /// apart. Nothing is sent more or less often for it; six gaps out of 253 are longer.
    static func sendWindow(for addresses: Int, pacing: TimeInterval) -> Int {
        let byCount = min(max(256, addresses / 16), 4096)
        guard pacing > 0 else { return byCount }
        return max(1, min(byCount, Int(maximumWindowSendTime / pacing)))
    }

    /// How long one window may spend sending before it closes so that its rows can appear.
    ///
    /// A responsiveness figure and nothing else — how long a list may sit unchanged before it reads
    /// as stuck — which is why it is not the reply timeout it used to sit next to at 1.5 s. Like
    /// every other gap here it is spent in requested sleep, so the window it sizes takes about a
    /// seventh longer than this: 40 addresses at 25 ms, measured at 1.14 s.
    static let maximumWindowSendTime: TimeInterval = 1.0

    init?() {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard descriptor >= 0 else { return nil }
        super.init(descriptor: descriptor)
    }

    override func send(to address: String, sequence: UInt16) {
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, address, &destination.sin_addr) == 1 else { return }
        sendDatagram(Self.echoRequest(sequence: sequence), to: &destination)
    }

    override func receive() -> (address: String, arrival: DispatchTime)? {
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            var from = sockaddr_in()
            guard let count = receiveDatagram(into: &buffer, from: &from) else { return nil }
            let arrival = DispatchTime.now()
            guard count > 0 else { continue }
            guard isEchoReply(buffer, count: count) else { continue }
            return (IPv4.string(UInt32(bigEndian: from.sin_addr.s_addr)), arrival)
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
    // back; replies are accepted on source address alone. That is a choice, not an oversight.
    //
    // Checking it would work: the kernel does not rewrite the identifier on the way out, which is
    // the whole basis of ICMPv6Pinger doing exactly that. But this socket is handed replies to
    // other processes' requests (see SweepResult), and one of those arriving from an address
    // inside the range is still evidence that something is at that address — which is the
    // question this sweep exists to answer. Filtering them out would discard it. The range the
    // caller applies is left to do the excluding instead: it removes the addresses nobody asked
    // about and keeps every one that answered, whoever it answered.
    //
    // What that costs is the round-trip time, which is timed against this sweep's last send to
    // the address and may belong to another request entirely. EchoPinger's `sentAt` reports that
    // figure as best-effort for this reason among others.
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
