// LanSweep.swift (v39, 25.11.2026): the network sweep of LAN Scanner (Mantra), copied faithfully from its repository
// (markoboskoauroville/LAN_SCANNER at bd580de: app/Model.swift NetInfo/CIDR/MAC/ARPText, app/Engine.swift Sh/Net/ARP/Wire/
// Sweep) so the Sony SCAN uses the same engine, not a second scanner. Marko: "The code for scanning the network we already
// have ... We have a Mantra scanner, LAN scanner available." Changes: everything sits inside `enum Lan` so no name meets the
// recorder's own types, and Net.title(for:) no longer asks CoreWLAN for the Wi-Fi name (that needs Location access; the
// interface name is enough here). The steps are LAN Scanner's: the interfaces with their netmask, an unprivileged ICMP echo
// plus a NetBIOS query to every host (capped to the /22 around the Mac), then the kernel's ARP table read with sysctl as
// the truth. Keep this file the same as LAN Scanner's engine when either changes.
import Foundation
import Darwin

enum Lan {
struct NetInfo {
    var iface: String            // en0
    var ip: String               // this Mac's address on it
    var mask: UInt32
    var prefix: Int
    var gateway: String?
    var title: String            // Wi-Fi name, or "Wi-Fi (en0)"
    var index: UInt32            // if_nametoindex
}

enum CIDR {
    static func parse(_ ip: String) -> UInt32? {
        let p = ip.split(separator: ".")
        guard p.count == 4 else { return nil }
        var v: UInt32 = 0
        for s in p {
            guard let n = UInt32(s), n < 256 else { return nil }
            v = (v << 8) | n
        }
        return v
    }
    static func string(_ v: UInt32) -> String { "\(v >> 24).\((v >> 16) & 255).\((v >> 8) & 255).\(v & 255)" }
    static func prefix(ofMask m: UInt32) -> Int { m.nonzeroBitCount }
    static func mask(prefix: Int) -> UInt32 { prefix <= 0 ? 0 : (prefix >= 32 ? 0xFFFF_FFFF : ~UInt32(0) << UInt32(32 - prefix)) }

    /// The host addresses to sweep. A network wider than /22 is cut to the /22 around this Mac's address (cap 1024).
    /// Returns the addresses, the prefix really scanned and whether it was cut.
    static func hosts(ip: UInt32, prefix: Int) -> (hosts: [UInt32], scannedPrefix: Int, capped: Bool) {
        var pf = prefix
        var capped = false
        if pf < 22 { pf = 22; capped = true }
        if pf >= 31 { return ([], pf, capped) }
        let m = mask(prefix: pf)
        let net = ip & m
        let bc = net | ~m
        var out: [UInt32] = []
        var a = net + 1
        while a < bc { if a != ip { out.append(a) }; a += 1 }
        return (out, pf, capped)
    }
    static func network(ip: UInt32, prefix: Int) -> String { "\(string(ip & mask(prefix: prefix)))/\(prefix)" }
    static func contains(ip: UInt32, net: UInt32, prefix: Int) -> Bool { (ip & mask(prefix: prefix)) == (net & mask(prefix: prefix)) }
    static func isBroadcastOrMulticast(_ ip: UInt32, ownIP: UInt32, prefix: Int) -> Bool {
        if (ip >> 28) == 0xE { return true }                       // 224.0.0.0/4
        if ip == 0xFFFF_FFFF { return true }
        let m = mask(prefix: prefix)
        if prefix < 31 && ip == ((ownIP & m) | ~m) { return true } // the subnet broadcast
        return false
    }
}

enum MAC {
    /// "0:1a:2b:3c:4d:5e" or "00-1A-2B-3C-4D-5E" -> "00:1a:2b:3c:4d:5e"; nil when it is not six bytes.
    static func normalize(_ s: String) -> String? {
        let parts = s.lowercased().split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }
        var out: [String] = []
        for p in parts {
            guard p.count <= 2, let _ = UInt8(p, radix: 16) else { return nil }
            out.append(p.count == 1 ? "0" + p : String(p))
        }
        return out.joined(separator: ":")
    }
    static func isBroadcastOrMulticast(_ mac: String) -> Bool {
        guard let first = UInt8(mac.prefix(2), radix: 16) else { return true }
        return mac == "ff:ff:ff:ff:ff:ff" || (first & 0x01) == 1
    }
    /// Locally administered (bit 2 of the first byte): a phone's random Wi-Fi address, it has no real maker.
    static func isPrivate(_ mac: String) -> Bool {
        guard let first = UInt8(mac.prefix(2), radix: 16) else { return false }
        return (first & 0x02) != 0
    }
    static func prefix6(_ mac: String) -> String { mac.replacingOccurrences(of: ":", with: "").prefix(6).uppercased() }
}

