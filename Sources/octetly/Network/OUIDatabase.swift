import Foundation

struct OUIDatabase: Sendable {
    private let vendors: [String: String]

    init(csv: String) {
        var entries: [String: String] = [:]
        for line in csv.split(whereSeparator: { $0.isNewline }).dropFirst() {
            let fields = line.split(separator: ",", maxSplits: 1).map(String.init)
            if fields.count == 2 { entries[Self.normalizedPrefix(fields[0])] = fields[1] }
        }
        vendors = entries
    }

    func vendor(for macAddress: String) -> String {
        vendors[Self.normalizedPrefix(macAddress)] ?? "Unknown"
    }

    static func loadBundled() -> OUIDatabase {
        guard let url = Bundle.module.url(forResource: "oui", withExtension: "csv"),
              let csv = try? String(contentsOf: url, encoding: .utf8) else { return OUIDatabase(csv: "prefix,vendor") }
        return OUIDatabase(csv: csv)
    }

    private static func normalizedPrefix(_ value: String) -> String {
        String(value.uppercased().filter(\.isHexDigit).prefix(6))
    }
}
