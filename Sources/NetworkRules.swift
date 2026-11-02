import Darwin
import Foundation

/// A network a share may connect on, recognised by the MAC address of its router (default gateway).
/// Works without Location Services: since macOS 14 reading the Wi-Fi name (SSID) needs location access,
/// and with an ad-hoc signed app macOS would ask again after every update. The router's MAC is the same on
/// Wi-Fi and Ethernet of one network and differs between networks, even when both use 192.168.1.1.
struct KnownNetwork: Codable, Hashable, Identifiable {
    var name: String
    /// Normalised "aa:bb:cc:dd:ee:ff".
    var router: String
    var id: String { router }

    init(name: String, router: String) {
        self.name = name
        self.router = NetworkIdentity.normalizeMAC(router) ?? router.lowercased()
    }

    enum CodingKeys: String, CodingKey { case name, router }

    // Hand-edited shares.json: normalise the MAC so "94-2A-…" still matches.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let router = try c.decode(String.self, forKey: .router)
        guard let mac = NetworkIdentity.normalizeMAC(router) else {
            throw DecodingError.dataCorruptedError(forKey: .router, in: c, debugDescription: "not a MAC address")
        }
        self.router = mac
        self.name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? mac
    }

    /// Decodes a list entry by entry: a broken entry is skipped instead of dropping the whole list
    /// (which the next save would make permanent); duplicates of the same router are dropped.
    static func decodeList(from c: KeyedDecodingContainer<Share.CodingKeys>, forKey key: Share.CodingKeys) -> [KnownNetwork] {
        guard var list = try? c.nestedUnkeyedContainer(forKey: key) else { return [] }
        var result: [KnownNetwork] = []
        while !list.isAtEnd {
            if let n = try? list.decode(KnownNetwork.self) {
                if !result.contains(where: { $0.router == n.router }) { result.append(n) }
            } else if (try? list.decode(Skip.self)) == nil {
                break
            }
        }
        return result
    }

    /// Consumes any JSON value, so the next entry can be read.
    private struct Skip: Decodable { init(from decoder: Decoder) throws {} }
}

