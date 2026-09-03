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
        withSocketAddress(host: host, port: port) { family, address, length in
            let descriptor = socket(family, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }

            // A blocking connect() ignores SO_SNDTIMEO and rides the kernel's TCP retransmit
            // schedule instead — over a minute against a host that silently drops the SYN, which
            // is the normal response from a firewalled port. Non-blocking plus poll() is what
            // makes the timeout real.
            var flags = fcntl(descriptor, F_GETFL, 0)
            flags |= O_NONBLOCK
            guard fcntl(descriptor, F_SETFL, flags) == 0 else { return false }

            if connect(descriptor, address, length) == 0 { return true }
            guard errno == EINPROGRESS else { return false }

            // A signal landing mid-wait is not a refused connection. The deadline is what decides
            // when to give up, so an interrupted poll resumes on what is left of it rather than
            // reporting a port that was still being connected to as closed.
            var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let deadline = Date().addingTimeInterval(timeout)
            var ready: Int32
            repeat {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return false }
                ready = poll(&event, 1, Int32(remaining * 1000))
            } while ready < 0 && errno == EINTR
            guard ready > 0 else { return false }

            // poll() reports writability for a refused connection too, so the pending error decides.
            var failure: Int32 = 0
            var errorLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &errorLength) == 0 else {
                return false
            }
            return failure == 0
        } ?? false
    }

    /// The address to connect to, whichever family the host is written in.
    ///
    /// AI_NUMERICHOST keeps this from ever reaching a resolver: every host here came out of a scan
    /// already numeric, so a name lookup would be a bug rather than a fallback. It is also what
    /// carries the zone of a link-local address through to `sin6_scope_id`, which connect() will
    /// not go anywhere without — the same `fe80::` address can be in use on another segment this
    /// Mac is attached to, so nothing but the zone says which link to open the socket on.
    private static func withSocketAddress<T>(
        host: String,
        port: Int,
        _ body: (Int32, UnsafePointer<sockaddr>, socklen_t) -> T
    ) -> T? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var resolved: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &resolved) == 0,
              let first = resolved, let address = first.pointee.ai_addr else { return nil }
        defer { freeaddrinfo(resolved) }
        return body(first.pointee.ai_family, address, first.pointee.ai_addrlen)
    }
}
