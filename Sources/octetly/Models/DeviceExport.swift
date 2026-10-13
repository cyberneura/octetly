import Foundation

/// One device as `octetly search --json` prints it and as the window exports it, so a file saved
/// from the window and the output of a script read the same.
///
/// Fields with nothing found are nil, and left out of the JSON, rather than carrying the "—" the
/// table shows: a program reading it should not have to know the placeholder. `ipv6` is always
/// present as a list, and `openPorts` is an empty list once a scan has found none open.
struct DeviceRecord: Encodable, Equatable {
    var ipv4: String?
    var ipv6: [String]
    var name: String?
    var customName: String?
    var dnsName: String?
    var mdnsName: String?
    var smbName: String?
    var smbDomain: String?
    var macAddress: String?
    var vendor: String?
    /// nil until the ports have been scanned, so "not looked at" is not read as "none open".
    var openPorts: [Int]?
    var latencyMilliseconds: Double?

    init(_ device: Device) {
        ipv4 = device.ipv4
        ipv6 = device.ipv6Addresses
        name = device.hasName ? device.displayName : nil
        customName = device.customName.isEmpty ? nil : device.customName
        dnsName = present(device.dnsName)
        mdnsName = present(device.mdnsName)
        smbName = present(device.smbName)
        smbDomain = present(device.smbDomain)
        macAddress = present(device.macAddress)
        vendor = knownVendor(of: device)
        openPorts = device.portScanState == .done ? device.openPorts.sorted() : nil
        latencyMilliseconds = device.latencyMilliseconds
    }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case json, csv

    var id: Self { self }

    var fileExtension: String { rawValue }
}

enum DeviceExport {
    static func text(_ devices: [Device], as format: ExportFormat) throws -> String {
        let records = devices.map(DeviceRecord.init)
        return switch format {
        case .json: try json(records)
        case .csv: csv(records)
        }
    }

    static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func json(_ records: [DeviceRecord]) throws -> String {
        String(decoding: try jsonEncoder().encode(records), as: UTF8.self)
    }

    /// The JSON keys in the order a person reads the table, one row per device. The two lists, IPv6
    /// addresses and open ports, go into one cell separated by spaces, which neither contains.
    static let csvHeader = ["ipv4", "ipv6", "name", "customName", "dnsName", "mdnsName",
                            "smbName", "smbDomain", "macAddress", "vendor", "openPorts",
                            "latencyMilliseconds"]

    static func csv(_ records: [DeviceRecord]) -> String {
        let rows = records.map { record in
            [record.ipv4 ?? "", record.ipv6.joined(separator: " "), record.name ?? "",
             record.customName ?? "", record.dnsName ?? "", record.mdnsName ?? "",
             record.smbName ?? "", record.smbDomain ?? "", record.macAddress ?? "",
             record.vendor ?? "", record.openPorts?.map(String.init).joined(separator: " ") ?? "",
             record.latencyMilliseconds.map { String($0) } ?? ""]
        }
        // RFC 4180 ends every record, the last included, with CRLF.
        return ([csvHeader] + rows).map { $0.map(csvField).joined(separator: ",") + "\r\n" }.joined()
    }

    /// Quoted only when it has to be. A custom name is free text, so it can hold all of these.
    ///
    /// A value a spreadsheet would evaluate as a formula gets a leading `'` first. The names come
    /// from whatever the devices on the network announce over mDNS and SMB, so opening an export
    /// must not run what one of them chose to be called. Quoting does not prevent that.
    static func csvField(_ value: String) -> String {
        var value = value
        if let first = value.unicodeScalars.first, formulaLeads.contains(first) {
            value = "'" + value
        }
        // Scalars, not Characters: "\r\n" is a single Character in Swift, equal to neither "\r"
        // nor "\n", so a CRLF inside a value would slip past a Character test and split the row.
        guard value.unicodeScalars.contains(where: quotedScalars.contains) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static let quotedScalars: Set<Unicode.Scalar> = [",", "\"", "\n", "\r"]
    /// OWASP's list for CSV injection.
    private static let formulaLeads: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\t", "\r"]
}

/// nil for the "—" the scan uses to mean nothing was found, so JSON carries no placeholder.
func present(_ value: String) -> String? {
    value == DNSName.none || value.isEmpty ? nil : value
}

/// The vendor, keeping `Randomized`. `Device.hasVendor` treats it as missing because the window
/// styles it like an unknown one, but it is a finding — the address was never assigned — and
/// `search Randomized` matches on it, so hiding it would leave rows with no visible reason.
func knownVendor(of device: Device) -> String? {
    device.vendor == OUIDatabase.unknownVendor ? nil : device.vendor
}
