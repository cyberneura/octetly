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

        Settings { SettingsView(scanner: scanner, settings: scanner.settings) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        applyDockIcon()
    }

    /// Sets the Dock icon from the bundled image, where nothing else will.
    ///
    /// `swift run` produces a bare executable, not an .app, so there is no Info.plist and no
    /// asset catalog for macOS to read an icon out of — it would use the generic placeholder.
    /// Assigning it at launch is what works for a package executable.
    ///
    /// The released build is a real .app (`scripts/make-app.sh`) and carries an .icns, which
    /// macOS has already applied by this point. Assigning over it would replace a full icon set
    /// with a single 512-pixel image, so the .app is left alone: the presence of CFBundleIconFile
    /// is what tells the two apart, since a package executable has no Info.plist to hold it.
    @MainActor
    private func applyDockIcon() {
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil else { return }
        guard let url = BundledResource.url(forResource: "AppIcon", withExtension: "png"),
              let icon = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = icon
    }
}
