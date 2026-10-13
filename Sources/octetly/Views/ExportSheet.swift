import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Asks for a format, then writes `devices` to a file or to the clipboard.
///
/// The caller decides which devices: the selected rows when there are any, otherwise every row
/// the table shows. The sheet only says which of the two it was given.
struct ExportSheet: View {
    let devices: [Device]
    let selectionOnly: Bool

    @Environment(\.dismiss) private var dismiss
    @AppStorage("exportFormat") private var format = ExportFormat.csv
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Devices").font(.headline)

            Text(scope)
                .font(.callout)
                .foregroundStyle(.secondary)

            Form {
                Picker("Format:", selection: $format) {
                    Text("CSV").tag(ExportFormat.csv)
                    Text("JSON").tag(ExportFormat.json)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Copy to Clipboard", action: copy)
                Button("Save to File…", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private var scope: String {
        let count = devices.count == 1 ? "1 device" : "\(devices.count.formatted()) devices"
        return selectionOnly ? "Exports the \(count) selected in the table."
            : "Exports all \(count) shown in the table. Select rows to export only those."
    }

    private func exportedText() -> String? {
        do {
            return try DeviceExport.text(devices, as: format)
        } catch {
            failure = "Could not write \(format.rawValue.uppercased()): \(error.localizedDescription)"
            return nil
        }
    }

    private func copy() {
        guard let text = exportedText() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        dismiss()
    }

    private func save() {
        guard let text = exportedText() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .json ? .json : .commaSeparatedText]
        panel.nameFieldStringValue = "octetly-\(Self.stamp.string(from: .now)).\(format.fileExtension)"
        panel.canCreateDirectories = true
        // Modal over the sheet rather than after closing it, so a cancelled save panel leaves the
        // choices on screen to change instead of throwing them away.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            dismiss()
        } catch {
            failure = "Could not save the file: \(error.localizedDescription)"
        }
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
