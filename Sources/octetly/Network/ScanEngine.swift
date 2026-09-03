import Darwin
import Foundation

struct ScanSnapshot: Sendable {
    let range: ScanRange
    let network: LocalNetwork?
}

struct DeviceIdentity: Sendable, Hashable {
    var dnsName = "—"
    var mdnsName = "—"
    var smbName = "—"
    var smbDomain = "—"

    var hostname: String {
        if dnsName != "—" { return dnsName }
        if mdnsName != "—" { return mdnsName }
        return smbName
    }
}

struct ScanProgress: Sendable {
    enum Phase: Sendable {
        case probing
        case probingIPv6
        case scanningPorts

        var label: String {
            switch self {
            case .probing: "Probing"
            case .probingIPv6: "Probing IPv6"
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
    // together. This is spent in full on every pass — drain has no idle-gap exit — so it is
    // three times this much of fixed cost per scan.
    private static let finalReplyTimeout: TimeInterval = 1.5

    private static let discoveryPasses = 3

    // The first pass empties the socket as fast as it will take packets — 254 addresses in about
    // 11 ms — which a switched LAN answers in full. A tunnelled or rate-limited path drops most
    // of that burst (ICMPPinger carries the measurements), so the retries are spread out. The gap
    // is derived from a time budget rather than fixed, because a fixed one that suits a /24 would
    // put a /16 in the region of ten minutes.
    private static let retryPacingBudget: TimeInterval = 3.0
    private static let retryPacingCeiling: TimeInterval = 0.01

    // Spacing for the timing pass. Only hosts that already answered are re-probed, so this is a
    // few dozen packets rather than the whole range.
    private static let latencyPacing: TimeInterval = 0.002
    private static let latencyReplyTimeout: TimeInterval = 0.4

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
            /// goes through here, so none can collect one and stop halfway. The timing pass after
            /// discovery does not — it re-probes addresses that are already rows, and hands its
            /// own responders to `answered` for the final merge to pick up.
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

            for pass in 1...discoveryPasses {
                guard !Task.isCancelled, !pending.isEmpty else { break }
                let windowSize = ICMPPinger.sendWindow(for: pending.count)
                let pacing = pass == 1 ? 0 : min(retryPacingCeiling, retryPacingBudget / Double(pending.count))
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

            // The burst that finds hosts also inflates their round-trip times, because hundreds
            // of requests are outstanding at once (ICMPPinger carries the figures). One spaced
            // pass over only the hosts that answered costs a fraction of a second and gives a
            // number comparable to what ping(8) reports for the same host.
            if let pinger, !answered.isEmpty, !Task.isCancelled {
                let sorted = answered.sorted()
                let measured = await sweep(pinger) {
                    $0.probe(sorted, timeout: latencyReplyTimeout, pacing: latencyPacing)
                }
                // This pass only sends to hosts that already answered, so a new address turning up
                // in it came from somewhere else: a late reply to an earlier round landing in this
                // one's drain, or a reply to another process's request, which EchoPinger explains
                // this socket is handed too. Either way, folding the responders back into
                // `answered` is what gets it a row — the ARP merge below builds its list from that
                // set, so an address only in `measured` would have nothing look for it.
                let timed = measured.filter(range.contains)
                answered.formUnion(timed.responded)
                latencies.merge(timed.latencies) { _, fresh in fresh }
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
            let timed = await sweep(timer) {
                $0.probe(ipv6Only, timeout: latencyReplyTimeout, pacing: latencyPacing)
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
        let name = IPv4.decodedCString(buffer).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return name.isEmpty ? "—" : name
    }

    private static func reverseNames(_ address: String) async -> (dns: String, mdns: String) {
        let output = await CommandRunner.run("/usr/bin/dig", ["+short", "-x", address], timeout: 2)
        let dns = output.split(separator: "\n").first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) } ?? "—"
        let mdns = dns.hasSuffix(".local") ? dns : "—"
        return (dns.isEmpty ? "—" : dns, mdns)
    }

    private static func smbIdentity(_ address: String) async -> (name: String, domain: String) {
        let output = await CommandRunner.run("/usr/bin/smbutil", ["status", address], timeout: 2)
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
