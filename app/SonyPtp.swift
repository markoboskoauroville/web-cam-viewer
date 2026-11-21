// SonyPtp.swift (v21): PTP over TCP/IP (CIPA DC-005, as named in Sony's Camera Control PTP 3 reference), the camera's
// Access Authentication SSH tunnel and the Keychain for its password. Moved from SONY_REMOTE_MAC (PtpIp.swift, Tunnel.swift;
// our own code, no Sony code). The password reaches /usr/bin/ssh through SSH_ASKPASS = this app itself (App.swift answers
// when started with WCR_SONY_ASKPASS in its environment). Host keys live in our own known_hosts, written only after Marko
// pressed SAME AS CAMERA · CONNECT, having compared the fingerprint with the camera's Access Authen. Info screen.
import Foundation
import Security

struct SonyReply {
    let code: UInt16
    let data: Data
    let params: [UInt32]
    var ok: Bool { code == 0x2001 }
}

enum SonyPtpError: Error, CustomStringConvertible {
    case initFail(UInt32), unexpected(String), refused(UInt16, String)
    var description: String {
        switch self {
        case .initFail(let r):
            return r == 0x2019 || r == 0x201E ? "the camera is busy (Imaging Edge or a phone connected to it?)"
                : "the camera refused the connection (reason \(String(format: "0x%08X", r))): approve it on the camera"
        case .unexpected(let m): return m
        case .refused(let c, let op): return "\(op) answered \(sonyHex(c))"
        }
    }
}

final class SonyPtpIp {
    private let cmd: SonyTCP
    private var evt: SonyTCP?
    private var tid: UInt32 = 0
    private let lock = NSLock()
    private(set) var cameraName = ""

    init(host: String, port: UInt16, guid: Data, name: String, pairingWait: Double = 90) throws {
        cmd = try SonyTCP(host: host, port: port)
        var w = SonyWriter()
        w.bytes(guid); w.utf16z(name); w.u32(0x0001_0000)
        try SonyPtpIp.packet(cmd, type: 1, w.data)
        cmd.setReadTimeout(pairingWait)
        let (t, body) = try SonyPtpIp.readPacket(cmd)
        cmd.setReadTimeout(10)
        if t == 5 { var r = SonyReader(body); throw SonyPtpError.initFail((try? r.u32()) ?? 0) }
        guard t == 2 else { throw SonyPtpError.unexpected("expected InitCommandAck, got packet \(t)") }
        var r = SonyReader(body)
        let conn = try r.u32()
        _ = try r.take(16)
        cameraName = (try? r.utf16z()) ?? ""
        let e = try SonyTCP(host: host, port: port)
        var we = SonyWriter(); we.u32(conn)
        try SonyPtpIp.packet(e, type: 3, we.data)
        let (et, _) = try SonyPtpIp.readPacket(e)
        if et == 5 { throw SonyPtpError.initFail(0) }
        guard et == 4 else { throw SonyPtpError.unexpected("expected InitEventAck, got packet \(et)") }
        evt = e
        Thread.detachNewThread { SonyPtpIp.eventLoop(e) }
    }

    func close() { cmd.close(); evt?.close(); evt = nil }

    /// events are not used (Sony: poll the properties); the channel is read so it never fills, and probes are answered
    private static func eventLoop(_ e: SonyTCP) {
        e.setReadTimeout(3600)
        while e.fd >= 0 {
            do {
                let (t, _) = try readPacket(e)
                if t == 13 { try? packet(e, type: 14, Data()) }
            } catch {
                if case SonyNetError.timeout = error, e.fd >= 0 { continue }
                return
            }
        }
    }

    /// One operation. `out` is sent in a data phase (Initiator → camera).
    func tx(_ op: UInt16, _ params: [UInt32] = [], out: Data? = nil, timeout: Double = 10) throws -> SonyReply {
        lock.lock(); defer { lock.unlock() }
        tid &+= 1
        let id = tid
        var w = SonyWriter()
        w.u32(out == nil ? 1 : 2); w.u16(op); w.u32(id)
        for p in params { w.u32(p) }
        try SonyPtpIp.packet(cmd, type: 6, w.data)
        if let d = out {
            var s = SonyWriter(); s.u32(id); s.u64(UInt64(d.count))
            try SonyPtpIp.packet(cmd, type: 9, s.data)
            var e = SonyWriter(); e.u32(id); e.bytes(d)
            try SonyPtpIp.packet(cmd, type: 12, e.data)
        }
        cmd.setReadTimeout(timeout)
        var data = Data()
        while true {
            let (t, body) = try SonyPtpIp.readPacket(cmd)
            switch t {
            case 9: break
            case 10, 12: if body.count > 4 { data.append(body.subdata(in: 4..<body.count)) }
            case 7:
                var r = SonyReader(body)
                let code = try r.u16()
                _ = try r.u32()
                var ps: [UInt32] = []
                while r.left >= 4 { ps.append(try r.u32()) }
                return SonyReply(code: code, data: data, params: ps)
            case 13: try SonyPtpIp.packet(cmd, type: 14, Data())
            default: break
            }
        }
    }

