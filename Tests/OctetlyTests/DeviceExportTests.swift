import Foundation
import Testing

@testable import Octetly

@Suite("DeviceExport")
struct DeviceExportTests {
    @Test("A field is quoted only when it holds a comma, a quote or a line break")
    func csvField() {
        #expect(DeviceExport.csvField("nas.local") == "nas.local")
        #expect(DeviceExport.csvField("") == "")
        #expect(DeviceExport.csvField("Desk, left") == "\"Desk, left\"")
        // A quote inside is doubled, so a reader does not take it for the end of the field.
        #expect(DeviceExport.csvField("The \"big\" one") == "\"The \"\"big\"\" one\"")
        #expect(DeviceExport.csvField("two\nlines") == "\"two\nlines\"")
        // Swift reads CRLF as one Character, which is neither "\r" nor "\n" on its own.
        #expect(DeviceExport.csvField("two\r\nlines") == "\"two\r\nlines\"")
    }

    @Test("A value a spreadsheet would run as a formula is turned into text")
    func csvFormula() {
        #expect(DeviceExport.csvField("=HYPERLINK(\"x\")") == "\"'=HYPERLINK(\"\"x\"\")\"")
        #expect(DeviceExport.csvField("+1") == "'+1")
        #expect(DeviceExport.csvField("-1") == "'-1")
        #expect(DeviceExport.csvField("@SUM(A1)") == "'@SUM(A1)")
        #expect(DeviceExport.csvField("\tx") == "'\tx")
        // A carriage return also needs quoting, after the prefix.
        #expect(DeviceExport.csvField("\rx") == "\"'\rx\"")
        // Only the first character counts: these are ordinary values.
        #expect(DeviceExport.csvField("nas-1.local") == "nas-1.local")
        #expect(DeviceExport.csvField("fe80::1%en0") == "fe80::1%en0")
    }

    @Test("A row has a cell for every header, with nothing found left empty rather than as —")
    func csvRow() {
        // Arrange
        var host = Device(ipv4: "192.168.0.9")
        host.add(ipv6: ["fe80::1%en0", "2001:db8::1"])
        host.macAddress = "00:11:32:69:6B:5F"
        host.vendor = "Synology Incorporated"
        host.hostname = "nas.local"
        host.mdnsName = "nas.local"
        host.customName = "NAS, upstairs"
        host.openPorts = [443, 22]
        host.portScanState = .done
        host.latencyMilliseconds = 2.5

        // Act
        let lines = DeviceExport.csv([DeviceRecord(host)]).components(separatedBy: "\r\n")

        // Assert — the last record ends with CRLF too, so the text ends in an empty piece.
        #expect(lines.count == 3)
        #expect(lines[0] == DeviceExport.csvHeader.joined(separator: ","))
        #expect(lines[1] == "192.168.0.9,2001:db8::1 fe80::1%en0,\"NAS, upstairs\",\"NAS, upstairs\",,"
            + "nas.local,,,00:11:32:69:6B:5F,Synology Incorporated,22 443,2.5")
        #expect(lines[2] == "")
    }

    @Test("Ports never scanned are absent, while a scan that found none is an empty list")
    func ports() throws {
        // Arrange
        let unscanned = Device(ipv4: "192.168.0.9")
        var closed = Device(ipv4: "192.168.0.10")
        closed.portScanState = .done

        // Act
        let records = [DeviceRecord(unscanned), DeviceRecord(closed)]
        let json = try DeviceExport.json(records)
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]

        // Assert — "not looked at" and "none open" are different findings.
        #expect(records[0].openPorts == nil)
        #expect(records[1].openPorts == [])
        #expect(decoded?[0]["openPorts"] == nil)
        #expect((decoded?[1]["openPorts"] as? [Int]) == [])
        // The table's placeholder is not carried into the file.
        #expect(decoded?[0]["macAddress"] == nil)
        #expect(decoded?[0]["vendor"] == nil)
    }
}
