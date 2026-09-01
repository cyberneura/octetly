import SwiftUI

/// The port scan mode control, in one place because it is shown in two.
///
/// A scan reads the mode when it starts and keeps it for that run, so a change made while one is
/// running would not reach the sweep it appears to be about — and worse, the selection-mode side
/// *is* live, so switching mid-scan starts a per-host scan the engine will then repeat. The rule
/// lives here rather than at each call site: disabling it at one of the two was the first attempt,
/// and the Settings window is the one that got missed.
struct PortScanModePicker: View {
    @Bindable var settings: ScanSettingsStore
    let isScanning: Bool

    var body: some View {
        Picker("Port scan", selection: $settings.settings.portScanMode) {
            ForEach(PortScanMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .disabled(isScanning)
    }
}
