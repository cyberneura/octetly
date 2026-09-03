import Foundation

/// Where the evidence for a row came from, and it is not evidence of the same strength.
///
/// An echo reply came from the address in question. An ARP cache entry says the kernel holds a
/// hardware address for it and has heard from that NIC recently — a weaker claim than it sounds,
/// because the timer it rests on is kept per NIC rather than per address, so a machine that has
/// moved to another address leaves the old row looking current (NeighbourCache has the detail).
/// Nothing else on a row distinguishes the two: a blank Ping column is equally what a host that
/// answered late looks like.
///
/// Not all of these can put a row on screen. `ndpCache` never does — it only ever adds addresses
/// to a row something else established, for the reason in NeighbourCache — so a row listing it
/// alongside nothing else cannot occur.
enum DiscoverySource: String, Sendable, Hashable, CaseIterable {
    case thisMac = "This Mac"
    case icmpEcho = "ICMP echo"
    case icmpv6Echo = "ICMPv6 echo"
    case arpCache = "ARP cache"
    case ndpCache = "NDP cache"
}

struct Device: Identifiable, Hashable, Sendable {
    /// Fixed when the row is created: the table's selection and the scan's own index are both
    /// keyed by it.
    let id: String
    /// nil for a host that only ever answered over IPv6. Never filled in afterwards — `id` would
    /// have to move with it, and the selected row would go out from under whoever selected it.
    let ipv4: String?
    /// Every address the host's NIC is known to answer on, routable ones first.
    private(set) var ipv6Addresses: [String] = []
    var macAddress: String = "—"
    var hostname: String = "—"
    var vendor: String = OUIDatabase.unknownVendor
    var dnsName: String = "—"
    var mdnsName: String = "—"
    var smbName: String = "—"
    var smbDomain: String = "—"
    var openPorts: Set<Int> = []
    var portScanState: PortScanState = .pending
    var latencyMilliseconds: Double?
    var discovery: Set<DiscoverySource> = []
    /// Filled in from AnnotationStore rather than by the scan.
    var customName: String = ""

    enum PortScanState: Sendable, Hashable {
        case pending
        case scanning
        case done
    }

    init(ipv4: String, macAddress: String = "—", vendor: String = OUIDatabase.unknownVendor,
         latencyMilliseconds: Double? = nil, discovery: Set<DiscoverySource> = []) {
        self.id = ipv4
        self.ipv4 = ipv4
        self.macAddress = macAddress
        self.vendor = vendor
        self.latencyMilliseconds = latencyMilliseconds
        self.discovery = discovery
    }

    /// A host reached over IPv6 alone. The row is keyed by the address it answered from, which
    /// stays in `ipv6Addresses` however many more the neighbour cache turns out to hold.
    init(ipv6 address: String, macAddress: String = "—", vendor: String = OUIDatabase.unknownVendor,
         discovery: Set<DiscoverySource> = []) {
        self.id = address
        self.ipv4 = nil
        self.ipv6Addresses = [address]
        self.macAddress = macAddress
        self.vendor = vendor
        self.discovery = discovery
    }

    mutating func add(ipv6 addresses: some Sequence<String>) {
        ipv6Addresses = IPv6.routableFirst(Set(ipv6Addresses).union(addresses))
    }

    var hasMACAddress: Bool { macAddress != "—" }
    var hasIPv6: Bool { !ipv6Addresses.isEmpty }
    var isLocalMachine: Bool { discovery.contains(.thisMac) }

    /// Whether an echo reply came back from this address, as opposed to the kernel resolving the
    /// address on the way to sending a request.
    ///
    /// Not necessarily a reply to a request of *ours*. The IPv4 socket is handed replies to other
    /// processes' requests too and accepts them on source address alone (see SweepResult); only
    /// the IPv6 side checks an identifier, and that is 16 bits. What this does mean either way is
    /// that something answered at this address, which is the question the row is asking.
    var answeredEcho: Bool {
        discovery.contains(.icmpEcho) || discovery.contains(.icmpv6Echo)
    }

    /// Listed in a fixed order rather than the set's, so the field does not reshuffle per scan.
    var discoverySummary: String {
        let sources = DiscoverySource.allCases.filter(discovery.contains)
        return sources.isEmpty ? "—" : sources.map(\.rawValue).joined(separator: ", ")
    }

