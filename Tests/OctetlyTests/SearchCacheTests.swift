import Foundation
import Testing

@testable import Octetly

@Suite("Search cache and range policy")
struct SearchCacheTests {
    @Test func explicitRange() throws {
        let range = try ScanRange.parse("192.168.0.148")
        #expect(SearchPolicy.includes(Device(ipv4: "192.168.0.148"), explicitRange: range))
        #expect(!SearchPolicy.includes(Device(ipv4: "192.168.0.149"), explicitRange: range))
        #expect(!SearchPolicy.includes(Device(ipv6: "fe80::1%en0"), explicitRange: range))
        #expect(SearchPolicy.includes(Device(ipv6: "fe80::1%en0"), explicitRange: nil))
    }

    @Test func freshNames() {
        #expect(SearchPolicy.matchesName(DeviceIdentity(mdnsName: "millais.local"), query: "MILLAIS"))
        #expect(SearchPolicy.matchesName(DeviceIdentity(smbName: "MILLAIS"), query: "millais"))
        #expect(!SearchPolicy.matchesName(DeviceIdentity(dnsName: "millais.example.com"), query: "millais"))
        #expect(!SearchPolicy.matchesName(DeviceIdentity(mdnsName: "other.local"), query: "millais"))
        #expect(!SearchPolicy.matchesName(DeviceIdentity(dnsName: "millais.local", mdnsName: "other.local"), query: "millais"))
        #expect(!SearchPolicy.matchesName(DeviceIdentity(), query: "—"))
        #expect(!SearchPolicy.matchesName(DeviceIdentity(mdnsName: "millais.local"), query: ""))
    }

    @Test func persistenceAndInvalidation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SearchCache(directory: directory)
        let range = try ScanRange.parse("192.168.0.0/24")
        var device = Device(ipv4: "192.168.0.148")
        device.mdnsName = "millais.local"
        #expect(cache.load(query: "millais", range: range) == nil)
        cache.save([device], query: "millais", range: range)
        #expect(cache.load(query: "millais", range: range)?.map(\.ipv4) == ["192.168.0.148"])
        #expect(cache.load(query: "other", range: range) == nil)
        #expect(cache.load(query: "millais", range: range, explicitRange: false) == nil)
        #expect(cache.load(query: "millais", range: try ScanRange.parse("192.168.0.148")) == nil)
        cache.save([], query: "millais", range: range)
        #expect(cache.load(query: "millais", range: range) == nil)
        device.customName = "alias"
        cache.save([device], query: "alias", range: range)
        #expect(cache.load(query: "alias", range: range) == nil)
        cache.save([device, Device(ipv6: "fe80::1%en0")], query: "millais", range: range)
        #expect(cache.load(query: "millais", range: range) == nil)
        cache.save([device], query: "millais", range: range)
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasSuffix(".json") && (try? String(contentsOf: $0, encoding: .utf8))?.contains("millais.local") == true })
        try Data("invalid json".utf8).write(to: file)
        #expect(cache.load(query: "millais", range: range) == nil)
    }

    @Test func cacheOption() throws {
        #expect(try CLICommand.parse(["search", "millais", "--cache", "--address"])
            == .search(query: "millais", range: nil, output: .addresses, cache: true))
        #expect(throws: CLIError.unexpectedValue("--cache")) {
            try CLICommand.parse(["search", "--cache=true"])
        }
        #expect(throws: CLIError.unknownOption("--cache", command: "lookup")) {
            try CLICommand.parse(["lookup", "millais", "--cache"])
        }
    }
}
