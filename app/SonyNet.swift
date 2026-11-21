// SonyNet.swift (v21): bytes, a blocking TCP socket and SSDP for the Sony module. Moved from SONY_REMOTE_MAC (Bytes.swift,
// Socket.swift; our own code), names prefixed Sony so nothing meets the recorder's own types. New here: SSDP asks on EVERY
// local IPv4 interface (Wi-Fi, the AX88179 cable, …), because the Mac's default route may be the Nothing hotspot or the
// Tailscale exit node while the camera sits on the Mantra router's 192.168.1.x; and a saved address is tried directly.
import Foundation
import Darwin

struct SonyWriter {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
    mutating func bytes(_ d: Data) { data.append(d) }
    /// PTP-IP friendly name: UTF-16LE characters and a 0x0000 at the end, no length in front
    mutating func utf16z(_ s: String) { for c in s.utf16 { u16(c) }; u16(0) }
    /// an unsigned value in n bytes, little endian
    mutating func uint(_ v: UInt64, bytes n: Int) { for i in 0..<n { data.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }
}

struct SonyReader {
    let data: Data
    var at: Int = 0
    init(_ d: Data) { data = Data(d) }        // a fresh copy: indices start at 0
    var left: Int { data.count - at }
    enum Short: Error { case end }
    mutating func need(_ n: Int) throws { if n < 0 || at + n > data.count { throw Short.end } }
    mutating func u8() throws -> UInt8 { try need(1); defer { at += 1 }; return data[at] }
    mutating func u16() throws -> UInt16 { try need(2); defer { at += 2 }; return UInt16(data[at]) | UInt16(data[at + 1]) << 8 }
    mutating func u32() throws -> UInt32 {
        try need(4); defer { at += 4 }
        return UInt32(data[at]) | UInt32(data[at + 1]) << 8 | UInt32(data[at + 2]) << 16 | UInt32(data[at + 3]) << 24
    }
    mutating func u64() throws -> UInt64 { let lo = UInt64(try u32()); let hi = UInt64(try u32()); return lo | hi << 32 }
    mutating func skip(_ n: Int) throws { try need(n); at += n }
    mutating func take(_ n: Int) throws -> Data { try need(n); defer { at += n }; return data.subdata(in: at..<(at + n)) }
    mutating func utf16z() throws -> String {
        var units: [UInt16] = []
        while true { let c = try u16(); if c == 0 { break }; units.append(c) }
        return String(decoding: units, as: UTF16.self)
    }
}

extension Data {
    func sonyU32(at i: Int) -> UInt32? {
        guard i >= 0, i + 4 <= count else { return nil }
        let b = startIndex + i
        return UInt32(self[b]) | UInt32(self[b + 1]) << 8 | UInt32(self[b + 2]) << 16 | UInt32(self[b + 3]) << 24
    }
}

func sonyHex(_ v: UInt16) -> String { String(format: "0x%04X", v) }

enum SonyNetError: Error, CustomStringConvertible {
    case resolve(String), connect(String), closed, timeout, io(String)
    var description: String {
        switch self {
        case .resolve(let h): return "cannot find \(h)"
        case .connect(let m): return "cannot connect: \(m)"
        case .closed: return "the camera closed the connection"
        case .timeout: return "the camera did not answer in time"
        case .io(let m): return m
        }
    }
}

final class SonyTCP {
    private(set) var fd: Int32 = -1
    let host: String
    let port: UInt16

    init(host: String, port: UInt16, connectTimeout: Double = 6) throws {
        self.host = host; self.port = port
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { throw SonyNetError.resolve(host) }
        defer { freeaddrinfo(res) }
        let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard s >= 0 else { throw SonyNetError.connect("no socket") }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(s, F_GETFL, 0)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)      // an absent camera fails in seconds, not in 75 s
        let r = Darwin.connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
        if r != 0 {
            guard errno == EINPROGRESS else { Darwin.close(s); throw SonyNetError.connect(String(cString: strerror(errno))) }
            var p = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            let n = poll(&p, 1, Int32(connectTimeout * 1000))
            if n <= 0 { Darwin.close(s); throw SonyNetError.connect("no answer from \(host):\(port)") }
            var err: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
            if err != 0 { Darwin.close(s); throw SonyNetError.connect(String(cString: strerror(err))) }
        }
        _ = fcntl(s, F_SETFL, flags & ~O_NONBLOCK)
        fd = s
        setReadTimeout(10)
    }

