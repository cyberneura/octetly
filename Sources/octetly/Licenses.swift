import AppKit
import Foundation

/// Octetly's own license followed by the third-party notices, as the app carries them.
///
/// Both files are resources (copies of LICENSE and THIRD-PARTY-NOTICES.txt at the top of the
/// repository, written by `scripts/generate-third-party-notices.sh`), so the text is whatever was
/// built into this copy of the app rather than anything read from a checkout at run time.
enum Licenses {
    /// Where the notices live on GitHub, for when the bundled copy cannot be read.
    static let noticesURL =
        URL(string: "https://github.com/cyberneura/octetly/blob/main/THIRD-PARTY-NOTICES.txt")!

    /// The text `--license` prints and the Third-Party Licenses window shows, or nil when either
    /// file is missing from the build.
    static func text() -> String? {
        guard let license = read("LICENSE"), let notices = read("THIRD-PARTY-NOTICES") else {
            return nil
        }
        let rule = String(repeating: "#", count: 80)
        return """
            \(rule)
            # Octetly
            \(rule)

            \(license.trimmingCharacters(in: .newlines))

            \(notices.trimmingCharacters(in: .newlines))

            """
    }

    private static func read(_ name: String) -> String? {
        guard let url = BundledResource.url(forResource: name, withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// The window behind "Third-Party Licenses…" in the app menu.
///
/// A plain AppKit window rather than a SwiftUI scene: it is opened from a menu command, one at a
/// time, and a scrolling text view is all it holds. Opening it again brings the same window back.
@MainActor
enum LicensesWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // A build without the files is a packaging mistake, not something to show an empty
        // window for; the same text is on GitHub.
        guard let text = Licenses.text() else {
            NSWorkspace.shared.open(Licenses.noticesURL)
            return
        }

        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            textView.textContainerInset = NSSize(width: 12, height: 12)
            textView.string = text
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Third-Party Licenses"
        window.contentView = scrollView
        window.minSize = NSSize(width: 420, height: 300)
        // Kept rather than released on close, so that reopening it is the same window.
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
