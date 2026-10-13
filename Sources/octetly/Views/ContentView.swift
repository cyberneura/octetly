import SwiftUI

struct ContentView: View {
    @Bindable var scanner: NetworkScanner
    @State private var editingRanges = false
    @State private var exporting = false
    @State private var sortOrder = [KeyPathComparator(\Device.addressOrder)]
    @State private var searchText = ""
    @State private var renamingID: Device.ID?
    @State private var copier = CellCopier()
    /// Trails scanner.progress so growth can be animated and a reset cannot be.
    @State private var shownFraction: Double = 0
    @AppStorage("showsSidebar") private var showsSidebar = true
    @AppStorage("showsInspector") private var showsInspector = true

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                if sidebarShown {
                    ScanSidebar(scanner: scanner,
                                ranges: scanner.ranges,
                                settings: scanner.settings,
                                editingRanges: $editingRanges)
                        .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)
                        .frame(maxHeight: .infinity)
                }

                deviceTable

                // The pane is absent rather than empty when nothing is selected, so the table gets
                // the whole window until there is something to show beside it.
                if showsInspector && (selectedDevice != nil || scanner.selectedDeviceIDs.count > 1) {
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
            ToolbarItemGroup(placement: .primaryAction) {
                scanButton
                exportButton
                sidebarToggle
                inspectorToggle
            }
            ToolbarItem(placement: .primaryAction) { searchField }
        }
        .sheet(isPresented: $editingRanges) {
            ScanRangeEditor(store: scanner.ranges)
        }
        .sheet(isPresented: $exporting) {
            ExportSheet(devices: exportedRows, selectionOnly: !selectedRows.isEmpty)
        }
    }

    /// Forced on while there is nothing to look at but the sidebar, since it holds the target
    /// and the options. A scan in progress does not count as nothing: rescanning empties the list
    /// first, and a hidden sidebar would otherwise flash back in for the moment before the first
    /// host arrives.
    private var sidebarForced: Bool { scanner.devices.isEmpty && !scanner.isScanning }

    private var sidebarShown: Bool { showsSidebar || sidebarForced }

    /// Here rather than only in the sidebar, which can be hidden; this also carries ⌘R, so the
    /// shortcut does not leave with the sidebar either.
    private var scanButton: some View {
        Button {
            scanner.isScanning ? scanner.stop() : scanner.scan()
        } label: {
            Label(scanner.isScanning ? "Stop" : "Scan",
                  systemImage: scanner.isScanning ? "stop.fill" : "arrow.clockwise")
        }
        .keyboardShortcut("r", modifiers: .command)
        .help(scanner.isScanning ? "Stop scanning (⌘R)" : "Scan (⌘R)")
    }

    private var exportButton: some View {
        Button {
            exporting = true
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .keyboardShortcut("e", modifiers: [.shift, .command])
        .disabled(rows.isEmpty)
        .help("Export the selected devices, or all shown, as CSV or JSON (⇧⌘E)")
    }

    /// In table order, not selection order, so an export reads like the rows it came from.
    private var selectedRows: [Device] {
        rows.filter { scanner.selectedDeviceIDs.contains($0.id) }
    }

    private var exportedRows: [Device] {
        let selected = selectedRows
        return selected.isEmpty ? rows : selected
    }

    private var sidebarToggle: some View {
        Button {
            showsSidebar.toggle()
        } label: {
            Label(sidebarShown ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
        }
        .keyboardShortcut("s", modifiers: [.control, .command])
        .disabled(sidebarForced)
        .help(sidebarForced ? "The sidebar stays open until a scan has found something"
              : sidebarShown ? "Hide Sidebar (⌃⌘S)" : "Show Sidebar (⌃⌘S)")
    }

    private var inspectorToggle: some View {
        Button {
            showsInspector.toggle()
        } label: {
            Label(showsInspector ? "Hide Details" : "Show Details", systemImage: "sidebar.right")
        }
        .keyboardShortcut("i", modifiers: [.option, .command])
        .help(showsInspector ? "Hide Details (⌥⌘I)" : "Show Details (⌥⌘I)")
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
            // Without this the table runs up under the title bar and insets its header by the
            // toolbar's height, leaving a blank band above it. With it, the toolbar becomes a
            // strip of its own across the whole window and the header sits directly beneath.
            .ignoresSafeArea(edges: .top)
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
        // The toolbar pins this to the trailing edge with its own margin. The width leaves the
        // same margin on the leading side when the inspector is at its minimum width; a wider
        // inspector only adds room on the left.
        .frame(width: 228)
    }

    private var table: some View {
        Table(rows, selection: $scanner.selectedDeviceIDs, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.displayName) { device in
                DeviceNameCell(device: device, editingID: $renamingID, copier: copier) { name in
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
                CopyableCell(cell: DeviceCell(device: device.id, column: .address),
                             text: device.displayAddress == "—" ? nil : device.displayAddress,
                             copier: copier) {
                    Text(device.displayAddress)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(device.displayAddress)
                }
            }
            .width(min: 120, ideal: 190)

            TableColumn("MAC Address", value: \.macAddress) { device in
                CopyableCell(cell: DeviceCell(device: device.id, column: .macAddress),
                             text: device.hasMACAddress ? device.macAddress : nil,
                             copier: copier) {
                    Text(device.macAddress).font(.body.monospaced()).foregroundStyle(.secondary)
                }
            }
            .width(min: 130, ideal: 150)

            TableColumn("Vendor", value: \.vendor) { device in
                CopyableCell(cell: DeviceCell(device: device.id, column: .vendor),
                             text: device.hasVendor ? device.vendor : nil,
                             copier: copier) {
                    Text(device.vendor)
                        .lineLimit(1)
                        .foregroundStyle(device.hasVendor ? .primary : .tertiary)
                }
            }
            .width(min: 120, ideal: 180)

            TableColumn("Ports", value: \.portSummary) { device in
                // Only a list of open ports is worth copying; the other states are status text.
                let hasOpenPorts = device.portScanState == .done && !device.openPorts.isEmpty
                CopyableCell(cell: DeviceCell(device: device.id, column: .ports),
                             text: hasOpenPorts ? device.portSummary : nil,
                             copier: copier) {
                    Text(device.portSummary)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(hasOpenPorts ? .primary : .secondary)
                }
            }
            .width(min: 100, ideal: 130)

            TableColumn("Ping", value: \.latencySortValue) { device in
                CopyableCell(cell: DeviceCell(device: device.id, column: .ping),
                             text: device.latencyMilliseconds == nil ? nil : device.latencySummary,
                             copier: copier, alignment: .trailing) {
                    Text(device.latencySummary)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(device.latencyMilliseconds == nil ? .tertiary : .secondary)
                }
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
            } else if scanner.selectedDeviceIDs.count > 1 {
                // Kept open rather than closed for a multiple selection, so extending a selection
                // with Shift or Command does not make the table jump wider and back.
                ContentUnavailableView("\(scanner.selectedDeviceIDs.count) Devices Selected",
                                       systemImage: "square.stack")
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
