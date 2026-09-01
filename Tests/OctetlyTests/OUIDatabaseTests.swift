import Testing

@testable import Octetly

@Suite("OUIDatabase")
struct OUIDatabaseTests {
    // The first line is a header, as it is in the generated Sources/octetly/Resources/oui.csv.
    // 001122A is a 28-bit assignment inside the 24-bit block 001122, which is the
    // case longest-prefix matching exists for.
    let database = OUIDatabase(csv: """
        prefix,vendor
        001122,Registration Authority
        001122A,Acme Networks
        001122AB0,Acme Networks Storage
        """)

    @Test("Every row is read but the header")
    func count() {
        #expect(database.count == 3)
    }

    @Test("The longest assignment wins")
    func longestPrefix() {
        // The 24-bit row names whoever registered the block, so answering with it
        // where a longer row exists would name the wrong company.
        #expect(database.vendor(for: "00:11:22:AB:00:01") == "Acme Networks Storage")
        #expect(database.vendor(for: "00:11:22:AC:00:01") == "Acme Networks")
        #expect(database.vendor(for: "00:11:22:B0:00:01") == "Registration Authority")
    }

    @Test("Separators in a MAC address do not matter")
    func separators() {
        #expect(database.vendor(for: "001122b00001") == "Registration Authority")
        #expect(database.vendor(for: "00-11-22-b0-00-01") == "Registration Authority")
    }

    @Test("A locally administered address was never assigned to anyone")
    func randomized() {
        // Phones set one per network by default, so this is the usual answer on
        // a Wi-Fi segment rather than an edge case.
        #expect(OUIDatabase.isLocallyAdministered("02:00:00:00:00:01"))
        #expect(!OUIDatabase.isLocallyAdministered("00:11:22:33:44:55"))
        #expect(database.vendor(for: "02:11:22:33:44:55") == OUIDatabase.randomizedVendor)
    }

    @Test("A group address is not a neighbour")
    func groupAddress() {
        // arp(8) reports broadcast and multicast rows alongside real hosts, and
        // they carry the locally administered bit too, so the order of the two
        // checks is what keeps them out of Randomized.
        #expect(database.vendor(for: "01:00:5E:00:00:01") == OUIDatabase.unknownVendor)
        #expect(database.vendor(for: "FF:FF:FF:FF:FF:FF") == OUIDatabase.unknownVendor)
    }

    @Test("An address no row covers is unknown, and so is one too short to look up")
    func unknown() {
        #expect(database.vendor(for: "00:00:00:11:22:33") == OUIDatabase.unknownVendor)
        #expect(database.vendor(for: "00:11") == OUIDatabase.unknownVendor)
        #expect(database.vendor(for: "") == OUIDatabase.unknownVendor)
    }
}
