import SwiftUI

struct DeviceRow: View {
    let device: Device

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title2).foregroundStyle(.tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.hostname == "—" ? device.ipv4 : device.hostname)
                    .font(.headline).lineLimit(1)
                Text(device.ipv4).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            if let latency = device.latencyMilliseconds {
                Text("\(latency, specifier: "%.1f") ms")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
