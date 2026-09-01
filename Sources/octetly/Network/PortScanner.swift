import Darwin
import Foundation

enum PortScanner {
    static let standardPorts = [22, 80, 443, 5900]

    static func openPorts(host: String) async -> Set<Int> {
        await withTaskGroup(of: (Int, Bool).self) { group in
            for port in standardPorts {
                group.addTask { (port, isOpen(host: host, port: port)) }
            }
            var open = Set<Int>()
            for await (port, reachable) in group where reachable { open.insert(port) }
            return open
        }
    }

    private static func isOpen(host: String, port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var timeout = timeval(tv_sec: 0, tv_usec: 350_000)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &destination.sin_addr) == 1 else { return false }

        return withUnsafePointer(to: &destination) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