enum ARPText {
    /// One line of `arp -an`: "? (192.168.1.1) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]".
    /// Incomplete entries ("(incomplete)") give nil.
    static func parse(line: String) -> (ip: String, mac: String, iface: String)? {
        guard let o = line.firstIndex(of: "("), let c = line.firstIndex(of: ")"), o < c else { return nil }
        let ip = String(line[line.index(after: o)..<c])
        guard CIDR.parse(ip) != nil else { return nil }
        let rest = line[line.index(after: c)...].split(separator: " ").map(String.init)
        guard let at = rest.firstIndex(of: "at"), at + 1 < rest.count, let mac = MAC.normalize(rest[at + 1]) else { return nil }
        var iface = ""
        if let on = rest.firstIndex(of: "on"), on + 1 < rest.count { iface = rest[on + 1] }
        return (ip, mac, iface)
    }
}
enum Sh {
    /// Runs a tool and returns its stdout, nil on failure or timeout.
    static func run(_ exe: String, _ args: [String], timeout: Double = 5) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        var data = Data()
        let g = DispatchGroup(); g.enter()
        DispatchQueue.global().async { data = out.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        if g.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return nil }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

enum Net {
    static let skipPrefixes = ["lo", "utun", "bridge", "awdl", "llw", "gif", "stf", "ap", "anpi", "pktap", "vmenet", "ipsec", "ppp"]

    static func activeInterfaces() -> [NetInfo] {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        var out: [NetInfo] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            p = a.pointee.ifa_next
            let name = String(cString: a.pointee.ifa_name)
            let flags = Int32(a.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            if skipPrefixes.contains(where: { name.hasPrefix($0) }) { continue }
            guard let addr = a.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let nm = a.pointee.ifa_netmask else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if (ip >> 16) == 0xA9FE { continue }          // 169.254 link-local: no network
            let pf = CIDR.prefix(ofMask: mask)
            if pf >= 31 || pf == 0 { continue }
            if out.contains(where: { $0.iface == name }) { continue }
            out.append(NetInfo(iface: name, ip: CIDR.string(ip), mask: mask, prefix: pf, gateway: nil,
                               title: name, index: if_nametoindex(name)))
        }
        for i in out.indices {
            out[i].gateway = gateway(for: out[i].iface)
            out[i].title = title(for: out[i].iface)
        }
        return out
    }

    /// The interface that carries the default route ("the current network"), else the first one with a gateway.
    static func current(from list: [NetInfo]) -> NetInfo? {
        if let r = Sh.run("/sbin/route", ["-n", "get", "default"]) {
            for line in r.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("interface:") {
                    let n = t.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
                    if let hit = list.first(where: { $0.iface == n }) { return hit }
                }
            }
        }
        return list.first(where: { $0.gateway != nil && $0.iface.hasPrefix("en") }) ?? list.first(where: { $0.gateway != nil }) ?? list.first
    }

    static func gateway(for iface: String) -> String? {
        guard let t = Sh.run("/usr/sbin/netstat", ["-rn", "-f", "inet"]) else { return nil }
        for line in t.split(separator: "\n") {
            let f = line.split(separator: " ").map(String.init)
            if f.count >= 4, f[0] == "default", CIDR.parse(f[1]) != nil, f.contains(iface) { return f[1] }
        }
        return nil
    }

    static func title(for iface: String) -> String {
        if let t = Sh.run("/usr/sbin/networksetup", ["-listallhardwareports"]) {
            var port = ""
            for line in t.split(separator: "
") {
                if line.hasPrefix("Hardware Port:") { port = line.dropFirst("Hardware Port:".count).trimmingCharacters(in: .whitespaces) }
                if line.hasPrefix("Device:"), line.dropFirst("Device:".count).trimmingCharacters(in: .whitespaces) == iface, !port.isEmpty {
                    return "\(port) (\(iface))"
                }
            }
        }
        return iface
    }

