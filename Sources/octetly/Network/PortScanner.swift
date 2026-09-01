import Darwin
import Foundation

enum PortScanner {
    static let standardPorts = [22, 80, 443, 5900]

    static func openPorts(host: String, timeout: TimeInterval = 0.6) async -> Set<Int> {
        await withTaskGroup(of: (Int, Bool).self) { group in
            for port in standardPorts {
                group.addTask { (port, await BlockingWork.run { isOpen(host: host, port: port, timeout: timeout) }) }
            }
            var open = Set<Int>()
            for await (port, reachable) in group where reachable { open.insert(port) }
            return open
        }
    }

    private static func isOpen(host: String, port: Int, timeout: TimeInterval) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        // A blocking connect() ignores SO_SNDTIMEO and rides the kernel's TCP retransmit schedule
        // instead — over a minute against a host that silently drops the SYN, which is the normal
        // response from a firewalled port. Non-blocking plus poll() is what makes the timeout real.
        var flags = fcntl(descriptor, F_GETFL, 0)
        flags |= O_NONBLOCK
        guard fcntl(descriptor, F_SETFL, flags) == 0 else { return false }

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &destination.sin_addr) == 1 else { return false }

        let result = withUnsafePointer(to: &destination) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&event, 1, Int32(timeout * 1000)) > 0 else { return false }

        // poll() reports writability for a refused connection too, so the pending error decides.
        var failure: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length) == 0 else { return false }
        return failure == 0
    }
}
