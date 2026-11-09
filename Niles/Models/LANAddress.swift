import Foundation

/// The LAN address agents connect to, for the endpoint shown on the
/// dashboard and pairing screens.
enum LANAddress {
    /// The first IPv4 address of a physical interface (en0 preferred, then any
    /// other non-loopback), or nil when none is up. Not synchronized with
    /// interface changes; the dashboard refreshes it on every poll.
    static var primaryIPv4: String? {
        var rawAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&rawAddress) == 0, let first = rawAddress else { return nil }
        defer { freeifaddrs(first) }

        var fallback: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let interface = current.pointee.ifa_name.map({ String(cString: $0) }),
                let socket = current.pointee.ifa_addr,
                socket.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                socket, socklen_t(socket.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }

            let ip = Self.string(fromCString: host)
            guard ip != "127.0.0.1" else { continue }
            if interface == "en0" { return ip }
            fallback = fallback ?? ip
        }
        return fallback
    }

    private static func string(fromCString chars: [CChar]) -> String {
        let bytes = chars.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