    static func ownMAC(_ iface: String) -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            p = a.pointee.ifa_next
            guard String(cString: a.pointee.ifa_name) == iface, let addr = a.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_LINK) else { continue }
            let raw = UnsafeRawPointer(addr)
            let nlen = Int(raw.load(fromByteOffset: 5, as: UInt8.self)), alen = Int(raw.load(fromByteOffset: 6, as: UInt8.self))
            guard alen == 6 else { continue }
            let bytes = (0..<6).map { raw.load(fromByteOffset: 8 + nlen + $0, as: UInt8.self) }
            return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        }
        return nil
    }
}
// MARK: ARP cache

enum ARP {
    /// The kernel's ARP table for one interface, read with sysctl (no tool). nil when sysctl failed.
    static func readSysctl(index: UInt32) -> [(ip: String, mac: String)]? {
        // CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO
        var mib: [Int32] = [4, 17, 0, 2, 2, 0x400]
        var len = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) == 0 else { return nil }
        if len == 0 { return [] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, UInt32(mib.count), &buf, &len, nil, 0) == 0 else { return nil }
        var out: [(String, String)] = []
        var off = 0
        let hdr = 92                                           // sizeof(struct rt_msghdr) on macOS
        while off + hdr + 24 <= len {
            let msglen = Int(buf[off]) | (Int(buf[off + 1]) << 8)
            if msglen < hdr { break }
            let ifIndex = UInt32(buf[off + 4]) | (UInt32(buf[off + 5]) << 8)
            let sin = off + hdr                                // sockaddr_inarp
            let sinLen = Int(buf[sin])
            let sdl = sin + (sinLen > 0 ? (1 + ((sinLen - 1) | 3)) : 4)   // ROUNDUP to 4
            if sdl + 8 <= len, buf[sin + 1] == 2 {
                let nlen = Int(buf[sdl + 5]), alen = Int(buf[sdl + 6])
                if alen == 6, sdl + 8 + nlen + 6 <= len, index == 0 || ifIndex == index {
                    let ip = "\(buf[sin + 4]).\(buf[sin + 5]).\(buf[sin + 6]).\(buf[sin + 7])"
                    let mac = (0..<6).map { String(format: "%02x", buf[sdl + 8 + nlen + $0]) }.joined(separator: ":")
                    out.append((ip, mac))
                }
            }
            off += msglen
        }
        return out
    }

    /// The same table through /usr/sbin/arp -an (fallback, and the independent truth check).
    static func readArpTool(iface: String) -> [(ip: String, mac: String)] {
        guard let t = Sh.run("/usr/sbin/arp", ["-an", "-i", iface]) else { return [] }
        return t.split(separator: "\n").compactMap { ARPText.parse(line: String($0)) }.filter { $0.iface == iface || $0.iface.isEmpty }.map { ($0.ip, $0.mac) }
    }

    static func read(net: NetInfo) -> [(ip: String, mac: String)] {
        let raw = readSysctl(index: net.index) ?? readArpTool(iface: net.iface)
        let own = CIDR.parse(net.ip) ?? 0
        let netAddr = own & net.mask
        var seen = Set<String>(), out: [(String, String)] = []
        for e in raw {
            guard let v = CIDR.parse(e.ip), CIDR.contains(ip: v, net: netAddr, prefix: net.prefix),
                  !CIDR.isBroadcastOrMulticast(v, ownIP: own, prefix: net.prefix),
                  !MAC.isBroadcastOrMulticast(e.mac), !seen.contains(e.ip) else { continue }
            seen.insert(e.ip); out.append(e)
        }
        return out
    }
}

// MARK: sockets

