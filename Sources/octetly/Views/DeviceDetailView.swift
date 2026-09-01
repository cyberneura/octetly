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
                LabeledContent("IPv4", value: device.ipv4)
                LabeledContent("IPv6", value: device.ipv6)
                LabeledContent("Ping", value: device.latencySummary)
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
            : "Filed under \(device.ipv4). There is no MAC address for a host reached through a router or a VPN, so this note stays with the address rather than the machine."
    }
}
