import Foundation

/// Runs a command-line command and returns the exit status.
///
/// 0 when every lookup found something or the search matched at least one host, 1 when not, and
/// 2 for a command that could not be run at all — the same split grep(1) makes, so that a script
/// can tell "nothing there" from "did not look".
@MainActor
enum CLITool {
    static let usage = """
        usage: octetly lookup [--json] <name | address>...
               octetly search [--json] [--range <range>] [<word>]
               octetly version
               octetly --license

        lookup  A name is resolved to its IPv4 and IPv6 addresses by the system resolver
                (/etc/hosts, DNS, and mDNS on this Mac's own segment). An IPv4 address is
                named by reverse DNS, by the host's own mDNS responder asked directly, and by
                SMB, which works through a router or a VPN where multicast does not. An IPv6
                address is named by the system resolver alone.

        search  Scans a range the way the window does and prints the hosts whose name,
                address, MAC address or vendor contains <word>, or every host without one.
                Use this for a name the resolver cannot reach, such as a .local host on
                the far side of a VPN. Names set in the window are searched too.

        --range, -r  What to scan: 192.168.0.0/24, 192.168.0.1-192.168.0.99, or one
                     address. Defaults to this Mac's own network, capped at 1,024 addresses.
        --json       Print JSON instead of text.

        --license    Print Octetly's license and the third-party notices.

        Run with no arguments to open the window.
        """

    static func run(_ command: CLICommand) async -> Int32 {
        switch command {
        case .help:
            print(usage)
            return 0
        case .version:
            print("Octetly \(version)")
            return 0
        case .license:
            guard let text = Licenses.text() else {
                note("the license files are missing from this build; see \(Licenses.noticesURL.absoluteString)")
                return 2
            }
            print(text, terminator: "")
            return 0
        case .lookup(let targets, let json):
            return await lookup(targets, json: json)
        case .search(let query, let range, let json):
            return await search(query, in: range, json: json)
        }
    }

    static func note(_ message: String) {
        FileHandle.standardError.write(Data("octetly: \(message)\n".utf8))
    }

    /// The released app carries its version in Info.plist; `swift run` has no Info.plist to read.
    private static var version: String {
        BundledResource.app.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "(development build)"
    }

    // MARK: - lookup

    private struct LookupResult: Encodable {
        var query: String
        var kind: String
        var ipv4: [String]?
        var ipv6: [String]?
        var name: String?
        var dnsName: String?
        var mdnsName: String?
        var smbName: String?
        var smbDomain: String?
        /// What the system resolver calls an IPv6 address. The one source asked for one; see below.
        var resolverName: String?
        var failure: String?

        var found: Bool { !(ipv4 ?? []).isEmpty || !(ipv6 ?? []).isEmpty || name != nil }
    }

    private static func lookup(_ targets: [String], json: Bool) async -> Int32 {
        var results: [LookupResult] = []
        for target in targets {
            let result = await lookup(target)
            results.append(result)
            if !json { printLookup(result) }
        }
        if json, !printJSON(results) { return 2 }
        for result in results {
            if let failure = result.failure { note("could not resolve \(result.query): \(failure)") }
        }
        // A resolver that failed has said nothing about the name, which is not the same as saying
        // it has no address.
        if results.contains(where: { $0.failure != nil }) { return 2 }
        let missed = results.filter { !$0.found }
        if missed.contains(where: { $0.kind == "name" }) {
            note("the system resolver has no address for a name above. A .local name on the far "
                 + "side of a router or a VPN cannot be resolved this way; "
                 + "try `octetly search <word> --range <network>` instead.")
        }
        return missed.isEmpty ? 0 : 1
    }

    private static func lookup(_ target: String) async -> LookupResult {
        if IPv4.number(target) != nil {
            let identity = await ScanEngine.identity(of: target)
            return LookupResult(query: target, kind: "address",
                                name: present(identity.hostname),
                                dnsName: present(identity.dnsName),
                                mdnsName: present(identity.mdnsName),
                                smbName: present(identity.smbName),
                                smbDomain: present(identity.smbDomain))
        }
        if IPv6.isValid(target) {
            // Named the way a scan names an IPv6-only row: one getnameinfo, which is reverse DNS for
            // a routable address and mDNSResponder for one on this segment. The engine files that
            // under mDNS whichever it was, so it is reported here as the resolver's answer rather
            // than claimed for a source it may not have come from.
            let identity = await ScanEngine.identity(of: target)
            let name = present(identity.hostname)
            return LookupResult(query: target, kind: "address", name: name, resolverName: name)
        }
        let addresses = await BlockingWork.run { AddressResolver.addresses(of: target) }
        return LookupResult(query: target, kind: "name", ipv4: addresses.ipv4, ipv6: addresses.ipv6,
                            failure: addresses.failure)
    }

    private static func printLookup(_ result: LookupResult) {
        var rows: [(String, String)] = []
        if result.kind == "name" {
            rows += (result.ipv4 ?? []).map { ("IPv4", $0) }
            rows += (result.ipv6 ?? []).map { ("IPv6", $0) }
        } else {
            let names: [(String, String?)] = [("DNS", result.dnsName), ("mDNS", result.mdnsName),
                                              ("SMB", result.smbName), ("Workgroup", result.smbDomain),
                                              ("Resolver", result.resolverName)]
            rows = names.compactMap { label, value in value.map { (label, $0) } }
        }
        print(result.query)
        if rows.isEmpty { print(result.failure == nil ? "  not found" : "  lookup failed") }
        for (label, value) in rows {
            print("  \(label.padding(toLength: 10, withPad: " ", startingAt: 0))\(value)")
        }
    }

