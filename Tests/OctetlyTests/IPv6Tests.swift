import Testing

@testable import Octetly

@Suite("IPv6")
struct IPv6Tests {
    @Test("An address and its bytes are the same address")
    func bytes() {
        // Arrange / Act / Assert
        #expect(IPv6.bytes("::1")?.last == 1)
        #expect(IPv6.bytes("fe80::1")?.first == 0xFE)
        #expect(IPv6.bytes("192.168.0.1") == nil)
        #expect(IPv6.bytes("") == nil)
    }

    @Test("The zone comes off for parsing and stays on for display")
    func zone() {
        // Arrange / Act / Assert — the same fe80:: address can be in use on more than one segment
        // this Mac is attached to, so an address without its zone names no particular host.
        #expect(IPv6.withoutZone("fe80::1%en0") == "fe80::1")
        #expect(IPv6.withoutZone("2001:db8::1") == "2001:db8::1")
        #expect(IPv6.zone("fe80::1%en0") == "en0")
        #expect(IPv6.zone("2001:db8::1") == nil)
        #expect(IPv6.canonical("fe80::1%en0") == "fe80::1%en0")
    }

    @Test("Two spellings of one address end up the same")
    func canonical() {
        // Arrange / Act / Assert — what ndp(8) prints and what a reply arrived from have to
        // compare equal, and only one of the two is this program's to write.
        #expect(IPv6.canonical("FE80::0001%en0") == "fe80::1%en0")
        #expect(IPv6.canonical("2001:0db8:0000:0000:0000:0000:0000:0001") == "2001:db8::1")
        #expect(IPv6.canonical("not an address") == nil)
    }

    @Test("Link-local and multicast are told apart from the rest")
    func classification() {
        // Arrange / Act / Assert
        #expect(IPv6.isLinkLocal("fe80::1%en0"))
        #expect(IPv6.isLinkLocal("febf::1"))
        #expect(!IPv6.isLinkLocal("fec0::1"))
        #expect(!IPv6.isLinkLocal("2001:db8::1"))
        #expect(IPv6.isMulticast("ff02::1%en0"))
        #expect(!IPv6.isMulticast("fe80::1"))
    }

    @Test("Routable addresses lead")
    func routableFirst() {
        // Arrange
        let addresses = ["fe80::2%en0", "2001:db8::1", "fe80::1%en0", "fd00::1"]

        // Act
        let ordered = IPv6.routableFirst(addresses)

        // Assert — the two routable ones come first in address order, then the link-local ones.
        #expect(ordered == ["2001:db8::1", "fd00::1", "fe80::1%en0", "fe80::2%en0"])
    }
}
