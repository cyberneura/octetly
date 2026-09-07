import Foundation

/// How hard a path will let a sweep push before it starts dropping the answers.
///
/// A switched LAN absorbs a burst: 254 requests go out in about 11 ms and the live hosts answer.
/// One VPN-routed /24 did not, and the loss there was not something a longer wait fixed. Measured
/// against that path — hosts that each answer ping(8) with 0% loss when probed on their own, at
/// round-trip times of 13 to 360 ms against a 1.5 s reply window:
///
/// | send gap | found | elapsed |
/// |---|---|---|
/// | burst, then 10 ms retries (what the LAN profile does) | 13 | 10.5 s |
/// | 10 ms throughout, three passes | 13 | 13.4 s |
/// | 25 ms throughout, two passes | 21, and 23 on a repeat | 17 s |
///
/// The 25 ms run's 23 were a superset of the 10 ms run's 13. Adding passes at 10 ms did not close
/// the gap and slowing the send did, so what is being hit is a rate limit rather than a timeout.
/// The burst is worse than useless on such a path: on the run above its pass reached 2 of the 16
/// hosts then known, having spent its full reply window to do it, and repeats put its yield
/// anywhere between 2 and 11.
///
/// Those are the runs, not the settings that shipped: `routed` makes the same three passes `onLink`
/// does, so it has one more than the row it is named after.
///
/// One path is what this rests on, and the profile is applied to every routed range rather than to
/// paths shown to behave like it — nothing here measures a path before choosing. That is a policy
/// bet, and its cost is a fast router scanned more slowly than it needed to be. It is not free in
/// the other direction either: pacing moves the last address of a /24 from 11 ms into the scan to
/// about 7 s, so a host reachable only for the first instant of one is a host the burst would
/// have caught and this will not. Equal attempt counts bound how often each address is asked, not
/// when.
struct SweepProfile: Sendable, Equatable {
    /// Whether the first pass goes out as fast as the socket will take it.
    let burstsFirstPass: Bool
    let pacingCeiling: TimeInterval
    /// How long one pass may spend on the gaps between its sends.
    ///
    /// This, rather than the ceiling, is what keeps a wide range finite, and on a wide enough one
    /// it is the only thing setting the gap: a /16 paced at the routed ceiling would be about half
    /// an hour per pass, so the budget collapses the gap towards zero and the pass becomes a burst
    /// whatever the profile asked for. **The ceiling only holds while the budget affords it** —
    /// `pacing(pass:pending:)` has where each profile's crossover falls.
    ///
    /// Spent in requested sleep rather than in wall-clock, and the difference is not small: this
    /// platform takes 28.5 ms for a 25 ms request, so a pass budgeted at 26 s of gaps runs about
    /// 29 s of them. `EchoPinger.probe` has why that overshoot is left in — the alternative was
    /// bursts — and every wall-clock figure quoted here already has it added in.
    let pacingBudget: TimeInterval

    /// Spacing and reply window for the pass that times the hosts already found.
    ///
    /// Only responders are re-probed, which on the ranges this was measured on is a few dozen
    /// packets rather than a whole range, so it can afford the gap the discovery passes use on a
    /// /24. It needs to: a path that drops a burst drops this pass too, and what a host that misses
    /// it is left with is `discardsUnmeasuredLatency`'s to say.
    let latencyPacing: TimeInterval
    let latencyReplyTimeout: TimeInterval
    /// The same kind of cap as `pacingBudget`, for the same reason. Nothing bounds how many hosts
    /// answer a wide range, and this pass is proportional to that count rather than to the range:
    /// several hundred responders on a routed /16 would otherwise put a round near half a minute
    /// (300 of them is 8.6 s of gaps at the measured rate, 900 is 25.7, and the reply window is on
    /// top of that), with nothing to stop the next range answering with more. The crossover is
    /// `latencyBudget / latencyPacing` targets — 320 routed, 1,000 on-link — past which the budget
    /// sets the gap.
    let latencyBudget: TimeInterval

