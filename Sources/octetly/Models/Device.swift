import Foundation

struct Device: Identifiable, Hashable, Sendable {
    var id: String { ipv4 }
    let ipv4: String
    var ipv6: String = "—"
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
    /// Filled in from AnnotationStore rather than by the scan.
    var customName: String = ""
    var isLocalMachine = false

    enum PortScanState: Sendable, Hashable {
        case pending
        case scanning
        case done
    }

    var hasMACAddress: Bool { macAddress != "—" }

    /// What a name and a note are filed under.
    ///
    /// A MAC address survives the host changing address, so it is the better key wherever there is
    /// one. There is none for a host reached through a router or a VPN — nothing on this machine
    /// can see it — and refusing to annotate those would rule out every routed segment, so the
    /// address stands in. Callers surface which of the two was used, because an address-keyed note
    /// follows the address rather than the machine: DHCP hands it to something else and the note
    /// goes with it.
    var annotationKey: String { hasMACAddress ? "mac:\(macAddress)" : "ip:\(ipv4)" }

    var hasName: Bool { !customName.isEmpty || hostname != "—" }
    var hasVendor: Bool {
        vendor != OUIDatabase.unknownVendor && vendor != OUIDatabase.randomizedVendor
    }

    var displayName: String {
        if !customName.isEmpty { return customName }
        return hostname == "—" ? ipv4 : hostname
    }

    /// Sorting the table by the dotted string puts .10 before .9, so the column sorts on this.
    var addressValue: UInt32 { IPv4.number(ipv4) ?? 0 }

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
        return [displayName, hostname, ipv4, macAddress, vendor]
            .contains { $0.localizedCaseInsensitiveContains(text) }
    }
}
