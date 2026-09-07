import Testing

@testable import Octetly

@Suite("SweepProfile")
struct SweepProfileTests {
    private static func network(address: String, netmask: String) -> LocalNetwork {
        LocalNetwork(interface: "en0", address: address, netmask: netmask,
                     macAddress: nil, ipv6Addresses: [])
    }

    private static func range(_ text: String) throws -> ScanRange {
        try ScanRange.parse(text)
    }

    @Test("A range inside the interface's own subnet is on-link")
    func rangeOnOwnSubnet() throws {
        // Arrange
        let local = Self.network(address: "192.168.34.101", netmask: "255.255.252.0")

        // Act
        let profile = SweepProfile.forRange(try Self.range("192.168.34.0/24"), on: local)

        // Assert
        #expect(profile == .onLink)
    }

    @Test("A range on another subnet is routed")
    func rangeElsewhere() throws {
        // Arrange — the VPN-routed /24 this was measured on, against an en0 of 192.168.32.0/22.
        let local = Self.network(address: "192.168.34.101", netmask: "255.255.252.0")

        // Act
        let profile = SweepProfile.forRange(try Self.range("192.168.0.0/24"), on: local)

        // Assert
        #expect(profile == .routed)
    }

    @Test("A range that straddles the edge of the subnet is routed")
    func rangeStraddling() throws {
        // Arrange — there is one profile per scan, so a range with any part of it off the link
        // gets the one that copes with a router. The budget is what keeps that from being slow.
        let local = Self.network(address: "192.168.34.101", netmask: "255.255.252.0")

        // Act
        let profile = SweepProfile.forRange(try Self.range("192.168.0.0/16"), on: local)

        // Assert
        #expect(profile == .routed)
    }

    @Test("The subnet's own edges count as on-link")
    func rangeIncludingEdges() throws {
        // Arrange
        let local = Self.network(address: "192.168.34.101", netmask: "255.255.252.0")

        // Act
        let profile = SweepProfile.forRange(try Self.range("192.168.32.0-192.168.35.255"), on: local)

        // Assert
        #expect(profile == .onLink)
    }

    @Test("With no interface to compare against, the range is routed")
    func noInterface() throws {
        #expect(SweepProfile.forRange(try Self.range("192.168.0.0/24"), on: nil) == .routed)
    }

    @Test("A point-to-point interface puts every real range off-link")
    func pointToPointInterface() throws {
        // Arrange — a tunnel's own address is a /32, so its link holds nothing but itself.
        let tunnel = Self.network(address: "100.80.207.101", netmask: "255.255.255.255")

        // Act
        let profile = SweepProfile.forRange(try Self.range("192.168.0.0/24"), on: tunnel)

        // Assert
        #expect(profile == .routed)
    }

    @Test("The LAN profile bursts its first pass and paces the rest")
    func onLinkPacing() {
        // Arrange / Act / Assert
        #expect(SweepProfile.onLink.pacing(pass: 1, pending: 254) == 0)
        #expect(SweepProfile.onLink.pacing(pass: 2, pending: 254) == 0.01)
    }

    @Test("The routed profile paces from the first pass")
    func routedPacesImmediately() {
        // A /24 gets the full ceiling: 254 sends asking 25 ms each, well inside the budget.
        #expect(SweepProfile.routed.pacing(pass: 1, pending: 254) == 0.025)
        #expect(SweepProfile.routed.pacing(pass: 2, pending: 231) == 0.025)
    }

    @Test("The budget, not the ceiling, is what bounds a wide range")
    func budgetCapsWideRanges() {
        // Arrange — a /16 paced at the ceiling would be about half an hour per pass.
        let pending = 65_536

        // Act
        let gap = SweepProfile.routed.pacing(pass: 1, pending: pending)

        // Assert
        #expect(gap < SweepProfile.routed.pacingCeiling)
        #expect(Double(pending) * gap <= SweepProfile.routed.pacingBudget)
    }

