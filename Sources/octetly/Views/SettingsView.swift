import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            LabeledContent("Ports", value: "22, 80, 443, 5900")
            Text("Octetly scans only your directly connected local network.")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}
