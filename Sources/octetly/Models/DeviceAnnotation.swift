import Foundation
import Observation

struct DeviceAnnotation: Codable, Sendable, Hashable {
    var name = ""
    var note = ""

    var isEmpty: Bool { name.isEmpty && note.isEmpty }
}

@MainActor
@Observable
final class AnnotationStore {
    private static let key = "DeviceAnnotations"

    private(set) var entries: [String: DeviceAnnotation]

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = defaults.data(forKey: Self.key) ?? Data()
        entries = (try? JSONDecoder().decode([String: DeviceAnnotation].self, from: data)) ?? [:]
    }

    subscript(key: String) -> DeviceAnnotation {
        get { entries[key] ?? DeviceAnnotation() }
        set {
            // An emptied entry is removed rather than stored blank, so a key that no longer means
            // anything does not keep a row alive in the file forever.
            if newValue.isEmpty { entries.removeValue(forKey: key) } else { entries[key] = newValue }
            persist()
        }
    }

    /// Brings every device's entry onto the key that now identifies it.
    ///
    /// A row starts out keyed by address and switches to its MAC as soon as the neighbour cache
    /// catches up, which is seconds later on a first scan. Anything typed in that window would
    /// otherwise stay filed under the address and simply stop being displayed.
    ///
    /// Done once against the published list rather than at each point a MAC can arrive. There is
    /// more than one such point — a row can gain its MAC mid-scan, or turn up in a later scan
    /// with it already known — and handling them one at a time is what left the second path
    /// unhandled twice over. Anything already filed under the MAC wins: that one was entered
    /// against the identity that lasted.
    func consolidate(_ devices: [Device]) {
        for device in devices where device.hasMACAddress {
            let old = device.addressAnnotationKey
            let new = device.annotationKey
            guard self[new].isEmpty, !self[old].isEmpty else { continue }
            self[new] = self[old]
            self[old] = DeviceAnnotation()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
