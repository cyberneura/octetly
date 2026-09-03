import Testing

@testable import Octetly

@Suite("NeighbourCache")
struct NeighbourCacheTests {
    // The link-local rows are in the shape `ndp -an` prints on the network this was written for,
    // header and all. `fe80::1%lo0` prints `(incomplete)` because lo0 has no link-layer address to
    // report, not because the entry is unresolved, and it exercises the same check either way.
    // One NIC against two addresses is ordinary in a cache that holds entries for most of a day.
    // The 2001:db8:: row is made up — RFC 3849 documentation space, added to give `addresses(for:)`
    // a routable address to sort ahead of the rest, since this network has none.
    let ndpOutput = """
        Neighbor                                Linklayer Address  Netif Expire    St Flgs Prbs
        fe80::1%lo0                             (incomplete)         lo0 permanent R
        fe80::854:f142:1735:9416%en0            f2:22:d:22:86:2      en0 22h48m53s S
        fe80::c0a:355:e809:9f4c%en0             f2:22:d:22:86:2      en0 9h7m55s   S
        2001:db8::1                             0:11:32:69:6b:5f     en0 23h47m16s S
        fe80::211:32ff:fe69:6b5f%en0            0:11:32:69:6b:5f     en0 23h47m16s S
        """

    @Test("The header row and an unresolved entry are not neighbours")
    func skipsNonEntries() {
        // Arrange / Act
        let table = NeighbourCache.parseNDP(ndpOutput)

        // Assert
        #expect(table.macByAddress.count == 4)
        #expect(table.mac(for: "fe80::1%lo0") == nil)
    }

    @Test("Leading zeros dropped by ndp are put back")
    func normalizesHardwareAddresses() {
        // Arrange / Act
        let table = NeighbourCache.parseNDP(ndpOutput)

        // Assert — the same NIC is `0:11:32:…` here and `00:11:32:…` in arp(8), and the two have
        // to compare equal for a host found over IPv6 to be recognised as one already on the list.
        #expect(table.mac(for: "fe80::211:32ff:fe69:6b5f%en0") == "00:11:32:69:6B:5F")
        #expect(table.mac(for: "fe80::854:f142:1735:9416%en0") == "F2:22:0D:22:86:02")
    }