    /// How many times to go back for the hosts still without a figure.
    ///
    /// What a host would keep when this pass misses it is a reading taken while the send loop had
    /// the path loaded, and on a paced pass that loop runs for seconds: measured over the routed
    /// /24, hosts that ping(8) answers in 25 ms carried 600–1,060 ms from discovery. Those are not
    /// absurd enough to be refused by `EchoPinger.maximumRoundTrip`, which is exactly what makes
    /// another round worth its cost — a wrong number that looks right is read as right. A round is
    /// only the hosts still missing one, so the second is a handful of packets. What a host misses
    /// every round of is left blank instead, where `discardsUnmeasuredLatency` says so.
    let latencyRounds: Int

    /// Private so that the only profiles in existence are the two below. `latencyRounds` is a
    /// `1...` loop bound, which traps on a zero, and there is no case for a third profile that has
    /// not been measured.
    private init(burstsFirstPass: Bool, pacingCeiling: TimeInterval,
                 pacingBudget: TimeInterval, latencyPacing: TimeInterval,
                 latencyReplyTimeout: TimeInterval, latencyBudget: TimeInterval,
                 latencyRounds: Int) {
        self.burstsFirstPass = burstsFirstPass
        self.pacingCeiling = pacingCeiling
        self.pacingBudget = pacingBudget
        self.latencyPacing = latencyPacing
        self.latencyReplyTimeout = latencyReplyTimeout
        self.latencyBudget = latencyBudget
        self.latencyRounds = latencyRounds
    }

    /// Hosts on this Mac's own link.
    ///
    /// The budget puts the ceiling's crossover at 300 addresses, past which a pass is paced by the
    /// budget instead. These are the numbers this project shipped with before there was a choice of
    /// profile, kept as they were: a LAN is where the burst works, so what the retries are paced at
    /// matters less here than it does through a tunnel.
    ///
    /// The constants are unchanged; the behaviour is not quite. `ICMPPinger.sendWindow` now splits
    /// a paced pass by time as well as by count, so this profile's retries over a /24 close three
    /// windows where they used to close one — rows appear sooner, at two more reply waits.
    static let onLink = SweepProfile(burstsFirstPass: true,
                                     pacingCeiling: 0.01, pacingBudget: 3.0,
                                     latencyPacing: 0.002, latencyReplyTimeout: 0.4,
                                     latencyBudget: 2.0, latencyRounds: 1)

    /// Anything reached through a router or a tunnel.
    ///
    /// The budget is what it is so that the measured 25 ms survives out to 1,040 addresses, which
    /// covers every range up to a /22 and so also `LocalNetwork.autoHostLimit`. The gap is the
    /// thing that finds the hosts, and it is most of what a pass costs: a /24 spends 7.2 s of a
    /// pass that floors at 9.1 s, a /22 29.1 s of 31.9 s. Those floors count the sends at their measured
    /// rate, the per-window reply waits and the final drain, and not the ARP read a window that
    /// found something also pays for — with one on every window that is another 0.1 s on a /24 and
    /// 1 s on a /22. Past a /22 the budget takes over and
    /// the gap falls below what was measured to work — there is nothing else to offer, since a /16
    /// at 25 ms would be about half an hour a pass.
    ///
    /// The pass count is not reduced to pay for that. Two passes were tried, on the grounds that
    /// the second of the measured ones added only 3 hosts to the first's 20 — but the pass that
    /// dropping one removes is an *attempt*, and on a range small enough to have no burst to avoid
    /// (a single address, at the limit) three attempts beat two with nothing traded for it. What
    /// this profile changes is the spacing, not how many times a silent address is asked.
    ///
    /// The reply window is wider than the LAN's for the same reason the gap is: the slowest host
    /// measured on the routed /24 above averaged 216 ms against a 0.4 s window, which leaves a
    /// figure riding on one un-dropped packet.
    static let routed = SweepProfile(burstsFirstPass: false,
                                     pacingCeiling: 0.025, pacingBudget: 26.0,
                                     latencyPacing: 0.025, latencyReplyTimeout: 1.0,
                                     latencyBudget: 8.0, latencyRounds: 2)

