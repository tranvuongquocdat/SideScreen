import Foundation
import Darwin

enum LANAddressResolver {
    /// Returns the first non-loopback, non-link-local IPv4 address from `getifaddrs`,
    /// preferring `en0` (typical Wi-Fi / Ethernet) when present.
    static func primaryIPv4() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var candidates: [(name: String, ip: String)] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let flags = Int32(cur.pointee.ifa_flags)
            if let addr = cur.pointee.ifa_addr {
                let family = addr.pointee.sa_family
                if (flags & IFF_UP) != 0,
                   (flags & IFF_LOOPBACK) == 0,
                   family == sa_family_t(AF_INET) {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let rc = getnameinfo(
                        addr,
                        socklen_t(addr.pointee.sa_len),
                        &host, socklen_t(host.count),
                        nil, 0,
                        NI_NUMERICHOST
                    )
                    if rc == 0, let ip = String(validatingUTF8: host),
                       !isLoopback(ip), !isLinkLocal(ip) {
                        let name = String(cString: cur.pointee.ifa_name)
                        candidates.append((name, ip))
                    }
                }
            }
            ptr = cur.pointee.ifa_next
        }

        if let en0 = candidates.first(where: { $0.name == "en0" }) { return en0.ip }
        if let enN = candidates.first(where: { $0.name.hasPrefix("en") }) { return enN.ip }
        return candidates.first?.ip
    }

    static func isLoopback(_ ip: String) -> Bool {
        ip == "127.0.0.1" || ip == "::1" || ip.hasPrefix("127.")
    }

    static func isLinkLocal(_ ip: String) -> Bool {
        ip.hasPrefix("169.254.")
    }
}
