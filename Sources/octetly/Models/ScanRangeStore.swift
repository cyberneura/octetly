import Foundation
import Observation

@MainActor
@Observable
final class ScanRangeStore {
    private static let savedKey = "ScanRanges"
    private static let selectionKey = "ScanRangeSelection"

    private(set) var saved: [ScanRange]

    var selectedID: ScanRange.ID? {
        didSet { defaults.set(selectedID, forKey: Self.selectionKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Only the entered text is persisted and the bounds are derived again on load, so a
        // change to the parser can never leave a stored range meaning something other than
        // what its label reads as. A range that no longer parses is dropped.
        saved = (defaults.stringArray(forKey: Self.savedKey) ?? []).compactMap { try? ScanRange.parse($0) }
        let stored = defaults.string(forKey: Self.selectionKey)
        selectedID = saved.contains { $0.id == stored } ? stored : nil
    }

    var selected: ScanRange? { saved.first { $0.id == selectedID } }

    var selectionLabel: String { selected?.text ?? "Automatic" }

    /// nil when Automatic is selected and no IPv4 interface is up.
    var activeRange: ScanRange? { selected ?? LocalNetwork.current()?.autoRange }

    @discardableResult
    func add(_ text: String) throws -> ScanRange {
        let range = try ScanRange.parse(text)
        // Re-entering a span already saved under a different spelling replaces it rather than
        // adding a second entry that scans the same addresses.
        if let index = saved.firstIndex(where: { $0.id == range.id }) {
            saved[index] = range
        } else {
            saved.append(range)
        }
        persist()
        selectedID = range.id
        return range
    }

    func remove(_ range: ScanRange) {
        saved.removeAll { $0.id == range.id }
        if selectedID == range.id { selectedID = nil }
        persist()
    }

    private func persist() {
        defaults.set(saved.map(\.text), forKey: Self.savedKey)
    }
}
