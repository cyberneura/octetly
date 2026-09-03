import SwiftUI

/// The Name cell: the name, and a pencil that opens an editor for it.
struct DeviceNameCell: View {
    let device: Device
    @Binding var editingID: Device.ID?
    let rename: (String) -> Void

    @State private var draft = ""
    @State private var hovering = false

    private var isEditing: Bool { editingID == device.id }

    var body: some View {
        HStack(spacing: 6) {
            // Split rather than a Label so the icon can carry the "this is you" tint without the
            // name text taking it too.
            Image(systemName: device.isLocalMachine ? "laptopcomputer" : "desktopcomputer")
                .foregroundStyle(device.isLocalMachine ? Color.accentColor : Color.secondary)
            Text(device.displayName)
                .lineLimit(1)
                .foregroundStyle(device.hasName ? .primary : .tertiary)
            if device.isLocalMachine {
                Text("This Machine")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Spacer(minLength: 4)
            Button {
                draft = device.customName
                editingID = device.id
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            // Faded rather than removed, so the name beside it does not reflow as the pointer
            // crosses rows. Held visible while its popover is open, since taking the anchor away
            // mid-edit leaves the popover pointing at nothing.
            .opacity(hovering || isEditing ? 1 : 0)
            .help("Set a name for this device")
            .popover(isPresented: Binding(
                get: { isEditing },
                set: { if !$0, isEditing { editingID = nil } }
            )) {
                editor
            }
        }
        .onHover { hovering = $0 }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Name for \(device.displayAddress)").font(.headline)
            TextField(device.hostname == "—" ? "Name" : device.hostname, text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(commit)

            Text(device.hasMACAddress
                 ? "Filed under \(device.macAddress), so it follows this device if its IP changes."
                 : "Filed under \(device.annotationAddress). This device has no MAC address for the name to follow, so it stays with the address rather than the machine.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Clear") {
                    draft = ""
                    commit()
                }
                .disabled(device.customName.isEmpty)
                Spacer()
                Button("Cancel") { editingID = nil }
                Button("Save", action: commit).keyboardShortcut(.defaultAction)
            }
            .frame(width: 260)
        }
        .padding(14)
    }

    private func commit() {
        rename(draft)
        editingID = nil
    }
}