enum NetworkIdentity {
    /// "2:0:5e:10:0:1", "02-00-5E-10-00-01", "0200.5e10.0001" or "02005e100001" → "02:00:5e:10:00:01".
    static func normalizeMAC(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        var bytes: [String]
        if s.contains(":") || s.contains("-") {
            bytes = s.split(whereSeparator: { $0 == ":" || $0 == "-" }).map(String.init)
            guard bytes.count == 6, bytes.allSatisfy({ (1...2).contains($0.count) }) else { return nil }
            bytes = bytes.map { $0.count == 1 ? "0" + $0 : $0 }
        } else {
            let hex = s.replacingOccurrences(of: ".", with: "")
            guard hex.count == 12 else { return nil }
            bytes = stride(from: 0, to: 12, by: 2).map {
                String(hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: $0 + 2)])
            }
        }
        guard bytes.allSatisfy({ UInt8($0, radix: 16) != nil }) else { return nil }
        let mac = bytes.joined(separator: ":")
        // All zeros or broadcast is never a real router or server.
        return mac == "00:00:00:00:00:00" || mac == "ff:ff:ff:ff:ff:ff" ? nil : mac
    }

    /// Neighbour (ARP) table as returned by sysctl NET_RT_FLAGS/RTF_LLINFO: routing messages, each followed by
    /// the destination (sockaddr_in) and the link-layer address (sockaddr_dl). Returns IPv4 → MAC.
    static func parseNeighbours(_ buf: [UInt8]) -> [String: String] {
        var result: [String: String] = [:]
        let hdr = MemoryLayout<rt_msghdr>.size
        buf.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off + hdr <= raw.count {
                let rtm = raw.loadUnaligned(fromByteOffset: off, as: rt_msghdr.self)
                let len = Int(rtm.rtm_msglen)
                guard len >= hdr, off + len <= raw.count else { break }
                defer { off += len }
                guard rtm.rtm_addrs & RTA_DST != 0, rtm.rtm_addrs & RTA_GATEWAY != 0 else { continue }
                var p = off + hdr
                guard p + MemoryLayout<sockaddr_in>.size <= off + len else { continue }
                var sin = raw.loadUnaligned(fromByteOffset: p, as: sockaddr_in.self)
                guard sin.sin_family == sa_family_t(AF_INET) else { continue }
                let saLen = Int(sin.sin_len)
                p += saLen > 0 ? (saLen + 3) & ~3 : 4
                // sockaddr_dl read byte by byte (it may be shorter than the struct): len, family, index (2),
                // type, nlen, alen, slen, then data = interface name followed by the address.
                guard p + 8 <= off + len else { continue }
                let dlLen = Int(raw[p]), nlen = Int(raw[p + 5]), alen = Int(raw[p + 6])
                guard raw[p + 1] == UInt8(AF_LINK), alen == 6 else { continue }
                let macAt = p + 8 + nlen
                guard macAt + 6 <= p + max(dlLen, 8), macAt + 6 <= off + len else { continue }
                let mac = (0..<6).map { String(format: "%02x", base.load(fromByteOffset: macAt + $0, as: UInt8.self)) }.joined(separator: ":")
                var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &sin.sin_addr, &ip, socklen_t(ip.count)) != nil,
                      let norm = normalizeMAC(mac) else { continue }
                result[String(cString: ip)] = norm
            }
        }
        return result
    }

    /// Reads the neighbour table of this Mac. Works for an app (launched from the Finder or at login) without
    /// any permission; command line tools started from an app get an empty table, so this runs in-process.
    static func neighbours() -> [String: String] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        for _ in 0..<3 {                                      // the table may grow between the two calls (ENOMEM)
            var len = 0
            guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [:] }
            len += len / 2
            var buf = [UInt8](repeating: 0, count: len)
            if sysctl(&mib, 6, &buf, &len, nil, 0) == 0 { return parseNeighbours(Array(buf.prefix(len))) }
            if errno != ENOMEM { return [:] }
        }
        return [:]
    }

    /// Whether a share may connect on the current network. No networks set = everywhere.
    /// `current` = router MACs of the current network, nil when they could not be determined.
    static func allows(_ networks: [KnownNetwork], current: Set<String>?) -> Bool {
        if networks.isEmpty { return true }
        guard let current, !current.isEmpty else { return false }
        return networks.contains { current.contains($0.router) }
    }

    /// Router MACs for the given IPv4 gateways. If a router is not in the neighbour table yet, a single UDP
    /// packet to it makes macOS look it up.
    static func routers(gateways: [String]) async -> Set<String> {
        let gws = gateways.filter(isIPv4)
        guard !gws.isEmpty else { return [] }
        var table = neighbours()
        if gws.contains(where: { table[$0] == nil }) {
            for gw in gws where table[gw] == nil { poke(gw) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            table = neighbours()
        }
        return Set(gws.compactMap { table[$0] })
    }

    static func isIPv4(_ s: String) -> Bool {
        var a = in_addr()
        return inet_pton(AF_INET, s, &a) == 1
    }

    /// Sends one empty UDP datagram to the discard port, only so that the router's MAC lands in the ARP table.
    private static func poke(_ ip: String) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(9).bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return }
        var byte: UInt8 = 0
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, &byte, 0, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

/// Wake on LAN: a "magic packet" (6 × 0xFF, then the MAC 16 times) as a UDP broadcast on port 9.
enum WakeOnLAN {
    static func packet(mac: String) -> Data? {
        guard let norm = NetworkIdentity.normalizeMAC(mac) else { return nil }
        let bytes = norm.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return nil }
        return Data(repeating: 0xFF, count: 6) + Data((0..<16).flatMap { _ in bytes })
    }

    /// Sends the packet to 255.255.255.255 and to the broadcast address of every IPv4 interface
    /// (macOS sends the limited broadcast only out of the primary interface). Returns true if at least one went out.
    @discardableResult
    static func send(mac: String) -> Bool {
        guard let data = packet(mac: mac) else { return false }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var sent = false
        for target in ["255.255.255.255"] + broadcastAddresses() {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(9).bigEndian
            guard inet_pton(AF_INET, target, &addr.sin_addr) == 1 else { continue }
            let n = data.withUnsafeBytes { buf in
                withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if n == data.count { sent = true }
        }
        return sent
    }

    private static func broadcastAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [String] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
                  let a = ifa.ifa_addr, a.pointee.sa_family == sa_family_t(AF_INET),
                  let b = ifa.ifa_dstaddr else { continue }
            var sin = b.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(buf.count)) != nil {
                let s = String(cString: buf)
                if !result.contains(s) { result.append(s) }
            }
        }
        return result
    }
}
