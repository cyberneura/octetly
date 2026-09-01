import Testing

@testable import Octetly

@Suite("IPv4")
struct IPv4Tests {
    @Test("An address and its number are the same address")
    func roundTrip() {
        #expect(IPv4.number("192.168.0.1") == 0xC0A8_0001)
        #expect(IPv4.string(0xC0A8_0001) == "192.168.0.1")
        #expect(IPv4.string(0) == "0.0.0.0")
        #expect(IPv4.string(UInt32.max) == "255.255.255.255")
    }

    @Test("What is not an address is not read as one")
    func rejectsNonAddresses() {
        // Anything accepted here becomes a scan target, so the shapes that are
        // nearly an address matter more than the ones that are nothing like it.
        #expect(IPv4.number("256.0.0.1") == nil)
        #expect(IPv4.number("192.168.0") == nil)
        #expect(IPv4.number("192.168.0.1.1") == nil)
        #expect(IPv4.number("") == nil)
        #expect(IPv4.number("hello") == nil)
    }
}

@Suite("ScanRange")
struct ScanRangeTests {
    @Test("A CIDR network skips its network and broadcast addresses")
    func cidr() throws {
        let range = try ScanRange.parse("192.168.0.0/24")
        #expect(range.first == IPv4.number("192.168.0.1"))
        #expect(range.last == IPv4.number("192.168.0.254"))
        #expect(range.count == 254)
    }

    @Test("Host bits in a CIDR name the same network")
    func cidrIgnoresHostBits() throws {
        let written = try ScanRange.parse("192.168.0.77/24")
        let plain = try ScanRange.parse("192.168.0.0/24")
        #expect(written.id == plain.id)
    }

    @Test("A /31 and a /32 have no edges to skip")
    func cidrEdges() throws {
        // RFC 3021: there is no network or broadcast address to leave out, so
        // taking the same one off would leave a /32 with nothing in it at all.
        let host = try ScanRange.parse("10.0.0.5/32")
        #expect(host.count == 1)
        #expect(host.first == IPv4.number("10.0.0.5"))
        #expect(host.last == IPv4.number("10.0.0.5"))

        let pair = try ScanRange.parse("10.0.0.4/31")
        #expect(pair.count == 2)
        #expect(pair.first == IPv4.number("10.0.0.4"))
        #expect(pair.last == IPv4.number("10.0.0.5"))
    }

    @Test("A single address is a range of one")
    func singleAddress() throws {
        let range = try ScanRange.parse("192.168.0.42")
        #expect(range.count == 1)
        #expect(range.contains("192.168.0.42"))
        #expect(!range.contains("192.168.0.43"))
    }

    @Test("Every separator a Japanese IME can produce means the same span",
          arguments: ["-", "~", "\u{301C}", "\u{FF5E}", "\u{2013}", "\u{2014}"])
    func separators(separator: String) throws {
        let range = try ScanRange.parse("192.168.0.1 \(separator) 192.168.0.5")
        #expect(range.first == IPv4.number("192.168.0.1"))
        #expect(range.last == IPv4.number("192.168.0.5"))
        #expect(range.count == 5)
    }

    @Test("Two spellings of one span are one target")
    func identity() throws {
        let cidr = try ScanRange.parse("192.168.0.0/24")
        let bounds = try ScanRange.parse("192.168.0.1-192.168.0.254")
        #expect(cidr.id == bounds.id)
    }

    @Test("A reversed pair is reported rather than repaired")
    func reversed() {
        // Swapping them silently would scan a span nobody asked for.
        #expect(throws: ScanRangeError.reversed) {
            try ScanRange.parse("192.168.0.9 - 192.168.0.1")
        }
    }

    @Test("Nothing at all is its own complaint")
    func empty() {
        #expect(throws: ScanRangeError.empty) {
            try ScanRange.parse("   ")
        }
    }

    @Test("A malformed address is named in the error")
    func malformed() {
        #expect(throws: ScanRangeError.malformedAddress("192.168.0")) {
            try ScanRange.parse("192.168.0")
        }
        #expect(throws: ScanRangeError.malformedAddress("")) {
            try ScanRange.parse("192.168.0.1 - ")
        }
    }

    @Test("A prefix outside 0...32 is not a prefix")
    func malformedPrefix() {
        #expect(throws: ScanRangeError.malformedPrefix("33")) {
            try ScanRange.parse("192.168.0.0/33")
        }
        #expect(throws: ScanRangeError.malformedPrefix("")) {
            try ScanRange.parse("192.168.0.0/")
        }
    }

    @Test("The largest range that fits is a /16")
    func limit() throws {
        let widest = try ScanRange.parse("10.1.0.0/16")
        #expect(widest.count == 65_534)
        #expect(widest.count <= ScanRange.maximumHostCount)

        // A /8 is 16,777,214 hosts: refused rather than started.
        #expect(throws: ScanRangeError.tooLarge(16_777_214)) {
            try ScanRange.parse("10.0.0.0/8")
        }
    }

    @Test("An address outside the range is not in it")
    func contains() throws {
        let range = try ScanRange.parse("192.168.0.0/24")
        #expect(range.contains("192.168.0.1"))
        #expect(range.contains("192.168.0.254"))
        #expect(!range.contains("192.168.0.0"))
        #expect(!range.contains("192.168.0.255"))
        #expect(!range.contains("192.168.1.1"))
        #expect(!range.contains("not an address"))
    }

    @Test("The address list is the range, spelled out")
    func addressList() throws {
        let range = try ScanRange.parse("192.168.0.1-192.168.0.3")
        #expect(range.addressList() == ["192.168.0.1", "192.168.0.2", "192.168.0.3"])
    }
}
