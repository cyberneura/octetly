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
        case scanningPorts

        var label: String {
            switch self {
            case .probing: "Probing"
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
    case identity(String, DeviceIdentity)
    case neighbours([String: String])
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

    static func parseARP(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        let expression = try? NSRegularExpression(pattern: #"\((\d+\.\d+\.\d+\.\d+)\) at ([0-9a-fA-F:]+)"#)
        for line in output.split(separator: "\n") {
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = expression?.firstMatch(in: text, range: range), match.numberOfRanges == 3,
                  let ipRange = Range(match.range(at: 1), in: text),
                  let macRange = Range(match.range(at: 2), in: text) else { continue }
            result[String(text[ipRange])] = normalizeMAC(String(text[macRange]))
        }
        return result
    }

    private static func scan(
        range: ScanRange,
        vendorDatabase: OUIDatabase,
        settings: ScanSettings,
        emit: @escaping @Sendable (ScanEvent) -> Void
    ) async {
        let hosts = range.addressList()
        let network = LocalNetwork.current()
        var live = Set<String>()
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
                    var answered: SweepResult
                    if let pinger {
                        answered = await sweep(pinger) {
                            $0.probe(window, timeout: windowReplyTimeout, pacing: pacing)
                        }
                    } else {
                        // Only reached where the ICMP socket could not be opened at all.
                        answered = await pingFallback(window, concurrency: settings.deviceConcurrency)
                    }
                    // A multi-homed host answers from whichever address its routing table picks,
                    // which can be one that was never probed and outside the range being scanned.
                    answered = answered.filter(range.contains)
                    if !answered.responded.isEmpty {
                        live.formUnion(answered.responded)
                        latencies.merge(answered.latencies) { existing, _ in existing }
                        let arp = await arpTable()
                        let added = merge(answered.responded, arp: arp, latencies: latencies,
                                          vendorDatabase: vendorDatabase, into: &devices)
                        emit(.devices(ordered(devices)))
                        for address in added { enqueue.yield(address) }
                    }
                    emit(.progress(ScanProgress(phase: .probing, completed: window.endIndex,
                                                total: pending.count, pass: pass)))
                }

                guard !Task.isCancelled else { break }
                if let pinger {
                    let late = await sweep(pinger) { $0.drain(for: finalReplyTimeout) }
                        .filter(range.contains)
                    live.formUnion(late.responded)
                    latencies.merge(late.latencies) { existing, _ in existing }
                }
                pending = pending.filter { !live.contains($0) }
            }

            // The burst that finds hosts also inflates their round-trip times, because hundreds
            // of requests are outstanding at once (ICMPPinger carries the figures). One spaced
            // pass over only the hosts that answered costs a fraction of a second and gives a
            // number comparable to what ping(8) reports for the same host.
            if let pinger, !live.isEmpty, !Task.isCancelled {
                let sorted = live.sorted()
                let measured = await sweep(pinger) {
                    $0.probe(sorted, timeout: latencyReplyTimeout, pacing: latencyPacing)
                }
                // A host that stayed silent through every round can answer here, either late or
                // because this pass is the first probe it did not lose. Folding the responders
                // back into `live` is what gets it a row at all; without it the address is only
                // in `measured` and nothing downstream looks there.
                let timed = measured.filter(range.contains)
                live.formUnion(timed.responded)
                latencies.merge(timed.latencies) { _, fresh in fresh }
                for (address, milliseconds) in latencies {
                    devices[address]?.latencyMilliseconds = milliseconds
                }
                emit(.devices(ordered(devices)))
            }

            // Hosts that never answered but are in the neighbour cache anyway, plus this Mac.
            if !Task.isCancelled {
                var arp = await arpTable()
                live.formUnion(arp.keys.filter(range.contains))
                if let network, range.contains(network.address) {
                    live.insert(network.address)
                    // A machine does not ARP itself, so its own row would be the one row with no
                    // MAC and no vendor — while the sidebar shows both, from the same interface.
                    if let mac = network.macAddress { arp[network.address] = mac }
                }
                let added = merge(live, arp: arp, latencies: latencies,
                                  vendorDatabase: vendorDatabase, into: &devices)
                emit(.devices(ordered(devices)))
                for address in added { enqueue.yield(address) }
            }
            enqueue.finish()
        }

        guard !Task.isCancelled else { return }
        // ndp reports the whole neighbour table at once, so it is read here rather than per host,
        // and after the sweep because that is what populated it.
        emit(.neighbours(await neighbourTable()))

        let targets = ordered(devices).map(\.ipv4)
        if settings.portScanMode == .afterScan, !targets.isEmpty {
            await scanPorts(targets, settings: settings, emit: emit)
        }

        guard !Task.isCancelled else { return }
        emit(.finished(ScanSnapshot(range: range, network: network)))
    }

    /// Runs one blocking sweep, with Stop wired through to it.
    ///
    /// The pinger's loops run on BlockingWork, where Task.isCancelled reads false, so cancelling
    /// the scan cannot stop them on its own. A paced pass spends seconds inside a single call.
    private static func sweep(
        _ pinger: ICMPPinger,
        _ body: @escaping @Sendable (ICMPPinger) -> SweepResult
    ) async -> SweepResult {
        await withTaskCancellationHandler {
            await BlockingWork.run { body(pinger) }
        } onCancel: {
            pinger.stop()
        }
    }

    /// Consumes addresses as discovery finds them, keeping `concurrency` lookups in flight.
    private static func resolveNames(
        _ addresses: AsyncStream<String>,
        concurrency: Int,
        emit: @escaping @Sendable (ScanEvent) -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for await address in addresses {
                if running >= max(1, concurrency) {
                    await group.next()
                    running -= 1
                }
                group.addTask {
                    emit(.identity(address, await identity(of: address)))
                }
                running += 1
            }
        }
    }

    private static func scanPorts(
        _ targets: [String],
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
                let host = targets[index]
                group.addTask { (host, await PortScanner.openPorts(host: host)) }
                index += 1
            }
            while let (address, open) = await group.next() {
                completed += 1
                emit(.ports(address, open))
                emit(.progress(ScanProgress(phase: .scanningPorts, completed: completed, total: targets.count)))
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                if index < targets.count {
                    let host = targets[index]
                    group.addTask { (host, await PortScanner.openPorts(host: host)) }
                    index += 1
                }
            }
        }
    }

    /// Adds anything not already known and returns just those addresses.
    private static func merge(
        _ addresses: some Sequence<String>,
        arp: [String: String],
        latencies: [String: Double],
        vendorDatabase: OUIDatabase,
        into devices: inout [String: Device]
    ) -> [String] {
        var added: [String] = []
        for address in addresses {
            let mac = arp[address]
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
                if changed { devices[address] = existing }
                continue
            }
            devices[address] = Device(
                ipv4: address,
                macAddress: mac ?? "—",
                vendor: mac.map(vendorDatabase.vendor(for:)) ?? OUIDatabase.unknownVendor,
                latencyMilliseconds: latencies[address]
            )
            added.append(address)
        }
        return added
    }

    private static func ordered(_ devices: [String: Device]) -> [Device] {
        devices.values.sorted { $0.addressValue < $1.addressValue }
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

    private static func arpTable() async -> [String: String] {
        parseARP(await CommandRunner.run("/usr/sbin/arp", ["-an"], timeout: 2))
    }

    private static func neighbourTable() async -> [String: String] {
        var result: [String: String] = [:]
        let output = await CommandRunner.run("/usr/sbin/ndp", ["-an"], timeout: 3)
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count >= 2, fields[1].contains(":") else { continue }
            let mac = normalizeMAC(fields[1])
            let address = fields[0].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            // Keep the first entry per MAC: link-local addresses sort ahead of the routable ones
            // and are the reliable half of what ndp reports on a LAN.
            if result[mac] == nil { result[mac] = address }
        }
        return result
    }

    private static func identity(of address: String) async -> DeviceIdentity {
        async let names = reverseNames(address)
        async let smb = smbIdentity(address)
        let (resolved, share) = await (names, smb)
        return DeviceIdentity(dnsName: resolved.dns, mdnsName: resolved.mdns,
                              smbName: share.name, smbDomain: share.domain)
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

    private static func normalizeMAC(_ value: String) -> String {
        value.split(separator: ":").map { $0.count == 1 ? "0\($0)" : String($0) }.joined(separator: ":").uppercased()
    }
}
