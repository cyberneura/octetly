import Foundation
import Observation

@MainActor
@Observable
final class NetworkScanner {
    var devices: [Device] = []
    var isScanning = false
    var status = "Ready to scan"
    var selectedDeviceID: Device.ID?

    func scan() { status = "Scanner is being prepared…" }

    func stop() {
        isScanning = false
        status = "Scan stopped"
    }
}
