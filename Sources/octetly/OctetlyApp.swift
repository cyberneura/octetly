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
        // Compact puts the title and the toolbar on one row, so the search field sits in the
        // title bar rather than costing the panes a strip of their own. Hiding the bar and
        // rebuilding that strip by hand was the alternative, and it meant guessing at the safe
        // area and at where the traffic lights land.
        .windowToolbarStyle(.unifiedCompact)

        Settings { SettingsView(settings: scanner.settings) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
