import SwiftUI

struct ScanSidebar: View {
    // The stores arrive separately because a binding cannot be formed through the `let`
    // properties that hold them on NetworkScanner.
    @Bindable var scanner: NetworkScanner
    @Bindable var ranges: ScanRangeStore
    @Bindable var settings: ScanSettingsStore
    @Binding var editingRanges: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    target
                    Divider()
                    options
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            machine
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.regularMaterial)
    }

    private var machine: some View {
        VStack(alignment: .leading, spacing: 6) {
            heading("This Machine")
            if let network = scanner.machine {
                Text(network.interface)
                    .font(.callout)
                Text(network.cidr)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                if let mac = network.macAddress {
                    Text(mac)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if OUIDatabase.isLocallyAdministered(mac) {
                        // Worth saying outright: this is why the machine's own row shows no
                        // vendor, and why the address is not the one printed on the hardware.
                        Text("Private address — changes per network")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("No hardware address")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No active IPv4 interface")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var target: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Target")
            Picker("Target", selection: $ranges.selectedID) {
                Text("Automatic").tag(String?.none)
                ForEach(ranges.saved) { range in
                    Text(range.text).tag(String?.some(range.id))
                }
            }
            .labelsHidden()
            .disabled(scanner.isScanning)

            if let range = ranges.selected {
                Text(range.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Edit Ranges…") { editingRanges = true }
                .disabled(scanner.isScanning)

            Button {
                scanner.isScanning ? scanner.stop() : scanner.scan()
            } label: {
                Label(scanner.isScanning ? "Stop" : "Scan",
                      systemImage: scanner.isScanning ? "stop.fill" : "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut("r", modifiers: .command)
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Options")

            VStack(alignment: .leading, spacing: 4) {
                Text("Device lookups")
                    .font(.callout)
                Stepper(value: $settings.settings.deviceConcurrency,
                        in: ScanSettingsStore.concurrencyRange, step: 4) {
                    Text("\(settings.settings.deviceConcurrency) at once")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("How many hosts are named at the same time. Discovery itself is not limited by this.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Port scan")
                    .font(.callout)
                PortScanModePicker(settings: settings, isScanning: scanner.isScanning)
                    .labelsHidden()

                if settings.settings.portScanMode != .off {
                    if settings.settings.portScanMode == .afterScan {
                        Stepper(value: $settings.settings.portScanConcurrency,
                                in: ScanSettingsStore.concurrencyRange, step: 4) {
                            Text("\(settings.settings.portScanConcurrency) sockets")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(PortScanner.standardPorts.map(String.init).joined(separator: ", "))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}
