import SwiftUI

struct ContentView: View {
    @Bindable var scanner: NetworkScanner
    @State private var editingRanges = false
    @State private var sortOrder = [KeyPathComparator(\Device.addressOrder)]
    @State private var searchText = ""
    @State private var renamingID: Device.ID?
    /// Trails scanner.progress so growth can be animated and a reset cannot be.
    @State private var shownFraction: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                ScanSidebar(scanner: scanner,
                            ranges: scanner.ranges,
                            settings: scanner.settings,
                            editingRanges: $editingRanges)
                    .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)
                    .frame(maxHeight: .infinity)

                deviceTable

                // The pane is absent rather than empty when nothing is selected, so the table gets
                // the whole window until there is something to show beside it.
                if selectedDevice != nil {
                    inspector
                }
            }
            // HSplitView reports its content's ideal height as its own, so without this the split
            // view and the status bar under it sit centred with dead space above and below.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            statusBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Octetly")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { searchField }
        }
        .sheet(isPresented: $editingRanges) {
            ScanRangeEditor(store: scanner.ranges)
        }
    }

    private var selectedDevice: Device? {
        guard let id = scanner.selectedDeviceID else { return nil }
        return scanner.devices.first { $0.id == id }
    }

    // Re-sorting on read rather than sorting the stored array keeps the column order applied to
    // rows that arrive while the scan is still running.
    private var rows: [Device] {
        scanner.devices.filter { $0.matches(searchText) }.sorted(using: sortOrder)
    }

    private var deviceTable: some View {
        table
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Name, address, MAC, vendor", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .frame(width: 240)
    }

    private var table: some View {
        Table(rows, selection: $scanner.selectedDeviceID, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.displayName) { device in
                DeviceNameCell(device: device, editingID: $renamingID) { name in
                    scanner.rename(device.id, to: name)
                }
            }
            .width(min: 180, ideal: 240)

            // A host found over IPv6 alone is shown at its IPv6 address rather than at a blank,
            // which is what makes it one row among the others instead of a list of its own. That
            // address is two and a half times as long as a dotted quad, so the middle of it is
            // what gets dropped when the column is narrow: the prefix and the zone are the halves
            // that tell two of them apart.
            TableColumn("IP Address", value: \.addressOrder) { device in
                Text(device.displayAddress)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(device.displayAddress)
            }
            .width(min: 120, ideal: 190)

            TableColumn("MAC Address", value: \.macAddress) { device in
                Text(device.macAddress).font(.body.monospaced()).foregroundStyle(.secondary)
            }
            .width(min: 130, ideal: 150)

            TableColumn("Vendor", value: \.vendor) { device in
                Text(device.vendor)
                    .lineLimit(1)
                    .foregroundStyle(device.hasVendor ? .primary : .tertiary)
            }
            .width(min: 120, ideal: 180)

            TableColumn("Ports", value: \.portSummary) { device in
                Text(device.portSummary)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(device.portScanState == .done && !device.openPorts.isEmpty ? .primary : .secondary)
            }
            .width(min: 100, ideal: 130)

            TableColumn("Ping", value: \.latencySortValue) { device in
                Text(device.latencySummary)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(device.latencyMilliseconds == nil ? .tertiary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if rows.isEmpty {
                emptyState
                    // Opaque so the empty state reads as an empty table rather than as text
                    // floating over the alternating row stripes drawn underneath it.
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if scanner.devices.isEmpty {
            ContentUnavailableView(
                "No Devices Yet",
                systemImage: "network",
                description: Text("Scan your local network to find connected devices.")
            )
        } else {
            ContentUnavailableView(
                "No Matches",
                systemImage: "magnifyingglass",
                description: Text("No device matches “\(searchText)”.")
            )
        }
    }

    private var inspector: some View {
        Group {
            if let device = selectedDevice {
                DeviceDetailView(device: device, annotations: scanner.annotations)
            }
        }
        .frame(minWidth: 250, idealWidth: 290, maxWidth: 400)
        .frame(maxHeight: .infinity)
    }

    private var statusBar: some View {
        VStack(spacing: 6) {
            if let progress = scanner.progress {
                HStack(spacing: 10) {
                    ScanProgressBar(fraction: shownFraction)
                    // Reads the real value, not the animated one, so the number is never a frame
                    // behind what the scan has actually done.
                    Text(progress.fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
            }
            HStack {
                // The spinner covers the gap before the first progress event arrives.
                if scanner.isScanning && scanner.progress == nil {
                    ProgressView().controlSize(.small)
                }
                Text(scanner.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(scanner.devices.count) devices")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .onChange(of: scanner.progress?.fraction) { previous, current in
            show(fraction: current ?? 0, wasAt: previous ?? 0)
        }
    }

    private func show(fraction: Double, wasAt previous: Double) {
        guard fraction > previous else {
            // A new pass or phase restarts the count. Animating the bar backwards reads as work
            // being undone, so a reset lands in one frame.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { shownFraction = fraction }
            return
        }
        withAnimation(.easeOut(duration: 0.25)) { shownFraction = fraction }
    }
}