    /// Which profile a range gets.
    ///
    /// On-link only where the whole range sits inside the interface's own subnet. A range that
    /// straddles the edge gets the routed profile for the whole of itself, however little of it is
    /// actually outside — there is one profile per scan, and of the two it is the one that copes
    /// with a router. The budget above is what keeps that from being slow.
    ///
    /// No interface at all says nothing about the path, and of the two the one that finds hosts is
    /// the one to guess with.
    ///
    /// This is one interface's subnet and not the routing table, so it answers "is this the subnet
    /// of the interface LocalNetwork picked" rather than "how would a packet get there". It can be
    /// wrong in both directions. A route more specific than the interface's own — a VPN that takes
    /// over a slice of the LAN it was dialled in from — is called on-link when it is not. A machine
    /// with a second interface up has every address on that one called routed, since
    /// `LocalNetwork.current()` returns the first interface it finds and no other is consulted.
    ///
    /// The two mistakes do not cost the same thing, and neither is free. Neither costs an address
    /// an attempt — both profiles ask three times. Reading a routed path as on-link puts a burst on
    /// it and paces its retries at 10 ms, which is the 13-against-23 measured above: it is the
    /// faster scan and the one that loses hosts. Reading an on-link range as routed spends time,
    /// and empties the Ping column of any host that answers between the timing pass's window and
    /// discovery's drain — `discardsUnmeasuredLatency` hangs off the same choice, so which of them
    /// applies is decided by which interface `LocalNetwork` happened to pick. Splitting that
    /// decision out would fix the second cost without touching the first; nothing here has needed
    /// it yet, and it is written down so the next reader does not have to rediscover that the two
    /// are wired together. Consulting the route would settle the misjudgement itself, at a
    /// subprocess per scan and a new way to be wrong; no path measured here has needed that either.
    static func forRange(_ range: ScanRange, on network: LocalNetwork?) -> SweepProfile {
        guard let link = network?.linkRange,
              range.first >= link.first, range.last <= link.last else { return .routed }
        return .onLink
    }

    /// Whether a reading discovery took should be thrown away when the timing pass cannot replace
    /// it.
    ///
    /// Only where discovery paced itself. A paced send loop holds the path busy for seconds and the
    /// readings taken during one come out wrong by a factor — 600 to 1,060 ms, measured, for hosts
    /// that answer in 25 — which is a number that misleads rather than a number that is rough. A
    /// burst is over in 11 ms and inflates by about five times (24 ms where a spaced request gets
    /// 5), which is the sort of margin the Ping column is already understood to carry.
    ///
    /// The asymmetry matters because the timing pass waits less than discovery does: 0.4 s on a
    /// LAN against the 1.5 s of the final drain. A host that answers in between — a phone asleep
    /// on Wi-Fi, a printer rate-limiting ICMP — is found by discovery every time and missed by the
    /// timing pass every time, so discarding here would empty its Ping column on every scan rather
    /// than occasionally.
    var discardsUnmeasuredLatency: Bool { !burstsFirstPass }

    /// The gap to leave between sends, for one pass over `pending` addresses.
    ///
    /// The ceiling holds up to `pacingBudget / pacingCeiling` addresses — 300 on-link, 1,040
    /// routed — and past that the budget sets the gap and the ceiling never applies.
    func pacing(pass: Int, pending: Int) -> TimeInterval {
        if pass <= 1, burstsFirstPass { return 0 }
        guard pending > 0 else { return 0 }
        return min(pacingCeiling, pacingBudget / Double(pending))
    }

    /// The gap between sends for one round of the timing pass, over `targets` hosts.
    func latencyGap(targets: Int) -> TimeInterval {
        guard targets > 0 else { return 0 }
        return min(latencyPacing, latencyBudget / Double(targets))
    }
}