    /// The address column, and what stands in for a name where there is none. A host with no IPv4
    /// address is shown at the IPv6 address it is most reachable at rather than at a blank.
    var displayAddress: String { ipv4 ?? ipv6Addresses.first ?? "—" }

    /// Where to open a socket to this device.
    ///
    /// `id` — the address the row was made for — and not the first of the ones its NIC is listed
    /// under. Those come from the neighbour cache, which can be most of a day out of date (see
    /// NeighbourCache), while `id` is the address this scan actually had a reason to open the row
    /// at. Timing or port-scanning one of the others would be measuring an address on no evidence.
    var reachableAddress: String { ipv4 ?? id }

    /// The address a name or a note is filed under when there is no MAC address to use instead.
    ///
    /// Not `displayAddress`: that leads with whichever address is most routable, while the key is
    /// fixed to the one the row was created at. Editors show this so that what they say the entry
    /// is filed under is what it is filed under.
    var annotationAddress: String { id }

    /// What a name and a note are filed under.
    ///
    /// A MAC address survives the host changing address, so it is the better key wherever there is
    /// one. Two kinds of row have none: a host reached through a router or a VPN, which nothing on
    /// this machine has a hardware address for, and one found by its answer to the IPv6 all-nodes
    /// probe that the neighbour cache had no entry for. Refusing to annotate either would rule out
    /// a whole class of device, so the address stands in. Callers surface which of the two keys was
    /// used, because an address-keyed note follows the address rather than the machine: DHCP hands
    /// it to something else and the note goes with it.
    var annotationKey: String { hasMACAddress ? "mac:\(macAddress)" : addressAnnotationKey }

    /// The key this device would have had before its MAC was known, so a scan that finds it with
    /// a MAC straight away can still pick up what an earlier one filed under the address.
    var addressAnnotationKey: String { "ip:\(id)" }

    var hasName: Bool { !customName.isEmpty || hostname != "—" }
    var hasVendor: Bool {
        vendor != OUIDatabase.unknownVendor && vendor != OUIDatabase.randomizedVendor
    }

    var displayName: String {
        if !customName.isEmpty { return customName }
        return hostname == "—" ? displayAddress : hostname
    }

    /// Sorting the table by the dotted string puts .10 before .9, so the column sorts on this.
    var addressOrder: AddressOrder {
        AddressOrder(ipv4: ipv4.flatMap(IPv4.number),
                     ipv6: ipv6Addresses.first.flatMap(IPv6.bytes) ?? [])
    }

    var latencySummary: String {
        guard let latencyMilliseconds else { return "—" }
        // Sub-millisecond replies are normal on a switched LAN, where 0.4 and 0.9 ms are a real
        // difference that one decimal place would round away.
        let digits = latencyMilliseconds < 10 ? 2 : 1
        return "\(latencyMilliseconds.formatted(.number.precision(.fractionLength(digits)))) ms"
    }

    /// Hosts that never answered sort as slower than any host that did — last ascending, first
    /// descending, which is the same place "no answer" belongs in both readings.
    var latencySortValue: Double { latencyMilliseconds ?? .infinity }

    var portSummary: String {
        switch portScanState {
        case .pending: "—"
        case .scanning: "Scanning…"
        case .done: openPorts.isEmpty ? "None open" : openPorts.sorted().map(String.init).joined(separator: ", ")
        }
    }

    func matches(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        return ([displayName, hostname, displayAddress, macAddress, vendor] + ipv6Addresses)
            .contains { $0.localizedCaseInsensitiveContains(text) }
    }
}

/// The address column's sort order across both families.
///
/// A row with no IPv4 address has no number to sort among the IPv4 ones, so every one of them goes
/// after every IPv4 row, ordered by address among themselves. Ascending or descending, the rows
/// with an address of the kind the column is named for stay together.
struct AddressOrder: Comparable, Hashable, Sendable {
    let ipv4: UInt32?
    let ipv6: [UInt8]

    static func < (left: Self, right: Self) -> Bool {
        switch (left.ipv4, right.ipv4) {
        case let (leftValue?, rightValue?): leftValue < rightValue
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil): left.ipv6.lexicographicallyPrecedes(right.ipv6)
        }
    }
}
