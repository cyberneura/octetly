import SwiftUI
import AppKit

@main
struct OctetlyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
