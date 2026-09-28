import SwiftUI

struct DeviceDetailView: View {
    let device: Device
    @Bindable var annotations: AnnotationStore

    var body: some View {
        ScrollView {
            // Laid out by hand rather than with a grouped Form so the pane can share the
            // sidebar's 14pt inset; the grouped style's margins are not adjustable.
            VStack(alignment: .leading, spacing: 18) {
                DetailSection("Notes") {
                    TextEditor(text: noteBinding)
                        .font(.body)
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                    Text(keyDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DetailSection("Identity") {
                    DetailRow("Name", value: device.displayName)
                    DetailRow("Hostname", value: device.hostname)
                    DetailRow("Vendor", value: device.vendor)
                    DetailRow("MAC address", value: device.macAddress)
                }
                DetailSection("Addresses") {
                    DetailRow("IPv4", value: device.ipv4 ?? "—")
                    if device.hasIPv6 {
                        DetailRow("IPv6") {
                            VStack(alignment: .trailing, spacing: 3) {
                                ForEach(device.ipv6Addresses, id: \.self) { address in
                                    Text(address)
                                        .font(.callout.monospaced())
                                        .multilineTextAlignment(.trailing)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    } else {
                        DetailRow("IPv6", value: "—")
                    }
                    DetailRow("Ping", value: device.latencySummary)
                    DetailRow("Seen by", value: device.discoverySummary)
                    if !device.answeredEcho {
                        Text("Nothing answered an echo request at this address. It is here because the kernel holds a hardware address for it and has heard from that NIC recently — which is what a machine that filters ICMP looks like, and also what one that has just moved to another address looks like.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                DetailSection("Network names") {
                    DetailRow("DNS name", value: device.dnsName)
                    DetailRow("mDNS name", value: device.mdnsName)
                    DetailRow("SMB name", value: device.smbName)
                    DetailRow("SMB domain", value: device.smbDomain)
                }
                DetailSection("Open ports") {
                    Text(device.portScanState == .done
                         ? (device.openPorts.isEmpty
                            ? "None of the scanned ports are open"
                            : device.openPorts.sorted().map(String.init).joined(separator: ", "))
                         : device.portSummary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var noteBinding: Binding<String> {
        Binding(
            get: { annotations[device.annotationKey].note },
            set: { text in
                var annotation = annotations[device.annotationKey]
                annotation.note = text
                annotations[device.annotationKey] = annotation
            }
        )
    }

    private var keyDescription: String {
        device.hasMACAddress
            ? "Filed under the MAC address, so it follows this device if its IP changes."
            : "Filed under \(device.annotationAddress). This device has no MAC address for the note to follow, so it stays with the address rather than the machine."
    }
}

/// A titled card of rows, in the shape a grouped Form draws but with its own margins.
private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct DetailRow<Value: View>: View {
    let label: String
    @ViewBuilder let value: Value

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    // LabeledContent outside a Form puts the value right after the label; the pane wants the
    // grouped-form look of label on the left and value against the trailing edge.
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
            Spacer(minLength: 0)
            value
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

extension DetailRow where Value == Text {
    init(_ label: String, value: String) {
        self.init(label) { Text(value) }
    }
}
