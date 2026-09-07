import Foundation
import Testing

@testable import Octetly

@Suite("EchoPinger round-trip")
struct RoundTripTests {
    private static func at(milliseconds: Double) -> DispatchTime {
        DispatchTime(uptimeNanoseconds: UInt64(milliseconds * 1_000_000))
    }

    @Test("A reply inside the bound is reported as it came")
    func withinBound() {
        // Arrange — the range everything measured here falls in: single digits on a switch, tens to
        // a few hundred milliseconds through a router.
        let sent = Self.at(milliseconds: 1_000)

        // Act / Assert
        #expect(EchoPinger.reportableRoundTrip(sentAt: sent, arrival: Self.at(milliseconds: 1_005))
                == 5)
        #expect(EchoPinger.reportableRoundTrip(sentAt: sent, arrival: Self.at(milliseconds: 1_360))
                == 360)
    }

    @Test("A reply older than the longest wait is not a measurement")
    func beyondBound() {
        // A paced pass spends seconds in its send loop, and `sentAt` is keyed by address, so a reply
        // nobody is waiting for is still matched to whatever was last sent there. Left unbounded,
        // this is what put 16,419.9 ms in the Ping column of a host that answers in 80.
        let sent = Self.at(milliseconds: 1_000)
        #expect(EchoPinger.reportableRoundTrip(sentAt: sent, arrival: Self.at(milliseconds: 17_420))
                == nil)
    }

    @Test("The bound itself is still a measurement")
    func exactlyAtBound() {
        // Off-by-one here silently blanks the Ping column of the slowest hosts rather than erroring.
        let sent = Self.at(milliseconds: 1_000)
        let limit = EchoPinger.maximumRoundTrip * 1_000
        #expect(EchoPinger.reportableRoundTrip(sentAt: sent,
                                               arrival: Self.at(milliseconds: 1_000 + limit))
                == limit)
        #expect(EchoPinger.reportableRoundTrip(sentAt: sent,
                                               arrival: Self.at(milliseconds: 1_000 + limit + 1))
                == nil)
    }

    @Test("A reply that predates its send is refused rather than wrapped")
    func arrivalBeforeSend() {
        // The subtraction is on UInt64, so getting this wrong traps rather than showing a bad
        // number. It is reachable: the timing pass re-sends to addresses the sweep already timed.
        #expect(EchoPinger.reportableRoundTrip(sentAt: Self.at(milliseconds: 1_000),
                                               arrival: Self.at(milliseconds: 999)) == nil)
    }
}