    static func packet(_ c: SonyTCP, type: UInt32, _ payload: Data) throws {
        var w = SonyWriter(); w.u32(UInt32(payload.count + 8)); w.u32(type); w.bytes(payload)
        try c.send(w.data)
    }

    static func readPacket(_ c: SonyTCP) throws -> (UInt32, Data) {
        let head = try c.read(8)
        var r = SonyReader(head)
        let len = try r.u32(), type = try r.u32()
        guard len >= 8, len < 64 * 1024 * 1024 else { throw SonyPtpError.unexpected("broken packet length \(len)") }
        let body = len > 8 ? try c.read(Int(len) - 8) : Data()
        return (type, body)
    }
}

// MARK: Access Authentication (SSH)

enum SonyStore {
    static var dir: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(NAME)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var knownHosts: URL { dir.appendingPathComponent("sony_known_hosts") }
}

struct SonyHostKey {
    let lines: String
    let sha256: [String]
}

final class SonyTunnel {
    private var proc: Process?
    private var err = Pipe()

    static func run(_ path: String, _ args: [String], timeout: Double = 10) -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let o = Pipe(); p.standardOutput = o; p.standardError = o
        do { try p.run() } catch { return (-1, "\(error)") }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }
        let out = String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, out)
    }

    static func scan(_ ip: String) -> SonyHostKey? {
        let (_, out) = run("/usr/bin/ssh-keyscan", ["-T", "6", "-p", "22", ip], timeout: 12)
        let lines = out.split(separator: "\n").filter { !$0.hasPrefix("#") && $0.contains(" ") }.joined(separator: "\n")
        guard !lines.isEmpty else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wcr-sony-keys-\(getpid())")
        try? (lines + "\n").write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fp = run("/usr/bin/ssh-keygen", ["-l", "-E", "sha256", "-f", tmp.path]).1.split(separator: "\n").map { l -> String in
            let parts = l.split(separator: " ")
            return parts.count >= 2 ? "\(parts[1]) \(parts.last ?? "")" : String(l)
        }
        return SonyHostKey(lines: lines, sha256: fp)
    }

    static func isKnown(_ ip: String) -> Bool {
        guard let s = try? String(contentsOf: SonyStore.knownHosts, encoding: .utf8) else { return false }
        return s.split(separator: "\n").contains { $0.hasPrefix(ip + " ") || $0.hasPrefix("[\(ip)]") }
    }

    static func approve(_ key: SonyHostKey, ip: String) {
        var s = (try? String(contentsOf: SonyStore.knownHosts, encoding: .utf8)) ?? ""
        s = s.split(separator: "\n").filter { !$0.hasPrefix(ip + " ") }.joined(separator: "\n")
        if !s.isEmpty { s += "\n" }
        s += key.lines + "\n"
        try? s.write(to: SonyStore.knownHosts, atomically: true, encoding: .utf8)
    }

    /// `ssh -N -L <free port>:localhost:15740 user@ip`; answers the local port once the forward listens
    func open(ip: String, user: String, password: String, log: (String) -> Void) throws -> UInt16 {
        close()
        let lp = SonyTCP.freePort()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-N", "-c", "aes128-ctr", "-p", "22",
                       "-L", "127.0.0.1:\(lp):localhost:15740",
                       "-o", "UserKnownHostsFile=\(SonyStore.knownHosts.path)", "-o", "StrictHostKeyChecking=yes",
                       "-o", "GlobalKnownHostsFile=/dev/null", "-o", "PubkeyAuthentication=no",
                       "-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "NumberOfPasswordPrompts=1",
                       "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3", "-o", "ExitOnForwardFailure=yes",
                       "-o", "ConnectTimeout=8", "-o", "LogLevel=ERROR", "-F", "/dev/null",
                       "\(user)@\(ip)"]
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = Bundle.main.executablePath ?? CommandLine.arguments[0]
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = env["DISPLAY"] ?? ":0"
        env["WCR_SONY_ASKPASS"] = password
        p.environment = env
        err = Pipe()
        p.standardError = err; p.standardOutput = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        try p.run()
        proc = p
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if !p.isRunning {
                let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                proc = nil
                if msg.contains("Permission denied") { throw SonyNetError.io("the camera refused the user or password (Access Authen. Info)") }
                if msg.contains("Host key verification failed") || msg.contains("REMOTE HOST IDENTIFICATION") {
                    throw SonyNetError.io("the camera's fingerprint is not approved yet")
                }
                throw SonyNetError.io(msg.isEmpty ? "ssh ended (status \(p.terminationStatus))" : "ssh: \(msg)")
            }
            if SonyTCP.canConnect("127.0.0.1", lp) { log("SSH tunnel open on 127.0.0.1:\(lp)"); return lp }
            usleep(200_000)
        }
        close()
        throw SonyNetError.io("the SSH tunnel did not open in 15 s")
    }

    func close() {
        if let p = proc, p.isRunning { p.terminate() }
        proc = nil
    }
    deinit { close() }
}

/// the camera's password, in the login Keychain (never in a file, never in git)
enum SonyKeychain {
    static let service = "Webcam Recorder (Mantra) Sony camera"
    static func save(account: String, password: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q; add[kSecValueData as String] = password.data(using: .utf8)!
        SecItemAdd(add as CFDictionary, nil)
    }
    static func load(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
