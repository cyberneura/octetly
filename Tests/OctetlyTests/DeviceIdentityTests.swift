import Testing

@testable import Octetly

@Suite("DeviceIdentity")
struct DeviceIdentityTests {
    @Test("Unicast DNS names a row before anything else does")
    func dnsWins() {
        // Arrange
        let identity = DeviceIdentity(dnsName: "printer.corp.example.com", mdnsName: "printer.local",
                                      smbName: "PRINTER", smbDomain: "WORKGROUP")

        // Act / Assert — the resolver the machine is configured with is the one answer that says
        // something about the network it is on rather than only about the host.
        #expect(identity.hostname == "printer.corp.example.com")
    }

    @Test("A relayed .local does not outrank what the host itself said")
    func responderBeatsRelayedMulticastName() {
        // Arrange — the resolver holds a .local it got from somewhere, and the host answers with
        // another. A suffix says which namespace a name is in, not that the answer is current.
        let identity = DeviceIdentity(dnsName: "relay.local", mdnsName: "artemis.local")

        // Act / Assert — showing the resolver's would put a stale cache entry in the Name column
        // and leave the real name where only the detail pane sees it.
        #expect(identity.hostname == "artemis.local")
        // With nothing from the host, the relayed one is still better than no name at all.
        #expect(DeviceIdentity(dnsName: "relay.local").hostname == "relay.local")
    }

    @Test("The host's own name is used when the resolver has none")
    func mdnsFillsIn() {
        // This is the case the routed /24 is made of: reverse DNS is empty for every address there
        // and the responder answers for most of them.
        #expect(DeviceIdentity(mdnsName: "artemis.local").hostname == "artemis.local")
    }

    @Test("SMB is the last name tried")
    func smbIsLast() {
        // Measured on that same segment: one host answered smbutil and nothing else.
        #expect(DeviceIdentity(smbName: "POSEIDON").hostname == "POSEIDON")
    }

    @Test("A row nothing could name says so rather than guessing")
    func noNameAtAll() {
        // The table shows the address in this case, so "—" has to survive as far as the row.
        #expect(DeviceIdentity().hostname == "—")
    }
}
