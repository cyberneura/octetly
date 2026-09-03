import Foundation
import Observation

@MainActor
@Observable
final class NetworkScanner {
    var devices: [Device] = []
    var isScanning = false
    var status = "Ready to scan"
    var progress: ScanProgress?
    var selectedDeviceID: Device.ID? {
        didSet { reconcileSelectionScan() }
    }
    /// The interface this Mac would scan from. Re-read rather than cached for the life of the
    /// app, since it changes with Wi-Fi and with a VPN coming up.
    var machine: LocalNetwork? = LocalNetwork.current()
    let ranges = ScanRangeStore()
    let settings = ScanSettingsStore()
    let annotations = AnnotationStore()

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var portTasks: [Device.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var namedCount = 0
    private let vendorDatabase = OUIDatabase.loadBundled()

    init() {
        // The third input to the selection-scan invariant. Wiring it here rather than in a view
        // is the point: every path that can change one of the three inputs now reaches the check
        // on its own, and a view cannot leave one out.
        settings.onChange = { [weak self] in self?.reconcileSelectionScan() }
    }

    func refreshMachine() {
        machine = LocalNetwork.current()
    }

    func scan() {
        guard !isScanning else { return }
        refreshMachine()
        guard let range = ranges.activeRange else {
            status = "No active IPv4 LAN interface found"
            return
        }
        cancelPortScans()
        // A scan reports what is on the network now. Carrying rows over would leave a host that
        // has since left the network looking present, and switching target would show the union
        // of both ranges rather than the one that was scanned.
        devices = []
        isScanning = true
        progress = nil
        namedCount = 0
        status = "Scanning \(range.text)…"

        let options = settings.settings
        scanTask = Task { [vendorDatabase] in
            for await event in ScanEngine.events(range: range, vendorDatabase: vendorDatabase, settings: options) {
                // Cancelling the task does not stop delivery: an AsyncStream hands over whatever
                // is already buffered first, and next() only notices cancellation when it has to
                // suspend. Without this break, events keep arriving after stop() has reset
                // everything and put the rows back the way it found them — the port column
                // returns to "Scanning…" and the progress bar never clears.
                if Task.isCancelled { break }
                switch event {
                case .progress(let value):
                    progress = value
                    // The port phase reports per host, so this is where every row is told it is
                    // being looked at rather than waiting for its own result.
                    if value.phase == .scanningPorts, value.completed == 0 { markPortsScanning() }
                    status = label(for: value)
                case .devices(let list):
                    merge(discovered: list)
                case .identity(let id, let identity):
                    apply(identity, to: id)
                case .ports(let id, let open):
                    apply(ports: open, to: id)
                case .finished(let snapshot):
                    finish(snapshot)
                }
            }
            // Reached either by the stream finishing or by the break above. Cancellation leaves
            // the flags to stop(), which has already set them.
            guard !Task.isCancelled else { return }
            progress = nil
            isScanning = false
        }
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
        cancelPortScans()
        resetScanningPorts()
        progress = nil
        isScanning = false
        status = "Scan stopped"
    }

    /// Restores the invariant "the selected device has had its ports scanned, if the settings ask
    /// for that".
    ///
    /// Its inputs are the selection, the device list and the port scan mode, so it is re-checked
    /// whenever any of the three moves: from `selectedDeviceID`'s observer, from `publish`, and
    /// from the settings store's callback. Written as a condition to restore rather than as a
    /// handler for one event, because every defect found in this area was a state change that
    /// nobody had thought to hang a handler on.
    func reconcileSelectionScan() {
        guard settings.settings.portScanMode == .onSelection, let id = selectedDeviceID else {
            // The other half of the condition. Deselecting, or turning the mode off, means no
            // host qualifies any more — and a scan already running for one that no longer does
            // has to stop. Stating only the positive half left it running to completion.
            cancelPortScans()
            return
        }
        scanPorts(for: id)
    }

    func scanPorts(for id: Device.ID) {
        // Cancelled before the guards, not after: the selection has moved regardless of whether
        // the newly selected row needs scanning, and returning early for one that was already
        // scanned would leave the previous host running.
        //
        // One host at a time, so that clicking down a list does not leave a scan running per row.
        // Cancelling is not immediate: the connect attempts are already blocked in poll() and run
        // to their own timeout, so two hosts' sockets can overlap for a fraction of a second. The
        // port scan concurrency setting governs the after-scan sweep, which is the only place a
        // figure like that has anything to pace.
        cancelPortScans(except: id)
        guard portTasks[id] == nil,
              let index = devices.firstIndex(where: { $0.id == id }),
              devices[index].portScanState != .done else { return }

        devices[index].portScanState = .scanning
        let address = devices[index].reachableAddress
        portTasks[id] = Task {
            let open = await PortScanner.openPorts(host: address)
            // Checked before touching portTasks: a cancelled task must not clear the entry a
            // newer scan of the same host has since put there, which would let a second scan
            // start and escape cancellation.
            guard !Task.isCancelled else { return }
            portTasks[id] = nil
            apply(ports: open, to: id)
        }
    }

    /// Renames a device, or clears the name when `name` is blank.
    func rename(_ id: Device.ID, to name: String) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var annotation = annotations[devices[index].annotationKey]
        annotation.name = trimmed
        annotations[devices[index].annotationKey] = annotation
        devices[index].customName = trimmed
    }

