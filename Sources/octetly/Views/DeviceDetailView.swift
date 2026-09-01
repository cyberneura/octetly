import SwiftUI

struct DeviceDetailView: View {
    let device: Device

    var body: some View {
        Form {
            Section("Identity") {
                LabeledContent("Hostname", value: device.hostname)
                LabeledContent("Vendor", value: device.vendor)
                LabeledContent("MAC address", value: device.macAddress)
            }
            Section("Addresses") {
                LabeledContent("IPv4", value: device.ipv4)
                LabeledContent("IPv6", value: device.ipv6)
            }
            Section("Network names") {
                LabeledContent("DNS name", value: device.dnsName)
                LabeledContent("mDNS name", value: device.mdnsName)
                LabeledContent("SMB name", value: device.smbName)
                LabeledContent("SMB domain", value: device.smbDomain)
            }
            Section("Open ports") {
                Text(device.openPorts.isEmpty ? "None of the scanned ports are open" : device.openPorts.sorted().map(String.init).joined(separator: ", "))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(device.hostname == "—" ? device.ipv4 : device.hostname)
        .padding()
    }
}
