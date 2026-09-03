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
    /// them and spend a minute waiting; this keeps any range to at most ~16 windows while still
    /// splitting a small one finely enough that rows appear as they are found.
    static func sendWindow(for addresses: Int) -> Int {
        min(max(256, addresses / 16), 4096)
    }

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
