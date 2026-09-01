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

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
