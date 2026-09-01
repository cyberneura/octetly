import SwiftUI

@main
struct OctetlyApp: App {
    @State private var scanner = NetworkScanner()

    var body: some Scene {
        WindowGroup {
            ContentView(scanner: scanner)
                .frame(minWidth: 900, minHeight: 520)
        }
        .defaultSize(width: 1180, height: 680)
        .windowToolbarStyle(.unified)

        Settings { SettingsView() }
    }
}
