import AppKit
import SwiftUI

/// A column of the device table, for telling the cells of one row apart.
enum DeviceColumn: Hashable {
    case name, address, macAddress, vendor, ports, ping
}

/// One cell of the device table.
struct DeviceCell: Hashable {
    let device: Device.ID
    let column: DeviceColumn
}

/// The hover-to-copy state of the whole device table.
///
/// One hovered cell and one copied cell for the table rather than a flag in every cell, so a cell
/// builds its button only while it is the one being pointed at or just copied from. The view that
/// owns the table holds this without reading it, so a hover re-evaluates the cells on screen and
/// not the table and its rows.
@MainActor @Observable
final class CellCopier {
    /// The cell under the pointer, whether or not it has anything to copy.
    var hovered: DeviceCell?
    /// The cell last copied from, which shows a checkmark until `confirmation` has passed.
    private(set) var copied: DeviceCell?

    @ObservationIgnored private var resetTask: Task<Void, Never>?

    private static let confirmation: Duration = .seconds(3)

    func copy(_ text: String, from cell: DeviceCell) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copied = cell
        // A single timer: copying from another cell moves the checkmark there and starts the
        // count again instead of leaving the first one to clear the second.
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: Self.confirmation)
            guard !Task.isCancelled else { return }
            self?.copied = nil
        }
    }

    func pointer(isInside inside: Bool, _ cell: DeviceCell) {
        if inside {
            hovered = cell
        } else if hovered == cell {
            // Only the cell that owns the hover clears it: the next cell's enter can arrive
            // before this one's exit.
            hovered = nil
        }
    }

    func showsButton(for cell: DeviceCell) -> Bool { hovered == cell || copied == cell }
}

/// A table cell with a copy button at its trailing edge while it is hovered.
///
/// `text` is what gets copied, nil when the cell only shows a placeholder (`—`, `Unknown`), in
/// which case no button appears. The button is built only for the hovered or just-copied cell,
/// not hidden in every cell. Hover is tracked per cell, but the table only makes views for the
/// rows on screen, so the number of tracking areas follows the window height, not the row count.
struct CopyableCell<Content: View>: View {
    let cell: DeviceCell
    let text: String?
    let copier: CellCopier
    var alignment: Alignment = .leading
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 4) {
            content.frame(maxWidth: .infinity, alignment: alignment)
            if let text, copier.showsButton(for: cell) {
                CellCopyButton(copied: copier.copied == cell) { copier.copy(text, from: cell) }
            }
        }
        // The whole cell, not just the glyphs, so the button does not vanish between words.
        .contentShape(Rectangle())
        .onHover { copier.pointer(isInside: $0, cell) }
    }
}

/// The copy button, which turns into a checkmark once it has copied.
struct CellCopyButton: View {
    let copied: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(copied ? "Copied" : "Copy")
    }
}