    @Test("An empty pass asks for no gap rather than dividing by zero")
    func noPending() {
        #expect(SweepProfile.routed.pacing(pass: 1, pending: 0) == 0)
        #expect(SweepProfile.onLink.pacing(pass: 2, pending: 0) == 0)
    }

    @Test("The timing pass is spaced the way the profile's discovery passes are")
    func timingPassFollowsTheProfile() {
        // A path that drops a burst drops the timing pass too, so it has to be spaced like the
        // discovery it corrects — a pass that cannot reach a host cannot correct it.
        #expect(SweepProfile.routed.latencyPacing >= SweepProfile.routed.pacingCeiling)
        #expect(SweepProfile.routed.latencyPacing > SweepProfile.onLink.latencyPacing)
        #expect(SweepProfile.routed.latencyReplyTimeout > SweepProfile.onLink.latencyReplyTimeout)
    }

    @Test("The timing settings the README quotes are the ones in force")
    func timingPassSettingsArePinned() {
        // Relative comparisons hold while both sides drift together. These are the figures the
        // README and the profile docs put in front of a reader.
        #expect(SweepProfile.routed.latencyPacing == 0.025)
        #expect(SweepProfile.routed.latencyReplyTimeout == 1.0)
        #expect(SweepProfile.routed.latencyRounds == 2)
        #expect(SweepProfile.onLink.latencyPacing == 0.002)
        #expect(SweepProfile.onLink.latencyReplyTimeout == 0.4)
        // One round on a LAN, and not because a spaced pass reaches everything there — the test
        // below is about the hosts it does miss. It is that what a missed host keeps on a LAN is a
        // reading inflated about fivefold rather than fortyfold, and is kept rather than blanked,
        // so a second round would be a whole pass of sends to improve a handful of figures that
        // are already in the right order of magnitude.
        #expect(SweepProfile.onLink.latencyRounds == 1)
    }

    @Test("Only a paced profile throws away a reading it could not re-measure")
    func discardingFollowsThePacing() {
        // A paced send loop holds the path busy for seconds and its readings come out wrong by a
        // factor; a burst is over in 11 ms and inflates by about five times. And the LAN timing
        // pass waits 0.4 s against discovery's 1.5 s, so discarding there would empty the column of
        // every host that answers in between, on every scan.
        #expect(SweepProfile.routed.discardsUnmeasuredLatency)
        #expect(!SweepProfile.onLink.discardsUnmeasuredLatency)
        #expect(SweepProfile.onLink.latencyReplyTimeout < 1.5)
    }

    @Test("A routed range keeps the measured 25 ms out to a /22")
    func routedHoldsItsCeilingToTheAutoLimit() {
        // The whole point of the routed profile is the gap the hosts were found at. A budget that
        // ran out sooner would hand a /22 a gap no wider than the LAN ceiling — the spacing the
        // measurements rejected — while still paying a paced pass's wall clock for it.
        for pending in [254, 510, 1022, LocalNetwork.autoHostLimit] {
            #expect(SweepProfile.routed.pacing(pass: 1, pending: pending)
                    == SweepProfile.routed.pacingCeiling)
        }
        // And past that the budget takes over, which is the honest limit rather than a promise.
        #expect(SweepProfile.routed.pacing(pass: 1, pending: 4096)
                < SweepProfile.routed.pacingCeiling)
    }

    @Test("The timing pass is bounded by hosts that answered, not by the range")
    func timingPassHasItsOwnBudget() {
        // Arrange — a wide range can have hundreds of responders, and this pass is proportional to
        // that count. Without a budget it outlasts the discovery passes it is meant to correct.
        let manyResponders = 800

        // Act
        let gap = SweepProfile.routed.latencyGap(targets: manyResponders)

        // Assert
        #expect(gap < SweepProfile.routed.latencyPacing)
        #expect(Double(manyResponders) * gap <= SweepProfile.routed.latencyBudget)
        // A handful of hosts still gets the full spacing.
        #expect(SweepProfile.routed.latencyGap(targets: 20) == SweepProfile.routed.latencyPacing)
        #expect(SweepProfile.routed.latencyGap(targets: 0) == 0)
    }
}