    func setReadTimeout(_ seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func send(_ d: Data) throws {
        guard fd >= 0 else { throw SonyNetError.closed }
        try d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            var off = 0
            while off < d.count {
                let n = Darwin.send(fd, p.baseAddress!.advanced(by: off), d.count - off, 0)
                if n <= 0 { throw SonyNetError.io("send failed: \(String(cString: strerror(errno)))") }
                off += n
            }
        }
    }

    func read(_ n: Int) throws -> Data {
        guard fd >= 0 else { throw SonyNetError.closed }
        var out = Data(count: n)
        var got = 0
        try out.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
            while got < n {
                let r = recv(fd, p.baseAddress!.advanced(by: got), n - got, 0)
                if r == 0 { throw SonyNetError.closed }
                if r < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK { throw SonyNetError.timeout }
                    if errno == EINTR { continue }
                    throw SonyNetError.io("read failed: \(String(cString: strerror(errno)))")
                }
                got += r
            }
        }
        return out
    }

    func close() { if fd >= 0 { Darwin.close(fd); fd = -1 } }
    deinit { close() }

    static func canConnect(_ host: String, _ port: UInt16, timeout: Double = 0.5) -> Bool {
        (try? SonyTCP(host: host, port: port, connectTimeout: timeout))?.close() != nil
    }

    static func freePort() -> UInt16 {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(s) }
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = 0; a.sin_addr.s_addr = inet_addr("127.0.0.1")
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        let p = UInt16(bigEndian: a.sin_port)
        return p == 0 ? 47_150 : p
    }
}

/// SSDP (UPnP discovery): M-SEARCH for Sony's DigitalImaging service on every local IPv4 interface; the LOCATION of each answer.
enum SonySSDP {
    /// (interface name, address) of each IPv4 interface that is up, not loopback and not a tunnel (utun = Tailscale)
    static func interfaces() -> [(String, String)] {
        var out: [(String, String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return out }
        defer { freeifaddrs(list) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            defer { p = i.pointee.ifa_next }
            let flags = Int32(i.pointee.ifa_flags)
            guard let a = i.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_MULTICAST != 0 else { continue }
            let name = String(cString: i.pointee.ifa_name)
            if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("awdl") || name.hasPrefix("llw") { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append((name, String(cString: host)))
            }
        }
        return out
    }

    static func search(seconds: Double = 4, log: ((String) -> Void)? = nil) -> [String] {
        let ifs = interfaces()
        log?("asking for a Sony camera on " + (ifs.isEmpty ? "no network" : ifs.map { "\($0.0) \($0.1)" }.joined(separator: ", ")))
        var found: [String] = []
        let lock = NSLock()
        let group = DispatchGroup()
        for (_, addr) in ifs {
            group.enter()
            DispatchQueue.global().async {
                let r = SonySSDP.searchOn(addr, seconds: seconds)
                lock.lock(); for l in r where !found.contains(l) { found.append(l) }; lock.unlock()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + seconds + 1)
        lock.lock(); defer { lock.unlock() }
        return found
    }

    private static func searchOn(_ local: String, seconds: Double) -> [String] {
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { return [] }
        defer { Darwin.close(s) }
        var ttl: UInt8 = 2
        setsockopt(s, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(1))
        var ifaddr = in_addr(s_addr: inet_addr(local))
        setsockopt(s, IPPROTO_IP, IP_MULTICAST_IF, &ifaddr, socklen_t(MemoryLayout<in_addr>.size))
        var me = sockaddr_in(); me.sin_family = sa_family_t(AF_INET); me.sin_port = 0; me.sin_addr.s_addr = inet_addr(local)
        me.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &me) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var to = sockaddr_in(); to.sin_family = sa_family_t(AF_INET); to.sin_port = UInt16(1900).bigEndian
        to.sin_addr.s_addr = inet_addr("239.255.255.250"); to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\n" +
                  "ST: urn:schemas-sony-com:service:DigitalImaging:1\r\n\r\n"
        let bytes = Array(msg.utf8)
        var found: [String] = []
        let end = Date().addingTimeInterval(seconds)
        var lastSend = Date.distantPast
        var buf = [UInt8](repeating: 0, count: 4096)
        while Date() < end {
            if Date().timeIntervalSince(lastSend) > 1.2 {
                _ = withUnsafePointer(to: &to) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(s, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                lastSend = Date()
            }
            let n = recv(s, &buf, buf.count, 0)
            guard n > 0 else { continue }
            let text = String(decoding: buf[0..<n], as: UTF8.self)
            for line in text.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("location:") {
                let loc = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)
                if !found.contains(loc) { found.append(loc) }
            }
        }
        return found
    }
}