    // MARK: - Applying scan events

    /// Discovery reports addresses, MACs, vendors, round-trip times and how each row was found.
    /// Names and ports arrive on their own events, often earlier, and must survive a discovery
    /// update landing on top.
    private func merge(discovered list: [Device]) {
        var byID = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for incoming in list {
            if var existing = byID[incoming.id] {
                // Always taken, not filled in only when missing: the engine re-times every host
                // in a spaced pass after the sweep, and keeping the first value would pin the
                // column to the inflated figure the burst produced.
                if let latency = incoming.latencyMilliseconds {
                    existing.latencyMilliseconds = latency
                }
                if !existing.hasMACAddress, incoming.hasMACAddress {
                    existing.macAddress = incoming.macAddress
                    existing.vendor = incoming.vendor
                }
                existing.add(ipv6: incoming.ipv6Addresses)
                existing.discovery.formUnion(incoming.discovery)
                byID[incoming.id] = existing
            } else {
                byID[incoming.id] = incoming
            }
        }
        publish(Array(byID.values))
    }

    private func apply(_ identity: DeviceIdentity, to id: Device.ID) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].dnsName = identity.dnsName
        devices[index].mdnsName = identity.mdnsName
        devices[index].smbName = identity.smbName
        devices[index].smbDomain = identity.smbDomain
        devices[index].hostname = identity.hostname
        if identity.hostname != "—" { namedCount += 1 }
    }

    private func apply(ports: Set<Int>, to id: Device.ID) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].openPorts = ports
        devices[index].portScanState = .done
    }

    private func markPortsScanning() {
        for index in devices.indices where devices[index].portScanState == .pending {
            devices[index].portScanState = .scanning
        }
    }

    private func publish(_ list: [Device]) {
        // Everything derived from outside the scan is applied here, in one pass over the list
        // that is about to be shown, rather than in whichever merge branch happened to create
        // each row.
        annotations.consolidate(list)
        devices = list
            .map { device in
                var device = device
                device.customName = annotations[device.annotationKey].name
                return device
            }
            .sorted { $0.addressOrder < $1.addressOrder }
        // Only once the scan is done. These lists are cumulative and partial — a host absent from
        // one of them may simply not have answered yet, and dropping the selection there would
        // close the detail pane on a device that turns up a moment later.
        if !isScanning { pruneSelection() }
        reconcileSelectionScan()
    }

    private func pruneSelection() {
        guard let id = selectedDeviceID, !devices.contains(where: { $0.id == id }) else { return }
        selectedDeviceID = nil
    }

    private func finish(_ snapshot: ScanSnapshot) {
        // The list is final here, so a selection pointing at nothing really is stale.
        pruneSelection()
        let interface = snapshot.network.map { " on \($0.interface)" } ?? ""
        status = "Scanned \(snapshot.range.text)\(interface) · \(devices.count.formatted()) found"
    }

    private func label(for progress: ScanProgress) -> String {
        let completed = progress.completed.formatted()
        let total = progress.total.formatted()
        // "round", matching the README: "pass" is what it calls the separate latency timing pass,
        // and using the same word for both is what made the old wording ambiguous.
        let pass = progress.pass > 1 ? " (round \(progress.pass))" : ""
        let named = namedCount > 0 ? " · \(namedCount.formatted()) named" : ""
        return "\(progress.phase.label)\(pass) \(completed) of \(total)…\(named)"
    }

    /// Cancels the per-selection scans, and only those.
    ///
    /// Resets exactly the rows whose task it cancelled. The after-scan sweep marks rows .scanning
    /// without a task here, and this runs on every published list while that sweep is going, so
    /// clearing every .scanning row would wipe the indicator off rows still being worked on.
    private func cancelPortScans(except keep: Device.ID? = nil) {
        for (id, task) in portTasks where id != keep {
            task.cancel()
            portTasks[id] = nil
            // Nothing else moves a row out of .scanning, so a cancelled scan would otherwise
            // leave its row claiming to be busy for the life of the app.
            guard let index = devices.firstIndex(where: { $0.id == id }),
                  devices[index].portScanState == .scanning else { continue }
            devices[index].portScanState = .pending
        }
    }

    /// Clears every busy row, for when the engine's own sweep has gone away with them mid-flight.
    private func resetScanningPorts() {
        for index in devices.indices where devices[index].portScanState == .scanning {
            devices[index].portScanState = .pending
        }
    }
}
