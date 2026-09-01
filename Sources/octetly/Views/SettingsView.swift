import SwiftUI

struct SettingsView: View {
    @Bindable var settings: ScanSettingsStore

    var body: some View {
        Form {
            Section("Concurrency") {
                Stepper(value: $settings.settings.deviceConcurrency,
                        in: ScanSettingsStore.concurrencyRange, step: 4) {
                    LabeledContent("Device lookups", value: "\(settings.settings.deviceConcurrency)")
                }
                Stepper(value: $settings.settings.portScanConcurrency,
                        in: ScanSettingsStore.concurrencyRange, step: 4) {
                    LabeledContent("Port scan sockets", value: "\(settings.settings.portScanConcurrency)")
                }
                .disabled(settings.settings.portScanMode != .afterScan)
                Text("Discovery sends ICMP echo requests from one socket and is not paced by these.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Port scan") {
                Picker("Run", selection: $settings.settings.portScanMode) {
                    ForEach(PortScanMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Text("A scan takes this when it starts and keeps it for that run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Ports", value: PortScanner.standardPorts.map(String.init).joined(separator: ", "))
            }

            Section("Limits") {
                LabeledContent("Automatic range", value: "\(LocalNetwork.autoHostLimit.formatted()) addresses")
                LabeledContent("Entered range", value: "\(ScanRange.maximumHostCount.formatted()) addresses")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }
}
