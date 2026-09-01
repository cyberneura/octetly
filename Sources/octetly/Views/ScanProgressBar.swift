import SwiftUI

/// A determinate bar drawn directly rather than with ProgressView.
///
/// ProgressView is an NSProgressIndicator on macOS, and AppKit animates that control's value
/// changes itself. Disabling the SwiftUI transaction does not reach it, so a reset to zero slid
/// backwards no matter what the caller asked for. A plain frame width obeys the transaction.
struct ScanProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.quaternary)
                Capsule(style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
    }
}
