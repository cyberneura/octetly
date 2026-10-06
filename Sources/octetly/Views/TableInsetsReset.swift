import AppKit
import SwiftUI

/// Takes the device table's content insets away from AppKit.
///
/// The table ignores the top safe area so its header can sit in the title bar strip, which
/// leaves SwiftUI with no inset to give it. AppKit, though, still sees the scroll view running
/// under the title bar and insets its content by the bar's height on its own. The two disagree:
/// the header is drawn at the top while the rows start a title bar lower, so a blank band opens
/// under the header and the first row is cut off by it. Turning the automatic insets off on the
/// scroll view and its clip view leaves the rows starting right under the header.
///
/// Placed as a background of the table, so it finds the table by looking through its window
/// rather than through its own superviews: SwiftUI hosts the two side by side. The main window
/// holds a single table, and a sheet's list lives in a window of its own.
struct TableInsetsReset: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ probe: Probe, context: Context) { probe.scheduleReset() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleReset()
        }

        /// Run asynchronously because the table may not be in the window yet. If it still is not,
        /// a later update finds it: SwiftUI calls `updateNSView` again whenever the rows change.
        func scheduleReset() {
            Task { @MainActor [weak self] in
                guard let root = self?.window?.contentView else { return }
                Self.tableScrollViews(in: root).forEach(Self.reset)
            }
        }

        private static func tableScrollViews(in view: NSView) -> [NSScrollView] {
            if let scrollView = view as? NSScrollView, scrollView.documentView is NSTableView {
                return [scrollView]
            }
            return view.subviews.flatMap(tableScrollViews)
        }

        private static func reset(_ scrollView: NSScrollView) {
            // Assigned only when different, since every assignment relays out the table.
            if scrollView.automaticallyAdjustsContentInsets {
                scrollView.automaticallyAdjustsContentInsets = false
            }
            if !scrollView.contentInsets.isZero {
                scrollView.contentInsets = NSEdgeInsets()
            }
            let clipView = scrollView.contentView
            if clipView.automaticallyAdjustsContentInsets {
                clipView.automaticallyAdjustsContentInsets = false
            }
            if !clipView.contentInsets.isZero {
                clipView.contentInsets = NSEdgeInsets()
            }
        }
    }
}

private extension NSEdgeInsets {
    var isZero: Bool { top == 0 && left == 0 && bottom == 0 && right == 0 }
}
