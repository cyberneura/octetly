import Foundation
import Observation

@MainActor
@Observable
final class NetworkScanner {
    var devices: [Device] = []
    var isScanning = false
    var status = "Ready to scan"
    var progress: ScanProgress?
    var selectedDeviceID: Device.ID?
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
                case .identity(let address, let identity):
                    apply(identity, to: address)
                case .neighbours(let table):
                    applyNeighbours(table)
                case .ports(let address, let open):
                    apply(ports: open, to: address)
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
        progress = nil
        isScanning = false
        status = "Scan stopped"
    }

    /// Runs a port scan for the selected device when the settings ask for one on selection.
    func portScanSelectionIfNeeded() {
        guard settings.settings.portScanMode == .onSelection, let id = selectedDeviceID else { return }
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
        let address = devices[index].ipv4
        portTasks[id] = Task {
            let open = await PortScanner.openPorts(host: address)
            // Checked before touching portTasks: a cancelled task must not clear the entry a
            // newer scan of the same host has since put there, which would let a second scan
            // start and escape cancellation.
            guard !Task.isCancelled else { return }
            portTasks[id] = nil
            apply(ports: open, to: address)
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

    /// Discovery reports addresses, MACs, vendors and round-trip times. Names and ports arrive on
    /// their own events, often earlier, and must survive a discovery update landing on top.
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
                    let addressKey = existing.annotationKey
                    existing.macAddress = incoming.macAddress
                    existing.vendor = incoming.vendor
                    // The key is the MAC once there is one, so anything filed under the address
                    // moves with it — otherwise a name typed before ARP caught up would still be
                    // stored, just never looked for again.
                    annotations.migrate(from: addressKey, to: existing.annotationKey)
                    existing.customName = annotations[existing.annotationKey].name
                }
                byID[incoming.id] = existing
            } else {
                var fresh = incoming
                // A rediscovered row can arrive with its MAC already filled in, skipping the
                // address-keyed phase entirely, so the same carry-over has to happen here.
                annotations.migrate(from: fresh.addressAnnotationKey, to: fresh.annotationKey)
                fresh.customName = annotations[fresh.annotationKey].name
                byID[incoming.id] = fresh
            }
        }
        publish(Array(byID.values))
    }

    private func apply(_ identity: DeviceIdentity, to address: String) {
        guard let index = devices.firstIndex(where: { $0.ipv4 == address }) else { return }
        devices[index].dnsName = identity.dnsName
        devices[index].mdnsName = identity.mdnsName
        devices[index].smbName = identity.smbName
        devices[index].smbDomain = identity.smbDomain
        devices[index].hostname = identity.hostname
        if identity.hostname != "—" { namedCount += 1 }
    }

    private func applyNeighbours(_ table: [String: String]) {
        for index in devices.indices where devices[index].hasMACAddress {
            if let address = table[devices[index].macAddress] { devices[index].ipv6 = address }
        }
    }

    private func apply(ports: Set<Int>, to address: String) {
        guard let index = devices.firstIndex(where: { $0.ipv4 == address }) else { return }
        devices[index].openPorts = ports
        devices[index].portScanState = .done
    }

    private func markPortsScanning() {
        for index in devices.indices where devices[index].portScanState == .pending {
            devices[index].portScanState = .scanning
        }
    }

    private func publish(_ list: [Device]) {
        let own = machine?.address
        devices = list
            .map { device in
                var device = device
                device.isLocalMachine = device.ipv4 == own
                return device
            }
            .sorted { $0.addressValue < $1.addressValue }
        if let id = selectedDeviceID, !devices.contains(where: { $0.id == id }) {
            selectedDeviceID = nil
        }
        // A selection that survives a rescan keeps the same ID, so the view's onChange never
        // fires and the row it points at would sit unscanned. Safe to call on every update: the
        // guards in scanPorts make it a no-op once one is running or finished.
        portScanSelectionIfNeeded()
    }

    private func finish(_ snapshot: ScanSnapshot) {
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

    private func cancelPortScans(except keep: Device.ID? = nil) {
        for (id, task) in portTasks where id != keep {
            task.cancel()
            portTasks[id] = nil
        }
        // Nothing else ever moves a row out of .scanning, so a cancelled scan would leave its
        // row claiming to be busy for the life of the app.
        resetScanningPorts(except: keep)
    }

    private func resetScanningPorts(except keep: Device.ID? = nil) {
        for index in devices.indices
        where devices[index].portScanState == .scanning && devices[index].id != keep {
            devices[index].portScanState = .pending
        }
    }
}