enum Wire {
    static func sockaddr(_ ip: UInt32, port: UInt16) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = ip.bigEndian
        return a
    }

    static func send(_ fd: Int32, _ data: [UInt8], to ip: UInt32, port: UInt16) -> Bool {
        var a = sockaddr(ip, port: port)
        let n = withUnsafePointer(to: &a) { p in
            p.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { sendto(fd, data, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return n >= 0
    }

    static func checksum(_ d: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < d.count { sum += (UInt32(d[i]) << 8) | UInt32(d[i + 1]); i += 2 }
        if i < d.count { sum += UInt32(d[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum & 0xFFFF)
    }

    static func echoRequest(seq: UInt16) -> [UInt8] {
        var p: [UInt8] = [8, 0, 0, 0, 0x4C, 0x53, UInt8(seq >> 8), UInt8(seq & 255), 0x4D, 0x41, 0x4E, 0x54, 0x52, 0x41, 0x21, 0x21]
        let c = checksum(p)
        p[2] = UInt8(c >> 8); p[3] = UInt8(c & 255)
        return p
    }

    /// NetBIOS node-status query for "*": hosts that speak it answer with their name.
    static let nbstat: [UInt8] = {
        var p: [UInt8] = [0x4D, 0x4C, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0x20, 0x43, 0x4B]
        p += [UInt8](repeating: 0x41, count: 30)
        p += [0, 0, 0x21, 0, 1]
        return p
    }()

    /// The host name inside a node-status reply, nil when it is not one.
    static func nbName(from d: [UInt8]) -> String? {
        guard d.count > 57, d[4] == 0, d[5] == 0 else { return nil }
        let count = Int(d[56])
        var i = 57
        for _ in 0..<count {
            guard i + 18 <= d.count else { break }
            let suffix = d[i + 15], flags = (UInt16(d[i + 16]) << 8) | UInt16(d[i + 17])
            if suffix == 0 && (flags & 0x8000) == 0 {
                let raw = String(decoding: d[i..<(i + 15)], as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
                return raw.isEmpty ? nil : raw
            }
            i += 18
        }
        return nil
    }

    static func nonblocking(_ fd: Int32) {
        let fl = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK)
    }

    static func bind(_ fd: Int32, toInterface index: UInt32) {
        var i = index
        _ = setsockopt(fd, IPPROTO_IP, 25 /* IP_BOUND_IF */, &i, socklen_t(MemoryLayout<UInt32>.size))
    }
}

final class Sweep {
    var pinged = Set<UInt32>()
    var nbNames: [UInt32: String] = [:]
    var attempts = 0, failures = 0
    private let icmp: Int32, udp: Int32

    init(ifaceIndex: UInt32) {
        icmp = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        udp = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        for fd in [icmp, udp] where fd >= 0 { Wire.nonblocking(fd); Wire.bind(fd, toInterface: ifaceIndex) }
    }
    deinit { if icmp >= 0 { close(icmp) }; if udp >= 0 { close(udp) } }
    var usable: Bool { icmp >= 0 || udp >= 0 }

    /// Reads whatever has arrived for up to `ms` milliseconds.
    func drain(ms: Int32) {
        var fds: [pollfd] = []
        if icmp >= 0 { fds.append(pollfd(fd: icmp, events: Int16(POLLIN), revents: 0)) }
        if udp >= 0 { fds.append(pollfd(fd: udp, events: Int16(POLLIN), revents: 0)) }
        if fds.isEmpty { return }
        let end = Date().addingTimeInterval(Double(ms) / 1000)
        while true {
            let left = Int32(max(0, end.timeIntervalSinceNow * 1000))
            for i in fds.indices { fds[i].revents = 0 }
            let r = poll(&fds, nfds_t(fds.count), left)
            if r <= 0 { return }
            for f in fds where f.revents & Int16(POLLIN) != 0 { readOne(f.fd) }
            if left == 0 { return }
        }
    }

    private func readOne(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 1500)
        var from = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) { fp in
            fp.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
        }
        guard n > 0 else { return }
        let src = UInt32(bigEndian: from.sin_addr.s_addr)
        if fd == icmp {
            let ihl = (buf[0] >> 4) == 4 ? Int(buf[0] & 0x0F) * 4 : 0
            if ihl < n, buf[ihl] == 0 { pinged.insert(src) }          // echo reply
        } else if let name = Wire.nbName(from: Array(buf[0..<n])) {
            nbNames[src] = name
        }
    }

    /// Probes the hosts in batches; `progress` gets 0...1 of this pass; `cancelled` stops it.
    func pass(_ hosts: [UInt32], tail: Int32, progress: (Double) -> Void, cancelled: () -> Bool) {
        var seq: UInt16 = 1
        let batch = 64
        var i = 0
        while i < hosts.count {
            if cancelled() { return }
            for h in hosts[i..<min(hosts.count, i + batch)] {
                if icmp >= 0 {
                    attempts += 1
                    if !Wire.send(icmp, Wire.echoRequest(seq: seq), to: h, port: 0) { failures += 1 }
                    seq &+= 1
                }
                if udp >= 0 { _ = Wire.send(udp, Wire.nbstat, to: h, port: 137) }
            }
            drain(ms: 60)
            i += batch
            progress(Double(min(i, hosts.count)) / Double(max(1, hosts.count)) * 0.8)
        }
        drain(ms: tail)
        progress(1)
    }
}
}
