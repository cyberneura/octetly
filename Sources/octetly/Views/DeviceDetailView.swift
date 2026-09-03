import SwiftUI

struct DeviceDetailView: View {
    let device: Device
    @Bindable var annotations: AnnotationStore

    var body: some View {
        Form {
            Section("Notes") {
                TextEditor(text: noteBinding)
                    .font(.body)
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                Text(keyDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Identity") {
                LabeledContent("Name", value: device.displayName)
                LabeledContent("Hostname", value: device.hostname)
                LabeledContent("Vendor", value: device.vendor)
                LabeledContent("MAC address", value: device.macAddress)
            }
            Section("Addresses") {
                LabeledContent("IPv4", value: device.ipv4 ?? "—")
                if device.hasIPv6 {
                    LabeledContent("IPv6") {
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
                    LabeledContent("IPv6", value: "—")
                }
                LabeledContent("Ping", value: device.latencySummary)
                LabeledContent("Seen by", value: device.discoverySummary)
                if !device.answeredEcho {
                    Text("Nothing answered an echo request at this address. It is here because the kernel holds a hardware address for it and has heard from that NIC recently — which is what a machine that filters ICMP looks like, and also what one that has just moved to another address looks like.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section("Network names") {
                LabeledContent("DNS name", value: device.dnsName)
                LabeledContent("mDNS name", value: device.mdnsName)
                LabeledContent("SMB name", value: device.smbName)
                LabeledContent("SMB domain", value: device.smbDomain)
            }
            Section("Open ports") {
                Text(device.portScanState == .done
                     ? (device.openPorts.isEmpty
                        ? "None of the scanned ports are open"
                        : device.openPorts.sorted().map(String.init).joined(separator: ", "))
                     : device.portSummary)
            }
        }
        .formStyle(.grouped)
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
