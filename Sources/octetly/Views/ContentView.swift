import SwiftUI

struct ContentView: View {
    @Bindable var scanner: NetworkScanner

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $scanner.selectedDeviceID) {
                    ForEach(scanner.devices) { device in
                        DeviceRow(device: device).tag(device.id)
                    }
                }
                .overlay {
                    if scanner.devices.isEmpty {
                        ContentUnavailableView(
                            "No Devices Yet",
                            systemImage: "network",
                            description: Text("Scan your local network to find connected devices.")
                        )
                    }
                }
                Divider()
                HStack {
                    if scanner.isScanning { ProgressView().controlSize(.small) }
                    Text(scanner.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(scanner.devices.count) devices")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(10)
            }
            .navigationTitle("Octetly")
        } detail: {
            if let id = scanner.selectedDeviceID,
               let device = scanner.devices.first(where: { $0.id == id }) {
                DeviceDetailView(device: device)
            } else {
                ContentUnavailableView("Select a Device", systemImage: "desktopcomputer")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(scanner.isScanning ? "Stop" : "Scan", systemImage: scanner.isScanning ? "stop.fill" : "arrow.clockwise") {
                    scanner.isScanning ? scanner.stop() : scanner.scan()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