    @Test("One NIC holds every address it answers on")
    func groupsAddressesByNIC() {
        // Arrange / Act
        let table = NeighbourCache.parseNDP(ndpOutput)

        // Assert
        #expect(table.addresses(for: "F2:22:0D:22:86:02") == [
            "fe80::854:f142:1735:9416%en0",
            "fe80::c0a:355:e809:9f4c%en0",
        ])
    }

    @Test("A routable address comes before a link-local one")
    func routableAddressFirst() {
        // Arrange / Act
        let table = NeighbourCache.parseNDP(ndpOutput)

        // Assert — a link-local address is unusable off the segment, so where a host has both it
        // is the routable one the address column should lead with.
        #expect(table.addresses(for: "00:11:32:69:6B:5F").first == "2001:db8::1")
    }

    @Test("A multicast group is not a device")
    func skipsMulticast() {
        // Arrange
        let output = """
            ff02::fb%en0                            33:33:0:0:0:fb       en0 permanent R
            fe80::1c10:cc17:a1f9:7d7c%en0           6:34:e9:28:91:d      en0 23h0m0s   S
            """

        // Act
        let table = NeighbourCache.parseNDP(output)

        // Assert
        #expect(table.macByAddress.count == 1)
        #expect(table.mac(for: "fe80::1c10:cc17:a1f9:7d7c%en0") == "06:34:E9:28:91:0D")
    }

    @Test("Only the interface the probe went out on is read")
    func filtersByInterface() {
        // Arrange — ndp(8) reports every interface at once. awdl0 and llw0 are this Mac's own
        // AirDrop interfaces, and a utun is whatever a VPN left behind.
        let output = """
            fe80::211:32ff:fe69:6b5f%en0            0:11:32:69:6b:5f     en0 23h47m16s S
            fe80::815:b5ff:feb2:c503%awdl0          a:15:b5:b2:c5:3    awdl0 permanent R
            fe80::815:b5ff:feb2:c503%llw0           a:15:b5:b2:c5:3     llw0 permanent R
            """

        // Act
        let all = NeighbourCache.parseNDP(output)
        let onEn0 = NeighbourCache.parseNDP(output, interface: "en0")

        // Assert — a neighbour on another link cannot be what answered a probe sent on this one.
        #expect(all.macByAddress.count == 3)
        #expect(onEn0.macByAddress.count == 1)
        #expect(onEn0.mac(for: "fe80::211:32ff:fe69:6b5f%en0") == "00:11:32:69:6B:5F")
        #expect(onEn0.addresses(for: "0A:15:B5:B2:C5:03").isEmpty)
    }

    @Test("An address listed twice keeps the entry ndp printed first")
    func firstEntryWins() {
        // Arrange — the same address against two NICs is what a cache mid-update looks like.
        let output = """
            fe80::1%en0                             0:11:32:69:6b:5f     en0 1h0m0s    S
            fe80::1%en0                             0:11:32:aa:bb:cc     en0 1h0m0s    S
            """

        // Act
        let table = NeighbourCache.parseNDP(output)

        // Assert
        #expect(table.mac(for: "fe80::1%en0") == "00:11:32:69:6B:5F")
    }

    // Rows in the shape `arp -anl` prints, header and all. Every combination of the two expiry
    // columns that a real cache produced during a sweep is here: both live, outbound expired but
    // inbound live, outbound live but inbound expired, permanent, and unresolved.
    let arpOutput = """
        Neighbor                Linklayer Address Expire(O) Expire(I)          Netif Refs Prbs
        192.168.32.1            ac:44:f2:b6:48:85 2m42s     1m28s          en0    6
        192.168.32.7            9c:53:22:48:aa:30 expired   1m12s          en0    3
        192.168.32.9            e8:65:38:b1:cf:8d 2m42s     expired        en0    2
        192.168.32.2            (incomplete)      (none)    (none)         en0
        192.168.34.101          6:34:e9:28:91:d   (none)    (none)         en0
        """

    @Test("An entry the kernel never resolved is not a host")
    func parsesARP() {
        // Arrange / Act
        let table = NeighbourCache.parseARP(arpOutput)

        // Assert — an incomplete entry means the kernel asked and nothing answered, which is the
        // whole difference between a host that filters ICMP and an address with nothing on it.
        #expect(table["192.168.32.2"] == nil)
        #expect(table["192.168.32.1"] == "AC:44:F2:B6:48:85")
    }

    @Test("The inbound timer decides, not the outbound one")
    func usesInboundExpiry() {
        // Arrange / Act
        let table = NeighbourCache.parseARP(arpOutput)

        // Assert — Expire(O) runs from this Mac's last send, which the sweep resets for every
        // address in range whether or not anything is there, so it says nothing about the host.
        // Expire(I) runs from the last packet received from it. An entry swept and still expired
        // inbound answered nothing; one expired outbound but live inbound was heard from
        // recently, and dropping it was the bug this test exists for.
        #expect(table["192.168.32.7"] == "9C:53:22:48:AA:30")
        #expect(table["192.168.32.9"] == nil)
    }

    @Test("A permanent entry has no timer to have expired")
    func keepsPermanentEntries() {
        // Arrange / Act
        let table = NeighbourCache.parseARP(arpOutput)

        // Assert — `(none)` is what this Mac's own address prints, and it is a host like any other.
        #expect(table["192.168.34.101"] == "06:34:E9:28:91:0D")
    }

    @Test("Anything that is not six octets is not a hardware address")
    func rejectsNonHardwareAddresses() {
        // Arrange / Act / Assert
        #expect(NeighbourCache.normalizedMAC("Linklayer") == nil)
        #expect(NeighbourCache.normalizedMAC("(incomplete)") == nil)
        #expect(NeighbourCache.normalizedMAC("0:11:32:69:6b") == nil)
        #expect(NeighbourCache.normalizedMAC("0:11:32:69:6b:5f:aa") == nil)
        #expect(NeighbourCache.normalizedMAC("0:11:32:69:6b:zz") == nil)
        #expect(NeighbourCache.normalizedMAC("0:11:32:69:6b:5f") == "00:11:32:69:6B:5F")
    }
}
