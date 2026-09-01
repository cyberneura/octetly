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

    /// Carries an entry over when a device's key changes under it.
    ///
    /// A row starts out keyed by address and switches to its MAC as soon as the neighbour cache
    /// catches up, which is seconds later on a first scan. Anything typed in that window would
    /// otherwise stay filed under the address and simply stop being displayed. Anything already
    /// filed under the destination wins — that one was entered against the identity that lasted.
    func migrate(from old: String, to new: String) {
        guard old != new, self[new].isEmpty, !self[old].isEmpty else { return }
        self[new] = self[old]
        self[old] = DeviceAnnotation()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
