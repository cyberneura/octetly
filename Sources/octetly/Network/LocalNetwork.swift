import Darwin
import Foundation

struct LocalNetwork: Sendable {
    let interface: String
    let address: String
    let netmask: String
    let hosts: [String]

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
            let hosts = hostAddresses(address: address, netmask: netmask)
            guard !hosts.isEmpty else { continue }
            return LocalNetwork(interface: name, address: address, netmask: netmask, hosts: hosts)
        }
        return nil
    }

    private static func numericAddress(_ socketAddress: UnsafePointer<sockaddr>) -> String? {
        var address = socketAddress.pointee
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(&address, socklen_t(address.sa_len), &buffer,
                                 socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
        return result == 0 ? decodedCString(buffer) : nil
    }

    private static func hostAddresses(address: String, netmask: String) -> [String] {
        guard let ip = ipv4Number(address), let mask = ipv4Number(netmask) else { return [] }
        let network = ip & mask
        let broadcast = network | ~mask
        guard broadcast > network + 1 else { return [address] }

        // Avoid accidentally sweeping very large enterprise/VPN networks.
        let count = min(Int(broadcast - network - 1), 1024)
        return (1...count).map { ipv4String(network + UInt32($0)) }
    }

    private static func ipv4Number(_ string: String) -> UInt32? {
        var address = in_addr()
        guard inet_pton(AF_INET, string, &address) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    private static func ipv4String(_ value: UInt32) -> String {
        var address = in_addr(s_addr: value.bigEndian)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN))
        return decodedCString(buffer)
    }

    private static func decodedCString(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}
