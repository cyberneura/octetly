import Foundation
import Observation

enum PortScanMode: String, CaseIterable, Sendable, Identifiable {
    case off
    case onSelection
    case afterScan

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Never"
        case .onSelection: "When a device is selected"
        case .afterScan: "After the scan finishes"
        }
    }
}

struct ScanSettings: Sendable, Equatable {
    var deviceConcurrency: Int = 24
    var portScanConcurrency: Int = 24
    var portScanMode: PortScanMode = .onSelection
}

@MainActor
@Observable
final class ScanSettingsStore {
    static let concurrencyRange = 4...128

    var settings: ScanSettings {
        didSet {
            persist()
            onChange?()
        }
    }

    /// Notified after any change. NetworkScanner uses it to re-check what a setting implies about
    /// the current selection, so that no view has to remember to.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded = ScanSettings()
        // A missing key reads back as 0, which would silently mean "no concurrency at all".
        if let stored = defaults.object(forKey: "DeviceConcurrency") as? Int {
            loaded.deviceConcurrency = Self.concurrencyRange.clamping(stored)
        }
        if let stored = defaults.object(forKey: "PortScanConcurrency") as? Int {
            loaded.portScanConcurrency = Self.concurrencyRange.clamping(stored)
        }
        if let stored = defaults.string(forKey: "PortScanMode"), let mode = PortScanMode(rawValue: stored) {
            loaded.portScanMode = mode
        }
        settings = loaded
    }

    private func persist() {
        defaults.set(settings.deviceConcurrency, forKey: "DeviceConcurrency")
        defaults.set(settings.portScanConcurrency, forKey: "PortScanConcurrency")
        defaults.set(settings.portScanMode.rawValue, forKey: "PortScanMode")
    }
}

extension ClosedRange where Bound == Int {
    func clamping(_ value: Int) -> Int { Swift.min(Swift.max(value, lowerBound), upperBound) }
}
