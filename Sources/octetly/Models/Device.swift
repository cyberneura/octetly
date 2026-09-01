import Foundation

struct Device: Identifiable, Hashable, Sendable {
    var id: String { ipv4 }
    let ipv4: String
    var ipv6: String = "—"
    var macAddress: String = "—"
    var hostname: String = "—"
    var vendor: String = "Unknown"
    var dnsName: String = "—"
    var mdnsName: String = "—"
    var smbName: String = "—"
    var smbDomain: String = "—"
    var openPorts: Set<Int> = []
    var latencyMilliseconds: Double?
}
