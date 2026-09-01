import Foundation
import Observation

@MainActor
@Observable
final class NetworkScanner {
    var devices: [Device] = []
    var isScanning = false
    var status = "Ready to scan"
    var selectedDeviceID: Device.ID?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    private let vendorDatabase = OUIDatabase.loadBundled()

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        status = "Finding the active LAN…"
        scanTask = Task {
            guard let snapshot = await ScanEngine.scan(vendorDatabase: vendorDatabase) else {
                if !Task.isCancelled { status = "No active IPv4 LAN interface found" }
                isScanning = false
                return
            }
            guard !Task.isCancelled else { return }
            devices = snapshot.devices
            selectedDeviceID = selectedDeviceID ?? devices.first?.id
            status = "Scanned \(snapshot.network.interface) (\(snapshot.network.address))"
            isScanning = false
        }
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        status = "Scan stopped"
    }
}
