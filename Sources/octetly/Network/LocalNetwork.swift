import Darwin
import Foundation

struct LocalNetwork: Sendable {
    // Automatic detection stops far short of ScanRange.maximumHostCount: being attached to a
    // corporate or VPN /16 must not turn a plain Scan into a sweep of the whole thing. A span
    // that large is only scanned when someone entered it by hand.
    static let autoHostLimit = 1024

    let interface: String
    let address: String
    let netmask: String
    let macAddress: String?
    /// This interface's own IPv6 addresses.
    ///
    /// Used to recognise this Mac's own answer to the all-nodes multicast probe, which it makes
    /// like any other node on the segment. `ScanEngine.discoverIPv6` has what that recognition is
    /// for.
    let ipv6Addresses: [String]

    /// The interface's own network, e.g. 192.168.34.101/22.
    var cidr: String {
        guard let mask = IPv4.number(netmask) else { return address }
        return "\(address)/\(mask.nonzeroBitCount)"
    }

    static func current() -> LocalNetwork? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }

        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_LOOPBACK == 0,
                  entry.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  let address = numericAddress(entry.pointee.ifa_addr),
                  let maskPointer = entry.pointee.ifa_netmask,
                  let netmask = numericAddress(maskPointer) else { continue }

            let name = String(cString: entry.pointee.ifa_name)
            let network = LocalNetwork(interface: name, address: address, netmask: netmask,
                                       macAddress: hardwareAddress(of: name, from: first),
                                       ipv6Addresses: ipv6Addresses(of: name, from: first))
            guard network.autoRange != nil else { continue }
            return network
        }
        return nil
    }

    var autoRange: ScanRange? {
        guard let ip = IPv4.number(address), let mask = IPv4.number(netmask) else { return nil }
        let network = ip & mask
        let broadcast = network | ~mask
        // A /31 or /32 leaves no host range to walk, so the interface's own address is the target.
        guard broadcast > network + 1 else { return try? ScanRange.parse(address) }

        let first = network + 1
        let full = broadcast - 1
        let capped = min(full, first + UInt32(Self.autoHostLimit - 1))
        // Re-parsing rather than constructing keeps the label and the bounds from disagreeing.
        let text = capped == full
            ? "\(IPv4.string(network))/\(mask.nonzeroBitCount)"
            : "\(IPv4.string(first))-\(IPv4.string(capped))"
        return try? ScanRange.parse(text)
    }

    /// The interface's hardware address, which arrives as a separate AF_LINK entry in the same
    /// list rather than alongside the AF_INET one.
    private static func hardwareAddress(of name: String,
                                        from first: UnsafeMutablePointer<ifaddrs>) -> String? {
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard String(cString: entry.pointee.ifa_name) == name,
                  let socketAddress = entry.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_LINK) else { continue }

            let link = UnsafeRawPointer(socketAddress).assumingMemoryBound(to: sockaddr_dl.self)
            let addressLength = Int(link.pointee.sdl_alen)
            guard addressLength == 6 else { continue }

            // sdl_data holds the interface name and then the address, so the octets start past
            // whatever sdl_nlen says the name took.
            guard let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) else { continue }
            let octets = UnsafeRawPointer(link)
                .advanced(by: dataOffset + Int(link.pointee.sdl_nlen))
                .assumingMemoryBound(to: UInt8.self)
            return (0..<addressLength)
                .map { String(format: "%02X", octets[$0]) }
                .joined(separator: ":")
        }
        return nil
    }

    /// This interface's IPv6 addresses, which arrive as further AF_INET6 entries in the same list
    /// rather than alongside the AF_INET one.
    private static func ipv6Addresses(of name: String,
                                      from first: UnsafeMutablePointer<ifaddrs>) -> [String] {
        var found: [String] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard String(cString: entry.pointee.ifa_name) == name,
                  let socketAddress = entry.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET6),
                  let text = numericAddress(socketAddress),
                  let address = IPv6.canonical(text) else { continue }
            found.append(address)
        }
        return IPv6.routableFirst(found)
    }

    /// The pointer is passed through rather than copied: a sockaddr_in6 is 28 bytes and would lose
    /// its second half to a sockaddr-sized local.
    private static func numericAddress(_ socketAddress: UnsafePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(socketAddress, socklen_t(socketAddress.pointee.sa_len), &buffer,
                                 socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
        return result == 0 ? IPv4.decodedCString(buffer) : nil
    }
}
