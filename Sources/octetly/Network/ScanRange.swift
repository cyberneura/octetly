import Foundation

struct ScanRange: Sendable, Hashable, Identifiable {
    // A hand-entered range is allowed to be far larger than an automatically detected one,
    // because typing it in is the act of asking for it. See LocalNetwork.autoHostLimit.
    static let maximumHostCount = 65_536

    let text: String
    let first: UInt32
    let last: UInt32

    // Two spellings of the same span (192.168.0.0/24 and 192.168.0.1-192.168.0.254) are the
    // same target, so the bounds identify a range rather than the text that produced it.
    var id: String { "\(first)-\(last)" }
    var count: Int { Int(last - first) + 1 }

    var summary: String {
        "\(IPv4.string(first)) – \(IPv4.string(last)) · \(count.formatted()) addresses"
    }

    func contains(_ address: String) -> Bool {
        guard let value = IPv4.number(address) else { return false }
        return value >= first && value <= last
    }

    func addressList() -> [String] {
        (first...last).map(IPv4.string)
    }

    // A Japanese IME produces U+301C or U+FF5E for the same key depending on the input source,
    // and both look like the wave dash the user typed, so neither can be the only one accepted.
    private static let separators: Set<Character> = ["-", "~", "\u{301C}", "\u{FF5E}", "\u{2013}", "\u{2014}"]

    static func parse(_ raw: String) throws -> ScanRange {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ScanRangeError.empty }
        if text.contains("/") { return try parseCIDR(text) }
        if let separator = text.first(where: separators.contains) {
            return try parseBounds(text, separator: separator)
        }
        guard let value = IPv4.number(text) else { throw ScanRangeError.malformedAddress(text) }
        return try make(text: text, first: value, last: value)
    }

    private static func parseCIDR(_ text: String) throws -> ScanRange {
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let addressText = parts[0].trimmingCharacters(in: .whitespaces)
        let prefixText = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        guard let address = IPv4.number(addressText) else { throw ScanRangeError.malformedAddress(addressText) }
        guard let prefix = Int(prefixText), (0...32).contains(prefix) else {
            throw ScanRangeError.malformedPrefix(prefixText)
        }

        // Shifting a UInt32 by 32 traps, so /0 cannot go through the same expression.
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
        let network = address & mask
        let broadcast = network | ~mask
        // A /31 or /32 has no network or broadcast address to skip (RFC 3021).
        let usesEdges = prefix >= 31
        return try make(text: text,
                        first: usesEdges ? network : network + 1,
                        last: usesEdges ? broadcast : broadcast - 1)
    }

    private static func parseBounds(_ text: String, separator: Character) throws -> ScanRange {
        let parts = text.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false)
        let lowText = parts[0].trimmingCharacters(in: .whitespaces)
        let highText = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        guard let low = IPv4.number(lowText) else { throw ScanRangeError.malformedAddress(lowText) }
        guard let high = IPv4.number(highText) else { throw ScanRangeError.malformedAddress(highText) }
        // Swapping the two silently would scan a span nobody asked for, so a reversed pair is
        // reported instead of repaired.
        guard low <= high else { throw ScanRangeError.reversed }
        return try make(text: text, first: low, last: high)
    }

    private static func make(text: String, first: UInt32, last: UInt32) throws -> ScanRange {
        let range = ScanRange(text: text, first: first, last: last)
        guard range.count <= maximumHostCount else { throw ScanRangeError.tooLarge(range.count) }
        return range
    }
}

enum ScanRangeError: LocalizedError, Equatable {
    case empty
    case malformedAddress(String)
    case malformedPrefix(String)
    case reversed
    case tooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .empty:
            "Enter an address, a range, or a network in CIDR notation."
        case .malformedAddress(let value):
            value.isEmpty ? "An address is missing." : "“\(value)” is not an IPv4 address."
        case .malformedPrefix(let value):
            value.isEmpty ? "A prefix length is missing." : "“\(value)” is not a prefix length between 0 and 32."
        case .reversed:
            "The first address comes after the last one."
        case .tooLarge(let count):
            "\(count.formatted()) addresses is over the limit of \(ScanRange.maximumHostCount.formatted())."
        }
    }
}
