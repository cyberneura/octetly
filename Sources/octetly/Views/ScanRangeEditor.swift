import SwiftUI

struct ScanRangeEditor: View {
    @Bindable var store: ScanRangeStore
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scan Ranges").font(.headline)
            Text("A network in CIDR notation (192.168.0.0/24), a span (192.168.0.1 – 192.168.31.255), or a single address. Up to \(ScanRange.maximumHostCount.formatted()) addresses.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("192.168.0.0/24", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Add", action: save)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Group {
                if let failure {
                    Text(failure).foregroundStyle(.red)
                } else if let preview = try? ScanRange.parse(input).summary {
                    Text(preview).foregroundStyle(.secondary)
                } else {
                    Text(" ")
                }
            }
            .font(.caption)
            .lineLimit(2, reservesSpace: true)

            List {
                ForEach(store.saved) { range in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(range.text).font(.body.monospaced())
                            Text(range.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            store.remove(range)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this range")
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(height: 180)
            .overlay {
                if store.saved.isEmpty {
                    Text("No saved ranges").font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private func save() {
        do {
            try store.add(input)
            input = ""
            failure = nil
        } catch let error {
            failure = error.localizedDescription
        }
    }
}
