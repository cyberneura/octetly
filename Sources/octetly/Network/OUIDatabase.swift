import Foundation

struct OUIDatabase: Sendable {
    static let unknownVendor = "Unknown"
    /// Not a vendor: the address says outright that no registry assigned it.
    static let randomizedVendor = "Randomized"

    private let vendors: [String: String]

    var count: Int { vendors.count }

    init(csv: String) {
        var entries: [String: String] = [:]
        for line in csv.split(whereSeparator: { $0.isNewline }).dropFirst() {
            let fields = line.split(separator: ",", maxSplits: 1).map(String.init)
            if fields.count == 2 { entries[Self.hexDigits(fields[0])] = fields[1] }
        }
        vendors = entries
    }

    /// Bit 0x02 of the first octet marks an address that was never handed out by the IEEE. Apple
    /// and Android both set one per network by default, so this is the common case on Wi-Fi and
    /// no table could ever name it.
    static func isLocallyAdministered(_ macAddress: String) -> Bool {
        guard let firstOctet = UInt8(hexDigits(macAddress).prefix(2), radix: 16) else { return false }
        return firstOctet & 0x03 == 0x02
    }

    func vendor(for macAddress: String) -> String {
        let digits = Self.hexDigits(macAddress)
        guard digits.count >= 6, let firstOctet = UInt8(digits.prefix(2), radix: 16) else {
            return Self.unknownVendor
        }
        // Bit 0x01 marks a group address — broadcast and multicast rows that arp(8) reports
        // alongside real neighbours. Checked first because they also carry the bit below.
        if firstOctet & 0x01 != 0 { return Self.unknownVendor }
        if Self.isLocallyAdministered(macAddress) { return Self.randomizedVendor }

        // Longest prefix wins: where the IEEE has sliced a 24-bit block into 28- or 36-bit
        // assignments, the 24-bit row names the registration authority rather than the vendor
        // actually holding the slice.
        for length in [9, 7, 6] where digits.count >= length {
            if let vendor = vendors[String(digits.prefix(length))] { return vendor }
        }
        return Self.unknownVendor
    }

    static func loadBundled() -> OUIDatabase {
        guard let url = Bundle.module.url(forResource: "oui", withExtension: "csv"),
              let csv = try? String(contentsOf: url, encoding: .utf8) else {
            return OUIDatabase(csv: "prefix,vendor")
        }
        return OUIDatabase(csv: csv)
    }

    private static func hexDigits(_ value: String) -> String {
        value.uppercased().filter(\.isHexDigit)
    }
}
