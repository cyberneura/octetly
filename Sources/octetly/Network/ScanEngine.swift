import Darwin
import Foundation

struct ScanSnapshot: Sendable {
    let range: ScanRange
    let network: LocalNetwork?
}

struct DeviceIdentity: Sendable, Hashable {
    var dnsName = DNSName.none
    var mdnsName = DNSName.none
    var smbName = DNSName.none
    var smbDomain = DNSName.none

    /// The one name the row shows.
    ///
    /// The configured resolver comes first, because a name it holds says something about the
    /// network the host is on and not only about the host. A `.local` one is the exception: that is
    /// an mDNS claim whoever relayed it, the host is the authority for its own, and where the two
    /// disagree the host wins — otherwise a stale cache entry outranks the machine it names, and
    /// the real name reaches only the detail pane, where nothing searches it. SMB is last: it is a
    /// service name rather than a host name, and only some machines run one.
    var hostname: String {
        if dnsName != DNSName.none, !DNSName.isMulticast(dnsName) { return dnsName }
        if mdnsName != DNSName.none { return mdnsName }
        if dnsName != DNSName.none { return dnsName }
        return smbName
    }
}

struct ScanProgress: Sendable {
    enum Phase: Sendable {
        case probing
        case probingIPv6
        case timing
        case scanningPorts

        var label: String {
            switch self {
            case .probing: "Probing"
            case .probingIPv6: "Probing IPv6"
            case .timing: "Timing"
            case .scanningPorts: "Scanning ports"
            }
        }
    }

    let phase: Phase
    let completed: Int
    let total: Int
    var pass: Int = 1

    var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
}

enum ScanEvent: Sendable {
    case progress(ScanProgress)
    /// Addresses found so far, carrying only what discovery itself knows.
    case devices([Device])
    /// Keyed by `Device.id`, which is an IPv6 address for a host that has no IPv4 one.
    case identity(String, DeviceIdentity)
    case ports(String, Set<Int>)
    case finished(ScanSnapshot)
}

enum ScanEngine {
    private static let windowReplyTimeout: TimeInterval = 0.05
    // Generous because a routed or tunnelled target answers in tens of milliseconds rather than
    // the two or three of a host on the same switch, and replies trickle in rather than arriving
    // together. This is spent in full on every pass — drain has no idle-gap exit — so a scan pays
    // it once per pass it makes, which is up to three: the loop stops early once no address is
    // still silent.
    //
    // `EchoPinger.maximumRoundTrip` happens to hold the same number and is deliberately not wired
    // to this one, because the two measure from different moments: this deadline runs from the
    // start of the drain, that one from the last send to a given address. On a paced pass those are
    // seconds apart, so lengthening this would not buy a reply the right to be timed — it would buy
    // more hosts, since a reply too old to time still says the host is there. They are equal
    // because both came out of the same observation about when this network stops answering, not
    // because either is derived from the other.
    private static let finalReplyTimeout: TimeInterval = 1.5

    // How many attempts a silent address gets. The same for both sweep profiles: what differs
    // between a switched LAN and a path through a router is how fast the requests may go out, not
    // how many times it is worth asking, and on a range too small for a burst to congest anything
    // a pass fewer is purely a pass fewer.
    private static let discoveryPasses = 3

    // How fast to send, and how to time what answered, are SweepProfile's — those do differ by an
    // order of magnitude between the two.

    // One packet reaches the whole segment, so a round costs one send and the wait for its replies
    // rather than anything proportional to the range: five rounds are five packets and five
    // seconds whether the target is a /24 or a /16.
    //
    // Five because a round keeps paying for longer than it looks like it should: left to run on
    // the Wi-Fi segment this was written on, the rounds added 55, +5, +1, +1, +1, +0. Stopping at
    // the first round that added nothing new was tried and gives up too early — on that segment it
    // fired on the third round, and the counts a whole scan reported were 58 and 59 with it
    // against 67 without.
    private static let ipv6Rounds = 5
    private static let ipv6ReplyTimeout: TimeInterval = 1.0

