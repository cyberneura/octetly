import Darwin
import Foundation

enum IPv6 {
    /// The 16 bytes behind an address, for ordering and for comparing two spellings of one address.
    static func bytes(_ string: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, withoutZone(string), &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    /// The zone that `fe80::1%en0` carries, and the address without it.
    ///
    /// A link-local address does not identify a host on its own: the same one can be in use on
    /// another segment this Mac is attached to, and only the zone says which link is meant. So the
    /// zone stays in what is stored and displayed, and comes off only where the address itself has
    /// to be parsed.
    static func withoutZone(_ string: String) -> String {
        guard let separator = string.firstIndex(of: "%") else { return string }
        return String(string[..<separator])
    }

    static func zone(_ string: String) -> String? {
        guard let separator = string.firstIndex(of: "%") else { return nil }
        return String(string[string.index(after: separator)...])
    }

    /// One spelling per address, so that what ndp(8) printed and what a reply arrived from compare
    /// equal. Both go through inet_ntop already, but nothing promises that of a third source.
    static func canonical(_ string: String) -> String? {
        guard var address = inAddr(string) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
            return nil
        }
        let text = IPv4.decodedCString(buffer)
        return zone(string).map { "\(text)%\($0)" } ?? text
    }

    static func isValid(_ string: String) -> Bool { bytes(string) != nil }

    /// fe80::/10, the addresses a host configures without being told to and the only kind on a
    /// network with no router advertisement.
    static func isLinkLocal(_ string: String) -> Bool {
        guard let bytes = bytes(string) else { return false }
        return bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80
    }

    /// ff00::/8 — a group rather than a host, so never a device.
    static func isMulticast(_ string: String) -> Bool {
        guard let bytes = bytes(string) else { return false }
        return bytes[0] == 0xFF
    }

    /// Routable addresses first.
    ///
    /// A host with a global or unique-local address is reachable at it from off the segment, which
    /// a link-local address never is, so that is the one to lead with where a host has both. On a
    /// network with no router advertisement — the one this was written on — there are only
    /// link-local ones, and a NIC often has more than one against its name in the cache. Which of
    /// them the host still holds is not something the cache says, since an entry outlives its use
    /// by most of a day.
    static func routableFirst(_ addresses: some Sequence<String>) -> [String] {
        addresses.sorted { left, right in
            let leftIsLocal = isLinkLocal(left)
            let rightIsLocal = isLinkLocal(right)
            if leftIsLocal != rightIsLocal { return !leftIsLocal }
            return left < right
        }
    }

    /// A destination for connect() or sendto(), with the zone resolved to an interface index.
    static func socketAddress(_ string: String, port: UInt16 = 0) -> sockaddr_in6? {
        guard let address = inAddr(string) else { return nil }
        var destination = sockaddr_in6()
        destination.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        destination.sin6_family = sa_family_t(AF_INET6)
        destination.sin6_port = port.bigEndian
        destination.sin6_addr = address
        if let zone = zone(string) { destination.sin6_scope_id = if_nametoindex(zone) }
        return destination
    }

    /// How an address that arrived over the wire is written down: `fe80::1%en0`, matching ndp(8),
    /// because getnameinfo appends the zone name for a scoped address.
    static func numericAddress(_ address: sockaddr_in6) -> String? {
        var storage = address
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                getnameinfo(generic, socklen_t(MemoryLayout<sockaddr_in6>.size), &buffer,
                            socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
            }
        }
        guard result == 0 else { return nil }
        return canonical(IPv4.decodedCString(buffer))
    }

    private static func inAddr(_ string: String) -> in6_addr? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, withoutZone(string), &address) == 1 else { return nil }
        return address
    }
}
