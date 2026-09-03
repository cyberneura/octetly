import Darwin
import Foundation

/// Sweeps IPv6 with ICMPv6 echo requests over a single unprivileged datagram socket.
///
/// This is the one probe that finds a host nothing else on this Mac has an address for. `ff02::1`
/// is the all-nodes multicast group: one packet reaches every IPv6 node on the segment, and a node
/// that answers does so from its own address, so a host that ignores every IPv4 echo request — or
/// has no IPv4 address at all — still names itself. Answering is a SHOULD rather than a MUST in
/// RFC 4443, so silence here is not proof of absence.
///
/// macOS lets any process open SOCK_DGRAM/IPPROTO_ICMPV6, where the raw equivalent is EPERM, and
/// fills the checksum in on the way out. That matters more than it does for IPv4: an ICMPv6
/// checksum covers a pseudo-header containing the source address, and which source address a
/// multicast send leaves from is the routing table's choice, not the sender's.
///
/// How many rounds are worth sending, and what was measured to decide it, is at
/// `ScanEngine.ipv6Rounds` — the one place that count is set.
final class ICMPv6Pinger: EchoPinger, @unchecked Sendable {
    static let allNodesGroup = "ff02::1"

    /// Picked per socket, so that a reply to some other program's ping6 is unlikely to be counted
    /// as a host this one found. Sixteen bits and one draw, so two programs collide once in
    /// 65535; that is the whole of the protection, and it is worth having only because the
    /// alternative is none.
    ///
    /// The IPv4 socket deliberately does not check one, for the reason ICMPPinger gives: a reply
    /// from inside the range it was handed is evidence a host is there whoever's request drew it,
    /// and the range is what excludes everything else. An all-nodes sweep has no range to exclude
    /// with — every IPv6 node on the segment is in scope — so the identifier is the only thing
    /// separating an answer to this sweep from an answer to a ping6 someone is running against a
    /// host on the far side of the internet.
    ///
    /// Nothing else here would catch that: the kernel neither rewrites the identifier on the way
    /// out nor demultiplexes on it. A second ICMPv6 socket that had sent nothing at all was handed
    /// every one of the 33 replies to this one's request when that was measured.
    ///
    /// Per socket and not per pass, which is why the timing pass opens its own: an answer to the
    /// multicast rounds that arrives late would otherwise reach the timing pass's socket, match
    /// its identifier, and be timed against whatever that pass last sent to the same address.
    /// `identifier(after:)` gives the second socket a value that cannot equal the first's, which
    /// two independent draws would do at the same one in 65535.
    private let identifier: UInt16

    /// An identifier that is not `other`, for a second socket that has to be told apart from it.
    static func identifier(after other: UInt16) -> UInt16 {
        let next = other &+ 1
        return next == 0 ? 1 : next
    }

    var currentIdentifier: UInt16 { identifier }

    init?(identifier: UInt16 = UInt16.random(in: 1...UInt16.max)) {
        let descriptor = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
        guard descriptor >= 0 else { return nil }
        self.identifier = identifier
        super.init(descriptor: descriptor)

        // Pass echo replies and nothing else. A zeroed filter is ICMP6_FILTER_SETBLOCKALL and the
        // one bit set here is ICMP6_FILTER_SETPASS; the macros themselves do not survive the C
        // importer. Without the filter this socket is handed our own request straight back — the
        // kernel loops a multicast send back to the sending host, which is a node on the segment
        // like any other — along with the neighbour solicitations a busy segment is full of.
        var filter = icmp6_filter()
        withUnsafeMutableBytes(of: &filter.icmp6_filt) { raw in
            let words = raw.bindMemory(to: UInt32.self)
            words[Int(ICMP6_ECHO_REPLY) >> 5] |= 1 << (UInt32(ICMP6_ECHO_REPLY) & 31)
        }
        setsockopt(descriptor, IPPROTO_ICMPV6, ICMP6_FILTER, &filter,
                   socklen_t(MemoryLayout<icmp6_filter>.size))
    }

    /// One request to the all-nodes group, and every host that answers it within `timeout`.
    ///
    /// The zone is what decides which segment this goes out on: `ff02::1` names the same group on
    /// every interface, so it means nothing without one.
    ///
    /// No round-trip time comes out of this, and none would be worth showing. Sends are recorded
    /// against the address they went to, which here is the group rather than any host, so nothing
    /// a reply arrives from has a send to be timed against — `latencies` comes back empty on its
    /// own. It is worth knowing that it should: the replies to a single multicast request were
    /// measured spread between 0.3 ms and over 100 ms from hosts that answer a unicast request in
    /// single-digit milliseconds, and what that spread is made of — a delay the host inserted, a
    /// wireless duty cycle, a queue — is not something this can tell apart. The spaced unicast
    /// pass in ScanEngine is what reports how far away a host is.
    func probeAllNodes(on interface: String, timeout: TimeInterval) -> SweepResult {
        guard !isStopped else { return SweepResult() }
        probeOne("\(Self.allNodesGroup)%\(interface)")
        return SweepResult(responded: drain(for: timeout).responded)
    }

    override func send(to address: String, sequence: UInt16) {
        guard var destination = IPv6.socketAddress(address) else { return }
        sendDatagram(Self.echoRequest(identifier: identifier, sequence: sequence), to: &destination)
    }

    override func receive() -> (address: String, arrival: DispatchTime)? {
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            var from = sockaddr_in6()
            guard let count = receiveDatagram(into: &buffer, from: &from) else { return nil }
            let arrival = DispatchTime.now()
            // Unlike the IPv4 datagram socket, which is handed the IP header as well, this one
            // hands back the ICMPv6 message on its own: type, code, checksum, identifier, then
            // the sequence number. The identifier is what separates an answer to this sweep from
            // one to a ping6 running beside it.
            guard count >= 8, buffer[0] == UInt8(ICMP6_ECHO_REPLY),
                  UInt16(buffer[4]) << 8 | UInt16(buffer[5]) == identifier else { continue }
            guard let address = IPv6.numericAddress(from) else { continue }
            return (address, arrival)
        }
    }

    /// The checksum stays zero for the reason in the type comment: the kernel is the only party
    /// that knows the source address it will be computed over.
    private static func echoRequest(identifier: UInt16, sequence: UInt16) -> [UInt8] {
        var packet: [UInt8] = [UInt8(ICMP6_ECHO_REQUEST), 0, 0, 0,
                               UInt8(identifier >> 8), UInt8(identifier & 0xFF),
                               UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        packet.append(contentsOf: [UInt8](repeating: 0x61, count: 24))
        return packet
    }
}