    static func events(
        range: ScanRange,
        vendorDatabase: OUIDatabase,
        settings: ScanSettings
    ) -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let task = Task {
                await scan(range: range, vendorDatabase: vendorDatabase, settings: settings) {
                    continuation.yield($0)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func scan(
        range: ScanRange,
        vendorDatabase: OUIDatabase,
        settings: ScanSettings,
        emit: @escaping @Sendable (ScanEvent) -> Void
    ) async {
        let hosts = range.addressList()
        let network = LocalNetwork.current()
        let profile = SweepProfile.forRange(range, on: network)
        var answered = Set<String>()
        var latencies: [String: Double] = [:]
        var devices: [String: Device] = [:]
        emit(.progress(ScanProgress(phase: .probing, completed: 0, total: hosts.count)))

        let (queue, enqueue) = AsyncStream<String>.makeStream()

        await withTaskGroup(of: Void.self) { group in
            // Names are resolved as addresses turn up rather than after the sweep has finished.
            // Discovery spends most of its time waiting on replies and on the pacing between
            // retries; naming spends its time in child processes. Overlapping them costs nothing
            // and is the difference between a row being named a second after it appears and
            // being named after the last retry pass, ten seconds later.
            group.addTask {
                await resolveNames(queue, concurrency: settings.deviceConcurrency, emit: emit)
            }

            let pinger = ICMPPinger()
            var pending = hosts

            /// Takes what a discovery sweep found all the way to the screen: rows, latencies, and
            /// the queue that names them. Every sweep that can turn up an address nobody has seen
            /// goes through here, so none can collect one and stop halfway. The timing pass sends
            /// only to addresses that are already rows, but the socket hands it replies to other
            /// processes' requests too (see SweepResult), so it can hear from one nobody has seen
            /// and it goes through here as well.
            func record(_ found: SweepResult) async {
                guard !found.responded.isEmpty else { return }
                answered.formUnion(found.responded)
                latencies.merge(found.latencies) { existing, _ in existing }
                let arp = await arpTable().entries
                let added = merge(found.responded, arp: arp, latencies: latencies,
                                  answered: answered, localAddress: network?.address,
                                  vendorDatabase: vendorDatabase, into: &devices)
                emit(.devices(ordered(devices)))
                for address in added { enqueue.yield(address) }
            }

            /// Puts what the timing rounds have so far on the screen: their figures, and a row for
            /// anything they heard from that has none.
            ///
            /// Both halves have to happen while the scan is still running. Stop skips the merge at
            /// the end, and NetworkScanner stops applying events the moment it is cancelled, so a
            /// figure or a row held back until after the rounds is one that never arrives — a Stop
            /// pressed during the second round would otherwise leave the first round's hosts
            /// showing the inflated reading it had just corrected.
            ///
            /// Takes the accumulated result rather than the round's own, so that which figure an
            /// address keeps is decided in one place: `SweepResult.formUnion` keeps the first, and
            /// the merge after the rounds keeps whatever that left. Applying each round's own on
            /// top would show the later of two replies from the same host and then flip back to the
            /// earlier one when the rounds ended.
            ///
            /// The figures are emitted before anything that can suspend. `record` waits on an ARP
            /// read, and a Stop landing inside that wait would take the figures down with the row
            /// it was fetching. It is called at all only where something answered that has no row
            /// yet, because the wait is also time replies sit unread between one round's sends and
            /// the next's — a reply is timed from the moment it is read (`EchoPinger.probe` says
            /// why) — so paying it every round would add itself to the figures that follow.
            func settle(_ timed: SweepResult) async {
                latencies.merge(timed.latencies) { _, fresh in fresh }
                // Only what this round actually moved. The accumulated result is handed over whole
                // every round, so most of what it holds is already on the row it belongs to, and
                // sorting every device and publishing it again on the main actor to say nothing is
                // work the second round would do for free.
                var changed = false
                for (address, milliseconds) in timed.latencies {
                    guard var device = devices[address],
                          device.latencyMilliseconds != milliseconds else { continue }
                    device.latencyMilliseconds = milliseconds
                    devices[address] = device
                    changed = true
                }
                if changed { emit(.devices(ordered(devices))) }
                if timed.responded.contains(where: { devices[$0] == nil }) {
                    await record(timed)
                }
            }

            for pass in 1...discoveryPasses {
                guard !Task.isCancelled, !pending.isEmpty else { break }
                let pacing = profile.pacing(pass: pass, pending: pending.count)
                let windowSize = ICMPPinger.sendWindow(for: pending.count, pacing: pacing)
                // Each pass counts its own remaining addresses, so it has to restart the bar.
                // Without this the bar would sit at full for the whole of the paced retries.
                emit(.progress(ScanProgress(phase: .probing, completed: 0, total: pending.count, pass: pass)))

                for start in stride(from: 0, to: pending.count, by: windowSize) {
                    guard !Task.isCancelled else { break }
                    let window = pending[start..<min(start + windowSize, pending.count)]
                    var found: SweepResult
                    if let pinger {
                        found = await sweep(pinger) {
                            $0.probe(window, timeout: windowReplyTimeout, pacing: pacing)
                        }
                    } else {
                        // Only reached where the ICMP socket could not be opened at all.
                        found = await pingFallback(window, concurrency: settings.deviceConcurrency)
                    }
                    // A multi-homed host answers from whichever address its routing table picks,
                    // which can be one that was never probed and outside the range being scanned.
                    await record(found.filter(range.contains))
                    emit(.progress(ScanProgress(phase: .probing, completed: window.endIndex,
                                                total: pending.count, pass: pass)))
                }

                guard !Task.isCancelled else { break }
                if let pinger {
                    // Recorded the same way as a window's own replies. A host that answers only
                    // during this wait used to reach `answered` and nothing else until the final
                    // merge, so it stayed off screen for the remaining rounds — and vanished
                    // altogether if the scan was stopped first, since that merge is skipped.
                    await record(await sweep(pinger) { $0.drain(for: finalReplyTimeout) }
                        .filter(range.contains))
                }
                pending = pending.filter { !answered.contains($0) }
            }

            // Whatever discovery reported is a reading taken while its own send loop had the path
            // loaded, and both profiles inflate it in their own way: the burst keeps hundreds of
            // requests outstanding at once, and a paced pass keeps the loop running for seconds
            // (ICMPPinger and SweepProfile carry the figures). Re-probing only the hosts that
            // answered, spaced out, is what makes the Ping column comparable to ping(8). On a LAN
            // that is one pass costing a fraction of a second.
            //
            // Through a router it takes rounds: one spaced pass does not reach every host on a
            // path that drops packets, and what a host it misses is left with is worth a second
            // try — `SweepProfile.discardsUnmeasuredLatency` is where that is decided and has the
            // figures. Each round asks only the hosts still without one, so the second is a handful
            // of packets, and formUnion keeps what a round already produced rather than replacing
            // it for no reason.
            if let pinger, !answered.isEmpty, !Task.isCancelled {
                var timed = SweepResult()
                var lastRound = 1
                for round in 1...profile.latencyRounds {
                    guard !Task.isCancelled else { break }
                    // Wait out the window the last round gave up on before sending anything more.
                    // A reply that missed it is still in flight, and `sentAt` is keyed by address:
                    // collected here it is timed against the send it answers, which is the figure
                    // it deserves, while collected after the next send it is timed against that one
                    // and reported as a fraction of what it was — 170 ms for a 1.2 s round trip,
                    // small enough that no ceiling can tell it from a fast host. Taking it here
                    // also drops the address off this round's list, so the mismatch has nothing
                    // left to happen to.
                    if round > 1 {
                        let late = await sweep(pinger) {
                            $0.drain(for: profile.latencyReplyTimeout)
                        }.filter(range.contains)
                        timed.formUnion(late)
                        await settle(timed)
                    }
                    let missing = answered.sorted().filter { timed.latencies[$0] == nil }
                    guard !missing.isEmpty else { break }
                    // Recorded here rather than at the top of the round, which is a round that has
                    // committed to sending rather than one that has merely begun. The first is
                    // always reached — `answered` is not empty and `timed` starts so — which is why
                    // the initial 1 needs no guard of its own.
                    lastRound = round
                    // A phase of its own on the bar. Without one the last thing the bar heard was
                    // discovery finishing at full, and this pass runs for seconds after that —
                    // long enough on a wide routed range to look finished while it is still going,
                    // which is when someone presses Stop and loses the rows the merge below has
                    // not added yet.
                    emit(.progress(ScanProgress(phase: .timing,
                                                completed: answered.count - missing.count,
                                                total: answered.count, pass: round)))
                    // This pass only sends to hosts that already answered, so a new address turning
                    // up in it came from somewhere else: a late reply to an earlier round landing
                    // in this one's drain, or a reply to another process's request, which
                    // EchoPinger explains this socket is handed too. `settle` is what turns one
                    // into a row and into `answered`; the ARP merge at the end reads that set, so
                    // an address that never reached it would also lose the badge saying an echo
                    // came back from it.
                    let gap = profile.latencyGap(targets: missing.count)
                    let found = await sweep(pinger) {
                        $0.probe(missing, timeout: profile.latencyReplyTimeout, pacing: gap)
                    }.filter(range.contains)
                    timed.formUnion(found)
                    await settle(timed)
                }
                // A host every round missed keeps nothing. What discovery left on it is a reading
                // taken while its own send loop had the path loaded — 600 to 1,060 ms, measured,
                // for hosts that answer in 25 — and that is wrong by a factor rather than by a
                // margin. The rounds above exist because such a figure looks plausible enough to be
                // read as fact; leaving it on the rows they could not reach would keep exactly the
                // ones they were added for.
                //
                // Not when the pass was cut short, where `timed` is empty or partial through no
                // finding of its own and every row would lose its figure for nothing, and not on a
                // profile whose discovery bursts — `discardsUnmeasuredLatency` has why.
                if profile.discardsUnmeasuredLatency, !Task.isCancelled {
                    for address in answered where timed.latencies[address] == nil {
                        latencies.removeValue(forKey: address)
                        devices[address]?.latencyMilliseconds = nil
                    }
                }
                latencies.merge(timed.latencies) { _, fresh in fresh }
                // The round it actually reached, not the one it was allowed: a first round that
                // measured every host breaks out of the second, and saying "round 2" then would
                // report work that was never done.
                emit(.progress(ScanProgress(phase: .timing, completed: answered.count,
                                            total: answered.count, pass: lastRound)))
                for (address, milliseconds) in latencies {
                    devices[address]?.latencyMilliseconds = milliseconds
                }
                emit(.devices(ordered(devices)))
            }

            // Hosts that never answered but are in the ARP cache anyway, plus this Mac. A host
            // that drops every echo request still answers the address resolution the kernel does
            // on the way to one, because that is handled below whatever is filtering ICMP.
            var arpWasComplete = false
            if !Task.isCancelled {
                let (arp, complete) = await arpTable()
                arpWasComplete = complete
                var present = answered.union(arp.keys.filter(range.contains))
                if let network, range.contains(network.address) { present.insert(network.address) }
                // This Mac needs nothing done for it here. macOS keeps a permanent ARP entry for
                // the interface's own address — `192.168.34.101  6:34:e9:28:91:d  (none) (none)`
                // — so its MAC and vendor arrive the same way every other row's do.
                let added = merge(present, arp: arp, latencies: latencies, answered: answered,
                                  localAddress: network?.address, vendorDatabase: vendorDatabase,
                                  into: &devices)
                emit(.devices(ordered(devices)))
                for address in added { enqueue.yield(address) }
            }

            // Skipped where the ARP read above was cut short. The IPv6 merge matches replies to
            // existing rows by hardware address, so rows the torn read left without one would not
            // be recognised, and every host behind them would get a second row.
            if !Task.isCancelled, arpWasComplete, let network {
                let added = await discoverIPv6(on: network, vendorDatabase: vendorDatabase,
                                               devices: &devices, emit: emit)
                for id in added { enqueue.yield(id) }
            }
            enqueue.finish()
        }

        guard !Task.isCancelled else { return }

        let targets = ordered(devices).map { (id: $0.id, address: $0.reachableAddress) }
        if settings.portScanMode == .afterScan, !targets.isEmpty {
            await scanPorts(targets, settings: settings, emit: emit)
        }

        guard !Task.isCancelled else { return }
        emit(.finished(ScanSnapshot(range: range, network: network)))
    }

    // MARK: - IPv6

    /// Finds hosts over IPv6 and folds them into the list.
    ///
    /// Runs after the IPv4 half rather than beside it, and the order is load-bearing. A row is
    /// keyed by its IPv4 address wherever it has one, so a host that answers on both families has
    /// to already be on the list under that address by the time its IPv6 reply arrives. Probing
    /// the other way round would give it a second row, and folding the two together afterwards
    /// would take a row away from under whoever had selected it.
    ///
    /// Returns the ids of the rows this added, for the naming queue.
    private static func discoverIPv6(
        on network: LocalNetwork,
        vendorDatabase: OUIDatabase,
        devices: inout [String: Device],
        emit: @escaping @Sendable (ScanEvent) -> Void
    ) async -> [String] {
        guard let pinger = ICMPv6Pinger() else { return [] }

        var responders = Set<String>()
        for round in 1...ipv6Rounds {
            guard !Task.isCancelled else { break }
            emit(.progress(ScanProgress(phase: .probingIPv6, completed: round - 1,
                                        total: ipv6Rounds, pass: round)))
            responders.formUnion(await sweep(pinger) {
                $0.probeAllNodes(on: network.interface, timeout: ipv6ReplyTimeout)
            }.responded)
        }
        emit(.progress(ScanProgress(phase: .probingIPv6, completed: ipv6Rounds, total: ipv6Rounds)))
        guard !Task.isCancelled else { return [] }

        // Read after the sweep rather than before it. A run that read it first left 3 of its 57
        // replies with no hardware address to match on; a run that read it afterwards had one for
        // all 63. Those are two runs against a moving network, so what they settle is which order
        // to prefer, not why — resolution the sweep provoked, neighbour discovery happening
        // anyway, and entries that were already there cannot be told apart from here.
        //
        // Limited to the interface the probe went out on. ndp(8) reports every interface at once,
        // including this Mac's own awdl0 and llw0 entries and whatever a VPN left behind, and a
        // neighbour on one of those cannot be what answered a probe sent on this one.
        //
        // A read that did not finish is refused rather than used. Below, a reply the table has no
        // entry for is taken to be a machine nothing else has seen, and half a table would answer
        // that for every host the read stopped short of — one duplicate row each.
        //
        // An empty table is refused on the same reasoning rather than on a claim about when one
        // can occur. Hosts answered this segment a moment ago; a cache with nothing in it for the
        // interface they answered on is a cache that cannot be matched against, and stopping is
        // the option that does not invent rows.
        guard let table = await neighbourTable(on: network.interface), !table.isEmpty else {
            return []
        }

        // This Mac answers the all-nodes group like any other node on the segment. ndp(8) does
        // list its own interface — `fe80::…%en0 … en0 permanent R` — so the MAC below would match
        // it to a row, but only to whichever row already holds this Mac's hardware address, and
        // there is none when the target does not cover this Mac. Handling it here keeps a scan of
        // some other segment from turning up the machine running it.
        let ownAddresses = Set(network.ipv6Addresses)

        var idByMAC: [String: String] = [:]
        for (id, device) in devices where device.hasMACAddress { idByMAC[device.macAddress] = id }

        var added: [String] = []
        for address in responders.sorted() {
            if ownAddresses.contains(address) {
                // This Mac's row is the IPv4 one the sweep already made. Where the target does not
                // cover this Mac there is no row for it, and its own reply is not a discovery — a
                // scan of some other segment should not turn up the machine running it.
                devices[network.address]?.add(ipv6: [address])
                devices[network.address]?.discovery.insert(.icmpv6Echo)
                continue
            }

            // The hardware address is the only thing that says whether this reply is a machine
            // already on the list, and one reply in the cache is not guaranteed just because the
            // cache has entries — a host answers a multicast probe without the kernel having had
            // to resolve it individually. A reply with no entry is taken at face value and gets a
            // row of its own, because losing it would lose exactly the host this sweep exists to
            // find. That a whole ndp(8) failure cannot arrive here is what the guard above buys.
            let mac = table.mac(for: address)
            let addresses = mac.map(table.addresses(for:)) ?? [address]

            if let mac, let existing = idByMAC[mac], var device = devices[existing] {
                device.add(ipv6: addresses)
                device.discovery.insert(.icmpv6Echo)
                devices[existing] = device
                continue
            }

            var device = Device(ipv6: address, macAddress: mac ?? "—",
                                vendor: mac.map(vendorDatabase.vendor(for:)) ?? OUIDatabase.unknownVendor,
                                discovery: [.icmpv6Echo])
            device.add(ipv6: addresses)
            devices[device.id] = device
            if let mac { idByMAC[mac] = device.id }
            added.append(device.id)
        }

        // Addresses for rows that did not answer the multicast probe. This is all the neighbour
        // cache is ever used for on its own — see NeighbourCache on why it does not get to say a
        // device exists.
        for (id, device) in devices where device.hasMACAddress {
            let addresses = table.addresses(for: device.macAddress)
            guard !addresses.isEmpty else { continue }
            devices[id]?.add(ipv6: addresses)
            devices[id]?.discovery.insert(.ndpCache)
        }
        // This Mac's own addresses come from the interface rather than from anyone's cache.
        devices[network.address]?.add(ipv6: network.ipv6Addresses)

        // The multicast rounds produce no usable round-trip time (ICMPv6Pinger says why), so the
        // rows with no IPv4 address to have been timed on get one spaced pass of their own. It is
        // a few dozen packets at most. Each is probed at the address it answered from, which is
        // its id, rather than at whichever of its addresses reads best in the table.
        //
        // On a socket of its own, with an identifier that cannot equal the sweep's, so that a
        // reply to one of the multicast rounds arriving late cannot be picked up here and timed
        // against what this pass just sent to that address.
        let ipv6Only = devices.values.filter { $0.ipv4 == nil }.map(\.id).sorted()
        if !ipv6Only.isEmpty, !Task.isCancelled,
           let timer = ICMPv6Pinger(identifier: ICMPv6Pinger.identifier(after: pinger.currentIdentifier)) {
            // The LAN profile's figures whatever the IPv4 range was: these hosts answered an
            // all-nodes probe on this interface, so they are on this Mac's own link by definition.
            let gap = SweepProfile.onLink.latencyGap(targets: ipv6Only.count)
            let timed = await sweep(timer) {
                $0.probe(ipv6Only, timeout: SweepProfile.onLink.latencyReplyTimeout, pacing: gap)
            }
            for (address, milliseconds) in timed.latencies {
                devices[address]?.latencyMilliseconds = milliseconds
            }
        }

        emit(.devices(ordered(devices)))
        return added
    }

    // MARK: - Sweeps

    /// Runs one blocking sweep, with Stop wired through to it.
    ///
    /// The pinger's loops run on BlockingWork, where Task.isCancelled reads false, so cancelling
    /// the scan cannot stop them on its own. A paced pass spends seconds inside a single call.
    private static func sweep<Pinger: EchoPinger>(
        _ pinger: Pinger,
        _ body: @escaping @Sendable (Pinger) -> SweepResult
    ) async -> SweepResult {
        await withTaskCancellationHandler {
            await BlockingWork.run { body(pinger) }
        } onCancel: {
            pinger.stop()
        }
    }

    /// Consumes addresses as discovery finds them, keeping `concurrency` lookups in flight.
    private static func resolveNames(
        _ identifiers: AsyncStream<String>,
        concurrency: Int,
        emit: @escaping @Sendable (ScanEvent) -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for await id in identifiers {
                if running >= max(1, concurrency) {
                    await group.next()
                    running -= 1
                }
                group.addTask {
                    emit(.identity(id, await identity(of: id)))
                }
                running += 1
            }
        }
    }

    private static func scanPorts(
        _ targets: [(id: String, address: String)],
        settings: ScanSettings,
        emit: @escaping @Sendable (ScanEvent) -> Void
    ) async {
        emit(.progress(ScanProgress(phase: .scanningPorts, completed: 0, total: targets.count)))
        var completed = 0
        // A sliding window rather than fixed batches: one firewalled host costs the full timeout,
        // and a batch would hold every other host in that batch behind it.
        let inFlight = max(1, settings.portScanConcurrency / PortScanner.standardPorts.count)
        await withTaskGroup(of: (String, Set<Int>).self) { group in
            var index = 0
            while index < min(inFlight, targets.count) {
                let target = targets[index]
                group.addTask { (target.id, await PortScanner.openPorts(host: target.address)) }
                index += 1
            }
            while let (id, open) = await group.next() {
                completed += 1
                emit(.ports(id, open))
                emit(.progress(ScanProgress(phase: .scanningPorts, completed: completed, total: targets.count)))
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                if index < targets.count {
                    let target = targets[index]
                    group.addTask { (target.id, await PortScanner.openPorts(host: target.address)) }
                    index += 1
                }
            }
        }
    }

    // MARK: - Assembling the list

    /// Adds anything not already known and returns just those addresses.
    ///
    /// `answered` is what separates a host that replied to an echo request from one the kernel
    /// merely resolved an address for on the way to sending it. Both are on this segment; only
    /// the first is reachable in the way the Ping column implies.
    ///
    /// `localAddress` is applied here rather than once at the end so that this Mac's row carries
    /// its badge from the first window it appears in. Marking it only after the final merge left
    /// the machine running the scan looking like any other host for the ten seconds the sweep
    /// takes, and unmarked altogether if the scan was stopped before then.
    private static func merge(
        _ addresses: some Sequence<String>,
        arp: [String: String],
        latencies: [String: Double],
        answered: Set<String>,
        localAddress: String?,
        vendorDatabase: OUIDatabase,
        into devices: inout [String: Device]
    ) -> [String] {
        var added: [String] = []
        for address in addresses {
            let mac = arp[address]
            var sources: Set<DiscoverySource> = []
            if answered.contains(address) { sources.insert(.icmpEcho) }
            if mac != nil { sources.insert(.arpCache) }
            if address == localAddress { sources.insert(.thisMac) }

            if var existing = devices[address] {
                var changed = false
                if !existing.hasMACAddress, let mac {
                    existing.macAddress = mac
                    existing.vendor = vendorDatabase.vendor(for: mac)
                    changed = true
                }
                if existing.latencyMilliseconds == nil, let latency = latencies[address] {
                    existing.latencyMilliseconds = latency
                    changed = true
                }
                if !sources.isSubset(of: existing.discovery) {
                    existing.discovery.formUnion(sources)
                    changed = true
                }
                if changed { devices[address] = existing }
                continue
            }
            devices[address] = Device(
                ipv4: address,
                macAddress: mac ?? "—",
                vendor: mac.map(vendorDatabase.vendor(for:)) ?? OUIDatabase.unknownVendor,
                latencyMilliseconds: latencies[address],
                discovery: sources
            )
            added.append(address)
        }
        return added
    }

    private static func ordered(_ devices: [String: Device]) -> [Device] {
        devices.values.sorted { $0.addressOrder < $1.addressOrder }
    }

    private static func pingFallback(_ batch: ArraySlice<String>, concurrency: Int) async -> SweepResult {
        var responsive = SweepResult()
        for start in stride(from: batch.startIndex, to: batch.endIndex, by: concurrency) {
            let slice = batch[start..<min(start + concurrency, batch.endIndex)]
            let found = await withTaskGroup(of: (String, Double)?.self, returning: [(String, Double)].self) { group in
                for host in slice {
                    group.addTask {
                        let output = await CommandRunner.run("/sbin/ping", ["-c", "1", "-W", "300", host], timeout: 1)
                        guard output.contains("1 packets received") else { return nil }
                        return (host, parsePingTime(output) ?? -1)
                    }
                }
                var values: [(String, Double)] = []
                for await value in group { if let value { values.append(value) } }
                return values
            }
            for (host, milliseconds) in found {
                responsive.responded.insert(host)
                if milliseconds >= 0 { responsive.latencies[host] = milliseconds }
            }
        }
        return responsive
    }

    private static func parsePingTime(_ output: String) -> Double? {
        guard let range = output.range(of: #"time=[0-9.]+"#, options: .regularExpression) else { return nil }
        return Double(output[range].dropFirst("time=".count))
    }

    /// `-l` rather than plain `-an`: the freshness of an entry is only in that form, and
    /// NeighbourCache says why reading it matters.
    ///
    /// A torn read is still used — half the entries is better than none for filling rows in — but
    /// the caller is told, because the IPv6 merge downstream reads a missing MAC as meaning the
    /// host is new and would give one a duplicate row.
    private static func arpTable() async -> (entries: [String: String], complete: Bool) {
        let result = await CommandRunner.runChecked("/usr/sbin/arp", ["-anl"], timeout: 2)
        return (NeighbourCache.parseARP(result.output), result.completed)
    }

    /// ndp reports the whole neighbour table at once, so it is read per scan rather than per host.
    ///
    /// nil where the command did not finish. Everything downstream reads a missing entry as
    /// meaning something — that this reply is from a machine nothing else has seen — so half a
    /// table is worse than none: it would answer that for every host the read was cut short of.
    private static func neighbourTable(on interface: String) async -> NeighbourTable? {
        let result = await CommandRunner.runChecked("/usr/sbin/ndp", ["-an"], timeout: 3)
        guard result.completed else { return nil }
        return NeighbourCache.parseNDP(result.output, interface: interface)
    }

    // MARK: - Naming

    private static func identity(of address: String) async -> DeviceIdentity {
        // dig(1) asks the configured unicast resolver, and no link-local address has a delegation
        // in ip6.arpa for it to find, so the whole child process can only ever come back empty for
        // one. getnameinfo goes through the system resolver instead, which asks mDNSResponder, and
        // that does answer for a host on this segment.
        guard IPv4.number(address) != nil else {
            return DeviceIdentity(mdnsName: await BlockingWork.run { systemName(of: address) })
        }
        async let names = reverseNames(address)
        async let smb = smbIdentity(address)
        let (resolved, share) = await (names, smb)
        return DeviceIdentity(dnsName: resolved.dns, mdnsName: resolved.mdns,
                              smbName: share.name, smbDomain: share.domain)
    }

    /// What the system resolver calls an IPv6 address, or "—".
    ///
    /// Measured at 200–300 ms for a host with an mDNS name and a flat 5 s for one without, which
    /// is the timeout mDNSResponder gives up after. That is why this is paced by the same setting
    /// as the child processes rather than run over every row at once.
    private static func systemName(of address: String) -> String {
        guard var socketAddress = IPv6.socketAddress(address) else { return "—" }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                getnameinfo(generic, socklen_t(MemoryLayout<sockaddr_in6>.size), &buffer,
                            socklen_t(buffer.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard result == 0 else { return "—" }
        // Through DNSName for the same reason dig's answers are: this is the resolver's
        // presentation form, so a name with a byte that has no spelling arrives escaped here too.
        let name = DNSName.decoded(IPv4.decodedCString(buffer))
        return name.isEmpty ? "—" : name
    }

    /// What the configured resolver calls this address, and what the host itself does.
    ///
    /// The two queries run one after the other rather than together. On the networks measured here
    /// the unicast one came back in 20–100 ms whether it had an answer or not, and its worst case
    /// is the 2 s CommandRunner allows it, so what running them in series buys is worth more than
    /// it costs: a row stays at two child processes in flight. Each parks a thread in BlockingWork,
    /// and the sweep's own passes are parked in the same pool, so naming wider than it needs to be
    /// is naming that delays discovery.
    ///
    /// The host is asked even when unicast DNS already returned a `.local` name. A suffix names a
    /// namespace and not a source: `.local` can come out of a configured zone, a cache, or a relay,
    /// none of which is evidence that the host answers to it now. So a relayed one is kept only as
    /// what to show when the host itself says nothing.
    private static func reverseNames(_ address: String) async -> (dns: String, mdns: String) {
        let dns = await digName(["+short", "-x", address])
        return (dns, DNSName.multicastName(dns: dns, responder: await responderName(address)))
    }

    /// One dig(1) query, or "—" where it did not answer one.
    ///
    /// Checked rather than read, because the output is being taken for a host name and dig says
    /// plenty on its way to failing: a server it cannot reach draws `;; connection timed out…`,
    /// which `DNSName` filters, and a fatal one draws
    /// `/usr/bin/dig: couldn't get address for '…': not found`, which it cannot — nothing marks
    /// that as a diagnostic except that dig then exits non-zero. Measured: 0 for an answer and for
    /// an empty one, 9 for a server that never replied.
    private static func digName(_ arguments: [String]) async -> String {
        let result = await CommandRunner.runChecked("/usr/bin/dig", arguments, timeout: 2)
        guard result.completed else { return DNSName.none }
        return DNSName.answer(in: result.output)
    }

    /// What the host's own mDNS responder calls itself, or "—".
    ///
    /// Asked of the host directly on port 5353 rather than through the system resolver. The
    /// resolver does answer for `.local`, but the query it sends out is multicast, and multicast
    /// does not cross a router — let alone a point-to-point tunnel. On a VPN-routed /24 measured
    /// here, dig(1), dscacheutil(1) and host(1) came back empty for every address they were tried
    /// on, while a unicast query to the host's own 5353 named 5 of those 7 and matched what LanScan
    /// showed for the same hosts. A whole-range scan of the same /24 later named 8.
    ///
    /// **A responder is allowed to refuse this.** RFC 6762 §5.5 has it answer a direct unicast
    /// query as it would a QU question, but SHOULD check that the source address shares a subnet
    /// with one of its interfaces and silently ignore the query when it does not — which is exactly
    /// the case being relied on here, since through a tunnel the source is this Mac's address on
    /// the far side of it. So this is not something a router can be expected to make work in
    /// general; it is that no responder met on any path measured here performed that check. The
    /// cost when one does is the second the query waits before giving up, and a row named by
    /// whatever else answered.
    ///
    /// One try is enough: 25 for 25 across five responders, because unlike the sweep this is a
    /// single exchange with no burst for the path to drop.
    ///
    /// `+short` sits ahead of `-x` rather than after it, and that is not a style choice: written
    /// after the query it belongs to it no longer suppresses the banner, so a silent host answers
    /// with five lines instead of one. Anywhere before `-x` does — `@server -p 5353 +short -x …`
    /// measures the same.
    ///
    /// Only `+short` behaves that way, and only when the query fails. `+timeout` and `+tries` were
    /// written after `-x` for a long time and were working: measured at 1.03 s against a port
    /// nothing listens on, where the defaults would have taken 15. So the rule is not the general
    /// one about global options preceding their queries — it is about the banner, whose text is
    /// settled when the first lookup is built. They lead here anyway, so that nothing about this
    /// call depends on knowing which of its options is the exception.
    private static func responderName(_ address: String) async -> String {
        await digName(["+short", "+timeout=1", "+tries=1",
                       "@\(address)", "-p", "5353", "-x", address])
    }

    /// Checked for the same reason the dig calls are, by a different route: smbutil finishes on its
    /// own even when the host does not answer — measured, exit 0 with `Operation timed out: unable
    /// to get status from …` — so what `completed` actually rules out here is CommandRunner's
    /// watchdog killing it part way. The parse below reads whatever bytes arrived as whole lines,
    /// and a read torn after `Server: PRIN` would name the host `PRIN`.
    private static func smbIdentity(_ address: String) async -> (name: String, domain: String) {
        let result = await CommandRunner.runChecked("/usr/bin/smbutil", ["status", address],
                                                    timeout: 2)
        guard result.completed else { return (DNSName.none, DNSName.none) }
        let output = result.output
        var name = "—", domain = "—"
        for line in output.split(separator: "\n") {
            let value = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard value.count == 2 else { continue }
            if value[0].localizedCaseInsensitiveContains("server") { name = value[1] }
            if value[0].localizedCaseInsensitiveContains("workgroup") || value[0].localizedCaseInsensitiveContains("domain") { domain = value[1] }
        }
        return (name, domain)
    }
}
