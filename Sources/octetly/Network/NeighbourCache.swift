import Foundation

/// What the kernel already knows about the hosts on this segment, as arp(8) and ndp(8) print it.
///
/// Both caches are evidence a host answered something, and neither needs a packet of our own: a
/// host that drops every echo request still answers the address resolution the kernel does before
/// sending one, because that is handled below whatever is filtering ICMP.
///
/// Their standing is not the same, which is why only one of them is allowed to put a row on
/// screen — and the difference is what this scan does, not what the two protocols offer. The
/// sweep sends to every address in the range, so every ARP entry inside it has just been asked a
/// question, and `arp -anl` reports whether an answer came back. Nothing has asked the NDP entries
/// anything by the time they are read: the all-nodes probe goes to the group. IPv6 has the same
/// machinery — a unicast to a stale neighbour moves it through DELAY and PROBE, and `ndp -an`
/// shows the state — and the scan does unicast to IPv6 addresses later, in the timing pass and the
/// port scan, but both run after this table has been read and only reach rows a reply already
/// established. So at the moment it is read, an NDP entry sits at whatever it was, and it sits
/// there a long time: `ndp -an` here lists neighbours expiring in just under 24 hours, long enough
/// that a laptop taken home yesterday would still read as present today. So NDP is read for the
/// addresses and hardware addresses it carries, and never as the reason a device exists.
enum NeighbourCache {
    /// IPv4 address to hardware address, from `arp -anl`, skipping entries nothing has answered.
    ///
    /// The column that decides it is `Expire(I)`, the inbound one, and reading the outbound one
    /// instead is a mistake this made first. `Expire(O)` counts down from this Mac's last *send*
    /// to that address, so the sweep resets it by definition — it sends to every address in the
    /// range — whether or not anything is on the other end. `Expire(I)` counts from the last
    /// packet *received*, which is what an ARP reply to the sweep's own resolution is. Measured
    /// across one sweep, in-range entries went from 89 with both sides expired to 132 with both
    /// live, while 4 came out live outbound and still expired inbound: swept, answered nothing.
    ///
    /// Reading `-l` at all is why the state is visible: plain `arp -an` prints an entry the same
    /// way whichever side has expired, so parsing that form cannot tell the two apart.
    ///
    /// Two things this does not do, both of which follow from `Expire(I)` being kept per hardware
    /// address rather than per entry — the eight rows sharing one MAC here all read the same
    /// value, however far apart their `Expire(O)` values were.
    ///
    /// It does not catch a host that changed address. Its old row keeps a live inbound timer for
    /// as long as the same NIC keeps answering at its new one, so the ghost stays.
    ///
    /// And it drops a host that changed NIC without changing address, which the sweep cannot
    /// reach: the kernel spends its first few sends unicasting to the MAC it already has, and the
    /// sweep is over before it falls back to broadcast. Nothing distinguishes that from a machine
    /// that left. What keeps this from mattering often is that it only decides rows nothing else
    /// found — an address that answered an echo request is on the list from that alone.
    ///
    /// The columns are the address, the hardware address, the outbound and inbound expiry, and
    /// the interface. `(none)` is not `expired` and stays: it is what a permanent entry prints,
    /// which is what this Mac's own address has. An entry the kernel never resolved prints
    /// `(incomplete)`, and the header row prints a word where the address goes, so both fall out
    /// of the checks below rather than needing a rule of their own.
    static func parseARP(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 4,
                  IPv4.number(fields[0]) != nil,
                  let mac = normalizedMAC(fields[1]),
                  fields[3] != "expired" else { continue }
            result[fields[0]] = mac
        }
        return result
    }

    /// IPv6 addresses and the hardware addresses they belong to, from `ndp -an`.
    ///
    /// The columns are the address, the hardware address, and the interface. An entry the kernel
    /// never resolved prints `(incomplete)` in the second column, and the header line prints a
    /// word there, so both fall out of `normalizedMAC` rather than needing a check of their own.
    ///
    /// `interface` narrows the table to one link. ndp(8) reports every interface at once — this
    /// Mac's own awdl0 and llw0 entries among them, and whatever a VPN has left on a utun — and a
    /// neighbour on one of those is not what answered a probe sent on another.
    static func parseNDP(_ output: String, interface: String? = nil) -> NeighbourTable {
        var table = NeighbourTable()
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 3,
                  interface == nil || fields[2] == interface,
                  let mac = normalizedMAC(fields[1]),
                  let address = IPv6.canonical(fields[0]),
                  !IPv6.isMulticast(address) else { continue }
            table.add(address: address, mac: mac)
        }
        return table
    }

    /// One spelling per hardware address.
    ///
    /// arp(8) and ndp(8) both drop the leading zero of an octet, so the same NIC is `0:11:32:…`
    /// in one of them and `00:11:32:…` in the other, and the two would not compare equal. nil for
    /// anything that is not six octets, which is what keeps `(incomplete)` and ndp(8)'s header row
    /// out without a rule per case.
    static func normalizedMAC(_ value: String) -> String? {
        let octets = value.split(separator: ":", omittingEmptySubsequences: false)
        guard octets.count == 6 else { return nil }
        var padded: [String] = []
        for octet in octets {
            guard (1...2).contains(octet.count), octet.allSatisfy(\.isHexDigit) else { return nil }
            padded.append(octet.count == 1 ? "0\(octet.uppercased())" : octet.uppercased())
        }
        return padded.joined(separator: ":")
    }
}

/// The IPv6 half of the neighbour cache, readable in both directions: a reply arrives from an
/// address and has to be turned into a device, and a device already on screen has to be given
/// every address its NIC answers on.
struct NeighbourTable: Sendable, Equatable {
    private(set) var addressesByMAC: [String: [String]] = [:]
    private(set) var macByAddress: [String: String] = [:]

    var isEmpty: Bool { macByAddress.isEmpty }

    mutating func add(address: String, mac: String) {
        // A stale entry and a current one for the same address are both listed; the first is the
        // one ndp(8) considers current.
        guard macByAddress[address] == nil else { return }
        macByAddress[address] = mac
        addressesByMAC[mac, default: []].append(address)
    }

    func mac(for address: String) -> String? { macByAddress[address] }

    /// Every address that NIC answers on, routable ones first.
    func addresses(for mac: String) -> [String] {
        IPv6.routableFirst(addressesByMAC[mac] ?? [])
    }
}