    // MARK: - search

    private struct SearchResult: Encodable {
        var ipv4: String?
        var ipv6: [String]
        var name: String?
        var customName: String?
        var dnsName: String?
        var mdnsName: String?
        var smbName: String?
        var smbDomain: String?
        var macAddress: String?
        var vendor: String?
        var latencyMilliseconds: Double?

        init(_ device: Device) {
            ipv4 = device.ipv4
            ipv6 = device.ipv6Addresses
            name = device.hasName ? device.displayName : nil
            customName = device.customName.isEmpty ? nil : device.customName
            dnsName = present(device.dnsName)
            mdnsName = present(device.mdnsName)
            smbName = present(device.smbName)
            smbDomain = present(device.smbDomain)
            macAddress = present(device.macAddress)
            vendor = knownVendor(of: device)
            latencyMilliseconds = device.latencyMilliseconds
        }
    }

    private static func search(_ query: String?, in chosen: ScanRange?, json: Bool) async -> Int32 {
        guard let range = chosen ?? LocalNetwork.current()?.autoRange else {
            note("no active IPv4 interface to take a range from; pass --range.")
            return 2
        }
        note("scanning \(range.summary)…")

        // Ports are never scanned here: nothing printed uses them, and on a busy range they cost
        // more than the rest of the scan put together.
        let settings = ScanSettings(portScanMode: .off)
        var devices: [String: Device] = [:]
        var identities: [String: DeviceIdentity] = [:]
        for await event in ScanEngine.events(range: range, vendorDatabase: OUIDatabase.loadBundled(),
                                             settings: settings) {
            switch event {
            case .devices(let list):
                // Each list is the engine's whole table so far, so the latest copy of a row wins.
                for device in list { devices[device.id] = device }
            case .identity(let id, let identity):
                identities[id] = identity
            case .progress, .ports, .finished:
                break
            }
        }

        // Read-only: the window's store consolidates keys as it goes, and a search is not the
        // place to rewrite what the window saved.
        let annotations = AnnotationStore()
        let hits = devices.values
            .map { device in
                var device = device
                if let identity = identities[device.id] {
                    device.dnsName = identity.dnsName
                    device.mdnsName = identity.mdnsName
                    device.smbName = identity.smbName
                    device.smbDomain = identity.smbDomain
                    device.hostname = identity.hostname
                }
                let named = annotations[device.annotationKey].name
                device.customName = named.isEmpty ? annotations[device.addressAnnotationKey].name : named
                return device
            }
            .filter { Self.matches($0, query) }
            .sorted { $0.addressOrder < $1.addressOrder }

        note("\(devices.count.formatted()) found, \(hits.count.formatted()) matching.")
        if json {
            guard printJSON(hits.map(SearchResult.init)) else { return 2 }
        } else {
            printTable(hits)
        }
        return hits.isEmpty ? 1 : 0
    }

    /// What the window's search field matches, and every name the scan found besides the one the
    /// row shows. A host is often known by one name to one person and another to the next — its SMB
    /// name, say, where DNS also has one and so takes the Name column.
    private static func matches(_ device: Device, _ query: String?) -> Bool {
        guard let query else { return true }
        return device.matches(query)
            || [device.dnsName, device.mdnsName, device.smbName]
                .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private static func printTable(_ devices: [Device]) {
        guard !devices.isEmpty else { return }
        let header = ["ADDRESS", "NAME", "MAC", "VENDOR", "IPV6"]
        let rows = devices.map { device in
            [device.ipv4 ?? "—", device.hasName ? device.displayName : "—", device.macAddress,
             knownVendor(of: device) ?? "—", device.ipv6Addresses.joined(separator: ", ")]
        }
        let widths = header.indices.map { column in
            ([header] + rows).map { $0[column].count }.max() ?? 0
        }
        for row in [header] + rows {
            let cells = row.indices.map { column in
                // The last column is left ragged, so a row does not end in a run of spaces.
                column == row.count - 1
                    ? row[column]
                    : row[column].padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }
            print(cells.joined(separator: "  "))
        }
    }

    // MARK: - Output

    /// false when nothing could be printed, so that the exit status does not report a result the
    /// caller never received.
    private static func printJSON(_ value: some Encodable) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            print(String(decoding: try encoder.encode(value), as: UTF8.self))
            return true
        } catch {
            note("could not write JSON: \(error.localizedDescription)")
            return false
        }
    }
}

/// nil for the "—" the scan uses to mean nothing was found, so JSON carries no placeholder.
private func present(_ value: String) -> String? {
    value == DNSName.none || value.isEmpty ? nil : value
}

/// The vendor, keeping `Randomized`. `Device.hasVendor` treats it as missing because the window
/// styles it like an unknown one, but it is a finding — the address was never assigned — and
/// `search Randomized` matches on it, so hiding it would leave rows with no visible reason.
private func knownVendor(of device: Device) -> String? {
    device.vendor == OUIDatabase.unknownVendor ? nil : device.vendor
}
