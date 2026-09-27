import Darwin
import Foundation

struct ResolvedAddresses: Sendable, Equatable {
    var ipv4: [String] = []
    var ipv6: [String] = []
    /// Why the resolver could not answer, when it could not. A name it does not know is not one of
    /// these: that is an answer, and it leaves this nil with both lists empty.
    var failure: String?

    var isEmpty: Bool { ipv4.isEmpty && ipv6.isEmpty }
}

/// Names to addresses, through the system resolver.
enum AddressResolver {
    /// Every address getaddrinfo(3) has for `name`, in the order it gave them. Blocks.
    ///
    /// getaddrinfo rather than dig(1), because it is the resolver the rest of the Mac uses: it
    /// reads /etc/hosts, follows the per-domain resolvers a VPN client installs, and hands `.local`
    /// to mDNSResponder. dig asks the one configured server and knows none of that. What it cannot
    /// do is reach a `.local` name across a router, since that query is multicast — which is what
    /// `search` is for.
    static func addresses(of name: String) -> ResolvedAddresses {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        // One entry per address rather than one per socket type.
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(name, nil, &hints, &list)
        guard status == 0, let first = list else {
            guard status != 0, status != EAI_NONAME else { return ResolvedAddresses() }
            let reason = status == EAI_SYSTEM
                ? String(cString: strerror(errno))
                : String(cString: gai_strerror(status))
            return ResolvedAddresses(failure: reason)
        }
        defer { freeaddrinfo(first) }

        var found = ResolvedAddresses()
        for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let address = entry.pointee.ai_addr else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = IPv4.decodedCString(buffer)
            switch Int32(address.pointee.sa_family) {
            case AF_INET where !found.ipv4.contains(text):
                found.ipv4.append(text)
            case AF_INET6 where !found.ipv6.contains(text):
                found.ipv6.append(text)
            default:
                continue
            }
        }
        return found
    }
}
