import Foundation
import Testing

@testable import Octetly

@Suite("ICMPPinger.sendWindow")
struct SendWindowTests {
    @Test("An unpaced pass keeps the window it always had")
    func burstIsUnchanged() {
        // Arrange / Act / Assert — the LAN profile's first pass sends with no gap at all.
        #expect(ICMPPinger.sendWindow(for: 254, pacing: 0) == 256)
        #expect(ICMPPinger.sendWindow(for: 65_536, pacing: 0) == 4096)
    }

    @Test("A paced pass closes its window often enough for rows to appear")
    func pacedWindowIsBoundedByTime() {
        // Arrange — the routed profile's 25 ms over a /24. At the unpaced window of 256 this is one
        // window for the whole range, so nothing reached the screen for over 7 s and then all of it
        // did, three times over.
        let window = ICMPPinger.sendWindow(for: 254, pacing: SweepProfile.routed.pacingCeiling)

        // Assert
        #expect(Double(window) * SweepProfile.routed.pacingCeiling
                <= ICMPPinger.maximumWindowSendTime)
        // Still whole windows rather than one address at a time, which would be one reply wait each.
        #expect(window > 1)
    }

    @Test("The window counts the docs quote are the ones that come out")
    func windowCountsMatchTheDocumentedFigures() {
        // SweepProfile and ICMPPinger both cost this split in windows-per-pass — 1 to 7 on a routed
        // /24, 4 to 26 on a /22, 1 to 3 on the LAN profile's retries — and those numbers are what
        // the per-pass floors of 9.1 s and 31.9 s are built from. Left unpinned they drift out of
        // the prose silently.
        let routedGap = SweepProfile.routed.pacingCeiling
        #expect(ICMPPinger.sendWindow(for: 254, pacing: routedGap) == 40)
        #expect(windowCount(addresses: 254, pacing: routedGap) == 7)
        #expect(windowCount(addresses: 254, pacing: 0) == 1)
        #expect(windowCount(addresses: 1022, pacing: routedGap) == 26)
        #expect(windowCount(addresses: 1022, pacing: 0) == 4)
        // The LAN profile's paced retries over a /24, which used to be a single window.
        #expect(windowCount(addresses: 254, pacing: SweepProfile.onLink.pacing(pass: 2, pending: 254)) == 3)
    }

    /// How many windows a pass over `addresses` closes, the way ScanEngine strides over them.
    private func windowCount(addresses: Int, pacing: TimeInterval) -> Int {
        let size = ICMPPinger.sendWindow(for: addresses, pacing: pacing)
        return Array(stride(from: 0, to: addresses, by: size)).count
    }

    @Test("Pacing only ever narrows the window")
    func pacingNeverWidens() {
        // A gap the budget has crushed towards zero must not widen a /16 past its window cap.
        #expect(ICMPPinger.sendWindow(for: 65_536, pacing: 0.000_1)
                <= ICMPPinger.sendWindow(for: 65_536, pacing: 0))
    }

    @Test("A gap wide enough to swallow the budget still sends something")
    func neverZero() {
        // Int(maximumWindowSendTime / 10) is 0, and a window of zero would make the sweep loop
        // forever.
        #expect(ICMPPinger.sendWindow(for: 254, pacing: 10) >= 1)
    }
}
