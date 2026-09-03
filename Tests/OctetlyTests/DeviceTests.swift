import Testing

@testable import Octetly

@Suite("Device")
struct DeviceTests {
    @Test("A row keeps the id it was created with")
    func identity() {
        // Arrange
        var host = Device(ipv4: "192.168.0.9")
        var ipv6Only = Device(ipv6: "fe80::2%en0")

        // Act — everything a later phase of the scan can add.
        host.add(ipv6: ["2001:db8::1", "fe80::1%en0"])
        host.macAddress = "00:11:32:69:6B:5F"
        ipv6Only.add(ipv6: ["fe80::1%en0"])

        // Assert — the table's selection and the engine's index are both keyed by id, so a row
        // that changed it mid-scan would go out from under whoever had selected it.
        #expect(host.id == "192.168.0.9")
        #expect(ipv6Only.id == "fe80::2%en0")
    }

    @Test("A row is shown at its most routable address and reached at the one it answered from")
    func displayAddress() {
        // Arrange
        let host = Device(ipv4: "192.168.0.9")
        var ipv6Only = Device(ipv6: "fe80::2%en0")

        // Act — the routable address comes from the neighbour cache, not from a reply.
        ipv6Only.add(ipv6: ["2001:db8::1"])

        // Assert — the routable one leads the table, but a socket goes to the address something
        // actually answered at during this scan: a cache entry can be most of a day old, so
        // timing or port-scanning the other one would be measuring an address on no evidence.
        #expect(host.displayAddress == "192.168.0.9")
        #expect(host.reachableAddress == "192.168.0.9")
        #expect(ipv6Only.displayAddress == "2001:db8::1")
        #expect(ipv6Only.reachableAddress == "fe80::2%en0")
        // What the name and note editors say the entry is filed under has to be the actual key.
        #expect(ipv6Only.annotationAddress == "fe80::2%en0")
        #expect(ipv6Only.addressAnnotationKey == "ip:fe80::2%en0")
    }

    @Test("Adding addresses keeps the one the row answered from")
    func addressesAccumulate() {
        // Arrange
        var device = Device(ipv6: "fe80::2%en0")

        // Act — the neighbour cache is read after the sweep and may not list every address yet.
        device.add(ipv6: ["fe80::1%en0"])
        device.add(ipv6: ["fe80::1%en0", "2001:db8::1"])

        // Assert
        #expect(device.ipv6Addresses == ["2001:db8::1", "fe80::1%en0", "fe80::2%en0"])
    }

    @Test("IPv4 rows sort by number, and IPv6-only rows after all of them")
    func addressOrder() {
        // Arrange
        let rows = [
            Device(ipv6: "fe80::2%en0"),
            Device(ipv4: "192.168.0.10"),
            Device(ipv6: "fe80::1%en0"),
            Device(ipv4: "192.168.0.9"),
        ]

        // Act
        let sorted = rows.sorted { $0.addressOrder < $1.addressOrder }

        // Assert — sorting on the dotted string would put .10 before .9, and a row with no number
        // at all has to land somewhere predictable rather than at zero.
        #expect(sorted.map(\.displayAddress) == [
            "192.168.0.9", "192.168.0.10", "fe80::1%en0", "fe80::2%en0",
        ])
    }

    @Test("Answering an echo request is not the same as being in a cache")
    func discovery() {
        // Arrange
        let silent = Device(ipv4: "192.168.0.9", discovery: [.arpCache])
        let answered = Device(ipv4: "192.168.0.10", discovery: [.icmpEcho, .arpCache])
        let overIPv6 = Device(ipv6: "fe80::1%en0", discovery: [.icmpv6Echo])

        // Assert — two of these answered a probe at the address in question. The first did not,
        // and is on the list on the weaker evidence of a cache entry: a different claim, and the
        // one the detail pane has to be able to state differently.
        #expect(!silent.answeredEcho)
        #expect(answered.answeredEcho)
        #expect(overIPv6.answeredEcho)
        #expect(silent.discoverySummary == "ARP cache")
        // Listed in a fixed order rather than the set's, so the field does not reshuffle per scan.
        #expect(answered.discoverySummary == "ICMP echo, ARP cache")
    }

    @Test("Search reaches an address the column is too narrow to show")
    func search() {
        // Arrange
        var device = Device(ipv6: "fe80::2%en0", macAddress: "00:11:32:69:6B:5F")
        device.add(ipv6: ["2001:db8::dead:beef"])

        // Act / Assert
        #expect(device.matches("dead:beef"))
        #expect(device.matches("fe80::2"))
        #expect(device.matches("69:6b"))
        #expect(!device.matches("192.168"))
    }

    @Test("A note follows the MAC address where there is one, and the row's own address otherwise")
    func annotationKey() {
        // Arrange
        let known = Device(ipv6: "fe80::2%en0", macAddress: "00:11:32:69:6B:5F")
        let unknown = Device(ipv6: "fe80::2%en0")
        let ipv4 = Device(ipv4: "192.168.0.9")

        // Assert — the IPv4 form is what earlier versions filed under, so it has to stay as it was.
        #expect(known.annotationKey == "mac:00:11:32:69:6B:5F")
        #expect(unknown.annotationKey == "ip:fe80::2%en0")
        #expect(ipv4.annotationKey == "ip:192.168.0.9")
    }
}
