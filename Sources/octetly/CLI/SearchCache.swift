import CryptoKit
import Foundation

enum SearchPolicy {
    static func includes(_ device: Device, explicitRange: ScanRange?) -> Bool {
        guard let explicitRange else { return true }
        guard let address = device.ipv4 else { return false }
        return explicitRange.contains(address)
    }

    static func matchesName(_ identity: DeviceIdentity, query: String) -> Bool {
        !query.isEmpty && [identity.mdnsName, identity.smbName].contains {
            $0 != DNSName.none && $0.localizedCaseInsensitiveContains(query)
        }
    }
}

/// A separate file per query/range keeps independent searches from overwriting each other.
struct SearchCache {
    struct Entry: Codable, Equatable {
        let ipv4: String
        let name: String
        let timestamp: Date
    }

    private struct Record: Codable {
        let query: String
        let rangeID: String
        let explicitRange: Bool
        let entries: [Entry]
    }

    let directory: URL

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.cyberneura.octetly/search", isDirectory: true)) {
        self.directory = directory
    }

    private func url(query: String, range: ScanRange, explicitRange: Bool) -> URL {
        // Fixed-length keys keep long queries within the filesystem filename limit.
        let key = SHA256.hash(data: Data(query.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(range.id)-\(explicitRange)-\(key).json")
    }

    func load(query: String, range: ScanRange, explicitRange: Bool = true) -> [Entry]? {
        guard let data = try? Data(contentsOf: url(query: query, range: range, explicitRange: explicitRange)),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.query == query, record.rangeID == range.id, record.explicitRange == explicitRange, !record.entries.isEmpty,
              record.entries.allSatisfy({ range.contains($0.ipv4) }) else { return nil }
        return record.entries
    }

    func save(_ devices: [Device], query: String, range: ScanRange, explicitRange: Bool = true) {
        // Broad queries (address/vendor/custom name) and IPv6-only matches cannot be safely
        // revalidated by looking up an IPv4 host name. Leave those to the regular scan.
        let entries = devices.compactMap { device -> Entry? in
            let identity = DeviceIdentity(dnsName: device.dnsName, mdnsName: device.mdnsName,
                                          smbName: device.smbName, smbDomain: device.smbDomain)
            guard let ipv4 = device.ipv4, range.contains(ipv4),
                  SearchPolicy.matchesName(identity, query: query) else { return nil }
            return Entry(ipv4: ipv4, name: identity.hostname, timestamp: Date())
        }
        let record = Record(query: query, rangeID: range.id, explicitRange: explicitRange,
                            entries: entries.count == devices.count ? entries : [])
        // A cache is optional: absent, corrupt, or unwritable files fall back to the scan.
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(query: query, range: range, explicitRange: explicitRange), options: .atomic)
    }
}
