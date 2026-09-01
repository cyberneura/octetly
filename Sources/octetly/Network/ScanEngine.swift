import Darwin
import Foundation

struct ScanSnapshot: Sendable {
    let network: LocalNetwork
    let devices: [Device]
}

enum ScanEngine {
    static func scan(vendorDatabase: OUIDatabase) async -> ScanSnapshot? {
        guard let network = LocalNetwork.current() else { return nil }

        var responsive = Set<String>()
        // Work in batches to avoid creating hundreds of processes simultaneously.
        for batchStart in stride(from: 0, to: network.hosts.count, by: 32) {
            guard !Task.isCancelled else { return nil }
            let batch = network.hosts[batchStart..<min(batchStart + 32, network.hosts.count)]
            let found = await withTaskGroup(of: String?.self, returning: [String].self) { group in
                for host in batch {
                    group.addTask { await ping(host) ? host : nil }
                }
                var values: [String] = []
                for await value in group { if let value { values.append(value) } }
                return values
            }
            responsive.formUnion(found)
        }

        responsive.insert(network.address)
        let arp = await arpTable()
        responsive.formUnion(arp.keys.filter { network.hosts.contains($0) })

        let devices = await withTaskGroup(of: Device.self, returning: [Device].self) { group in
            for address in responsive {
                group.addTask {
                    await enrich(address: address, mac: arp[address], vendorDatabase: vendorDatabase)
                }
            }
            var result: [Device] = []
            for await device in group { result.append(device) }
            return result.sorted { addressValue($0.ipv4) < addressValue($1.ipv4) }
        }
        return ScanSnapshot(network: network, devices: devices)
    }

    static func parseARP(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        let expression = try? NSRegularExpression(pattern: #"\((\d+\.\d+\.\d+\.\d+)\) at ([0-9a-fA-F:]+)"#)
        for line in output.split(separator: "\n") {
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = expression?.firstMatch(in: text, range: range), match.numberOfRanges == 3,
                  let ipRange = Range(match.range(at: 1), in: text),
                  let macRange = Range(match.range(at: 2), in: text) else { continue }
            result[String(text[ipRange])] = normalizeMAC(String(text[macRange]))
        }
        return result
    }

    private static func ping(_ address: String) async -> Bool {
        let output = await CommandRunner.run("/sbin/ping", ["-c", "1", "-W", "300", address], timeout: 1)
        return output.contains("1 packets received") || output.contains("1 packets transmitted, 1 packets received")
    }

    private static func arpTable() async -> [String: String] {
        parseARP(await CommandRunner.run("/usr/sbin/arp", ["-an"], timeout: 2))
    }

    private static func enrich(address: String, mac: String?, vendorDatabase: OUIDatabase) async -> Device {
        async let names = reverseNames(address)
        async let smb = smbIdentity(address)
        async let ports = PortScanner.openPorts(host: address)
        async let ipv6 = ipv6Address(for: mac)
        let (resolvedNames, smbIdentity, openPorts, v6) = await (names, smb, ports, ipv6)
        let hostname = resolvedNames.dns == "—" ? resolvedNames.mdns : resolvedNames.dns
        return Device(
            ipv4: address,
            ipv6: v6,
            macAddress: mac ?? "—",
            hostname: hostname,
            vendor: mac.map(vendorDatabase.vendor(for:)) ?? "Unknown",
            dnsName: resolvedNames.dns,
            mdnsName: resolvedNames.mdns,
            smbName: smbIdentity.name,
            smbDomain: smbIdentity.domain,
            openPorts: openPorts
        )
    }

    private static func reverseNames(_ address: String) async -> (dns: String, mdns: String) {
        let output = await CommandRunner.run("/usr/bin/dig", ["+short", "-x", address], timeout: 2)
        let dns = output.split(separator: "\n").first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) } ?? "—"
        let mdns = dns.hasSuffix(".local") ? dns : "—"
        return (dns, mdns)
    }

    private static func smbIdentity(_ address: String) async -> (name: String, domain: String) {
        let output = await CommandRunner.run("/usr/bin/smbutil", ["status", address], timeout: 2)
        var name = "—", domain = "—"
        for line in output.split(separator: "\n") {
            let value = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard value.count == 2 else { continue }
            if value[0].localizedCaseInsensitiveContains("server") { name = value[1] }
            if value[0].localizedCaseInsensitiveContains("workgroup") || value[0].localizedCaseInsensitiveContains("domain") { domain = value[1] }
        }
        return (name, domain)
    }

    private static func ipv6Address(for mac: String?) async -> String {
        guard let mac else { return "—" }
        let output = await CommandRunner.run("/usr/sbin/ndp", ["-an"], timeout: 2)
        return output.split(separator: "\n").first { $0.localizedCaseInsensitiveContains(mac) }
            .flatMap { $0.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) } ?? "—"
    }

    private static func normalizeMAC(_ value: String) -> String {
        value.split(separator: ":").map { $0.count == 1 ? "0\($0)" : String($0) }.joined(separator: ":").uppercased()
    }

    private static func addressValue(_ address: String) -> UInt32 {
        address.split(separator: ".").reduce(0) { ($0 << 8) + (UInt32($1) ?? 0) }
    }
}
