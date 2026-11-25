// SonyScan.swift (v39, 25.11.2026): SCAN beside the camera address. Marko: "Upgrade the camera control from the app. It needs
// to have next to the IP address scan. So it finds a camera automatically." Every road is measured on its own line, and an
// open port alone never counts (LESSONS 40: a VPN with a 0/1 route accepts every TCP connect):
//   1 the last good address and the remembered MAC of this body first
//   2 SSDP (UPnP M-SEARCH for Sony's DigitalImaging service, 239.255.255.250:1900) on every LAN interface
//   3 LAN Scanner's sweep (LanSweep.swift: ICMP + NetBIOS to every host, then the kernel's ARP table; only a device on the
//     wire answers ARP, a VPN cannot), then the MAC prefix: Sony's registered OUIs, and Murata's (the α7 V's Wi-Fi module is Murata,
//     80:99:9B, IEEE list 25.11.2026)
//   4 a real PTP/IP handshake on 15740 for every candidate (InitCommandRequest with our GUID and name; a camera answers
//     InitCommandAck with its own name, or InitFail when busy; a proxy answers neither)
//   5 the USB cable (IOKit, nothing opened: the ILCE-7M5 on the cable even while Imaging Edge Remote holds it)
// Runs on its own queue, never on the main thread and never near the recording path.
import Foundation
import Darwin

struct SonyCandidate {
    var address: String              // "192.168.1.103" or "USB"
    var mac: String?                 // "80:99:9b:13:ad:3f"
    var vendor: String?              // "Sony Corporation", "Murata (the α7 V's Wi-Fi module)"
    var remembered = false           // the MAC this body had before
    var lastGood = false             // the address that connected or answered PTP/IP before
    var ping = false
    var ssdp = false
    var model: String?
    var ptp = "not tried"            // the handshake, in words
    var ptpVerified = false          // InitCommandAck or InitFail from a PTP/IP responder
    var note = ""
    var how: [String] = []           // which stages found it

    var isUSB: Bool { address == "USB" }
    var score: Int {
        var s = 0
        if ptpVerified { s += 100 }
        if ssdp { s += 80 }
        if remembered { s += 60 }
        if lastGood { s += 15 }
        if vendor == SonyOUI.sonyName { s += 40 } else if vendor != nil { s += 20 }
        if ping { s += 5 }
        return s
    }
    /// one line for the pop-up and the API
    var title: String {
        if isUSB { return "\(model ?? "Sony") on USB" + (note.isEmpty ? "" : " (\(note))") }
        var t = address
        if let m = model { t += " · \(m)" }
        if ptpVerified { t += " · PTP/IP ✓" }
        else if remembered { t += " · this camera's Wi-Fi" }
        else if let v = vendor { t += " · \(v == SonyOUI.sonyName ? "Sony" : "Murata")" }
        return t
    }
    var json: [String: Any] {
        ["address": address, "mac": orNull(mac), "vendor": orNull(vendor), "remembered": remembered, "lastGood": lastGood,
         "ping": ping, "ssdp": ssdp, "model": orNull(model), "ptp": ptp, "ptpVerified": ptpVerified, "note": note,
         "how": how, "score": score, "title": title, "usb": isUSB]
    }
}

enum SonyOUI {
    static let sonyName = "Sony Corporation"
    static let murataName = "Murata (the α7 V's Wi-Fi module)"
    /// IEEE MA-L registry (oui.txt, 25.11.2026): Sony Corporation, Sony Imaging Products & Solutions, Sony Visual / Video &
    /// Sound / Home Entertainment Products (Sony Interactive Entertainment, the PlayStation, left out)
    static let sony: Set<String> = Set("""
    00014A 000AD9 000E07 000FDE 0012EE 0013A9 001620 0016B8 001813 001963 001A75 001A80 001B59 001CA4 001D28 001DBA 001E45
    001EDC 001FE4 00219E 002298 002345 0023F1 0024BE 0024EF 0025E7 00EB2D 045D4B 080046 104FA8 143FA6 18002D 1C7B21 205476
    2421AB 283F69 2C97ED 3017C8 303926 307512 30A8DB 30F9ED 38184C 387862 3C01EF 3C0771 3C38F4 402BA1 4040A7 40B837 44746C
    44D4E0 4C21D0 50125C 54263D 544249 5453ED 58170C 581862 584822 5CB524 68764F 6C0E0D 6C23B9 6CB227 702605 78843C 8099E7
    8400D2 848EDF 84C7EA 88C9E8 8C6422 90C115 94CE2C 94DB56 9C5CF9 A0E453 AC800A AC9B0A B4527D B4527E B8F934 BC6E64 C43ABE
    CC988B D05162 D4389C D8D43C E063E5 F0BF97 F84E17 FCF152
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
    /// Murata Manufacturing (Sony bodies carry Murata Wi-Fi modules: this α7 V is 80:99:9B:13:AD:3F)
    static let murata: Set<String> = Set("""
    000E6D 0013E0 0021E8 0026E8 00376D 006057 009D6B 00AEFA 044665 04C461 0C802F 10322C 1098C3 10A5D0 147DC5 1848CA 1C7022
    1C994C 2002AF 24CD8D 2C4CC6 2CD1C6 3490EA 40F308 448A7F 449160 44A7CF 48EB62 5026EF 58D50A 5CDAD4 5CF8A1 6021C0 60F189
    707414 7087A7 747A90 784B87 78F505 7CB8DA 80999B 849690 88308A 8C4500 90B686 98F170 9C50D1 A0C9A0 A0CC2B A0CDF3 A408EA
    A437E6 B0653A B072BF B8D7AF C4AC59 C4BEAF CCC079 D00B27 D01769 D040EF D0E44A D44DA4 D45383 D81068 D8C46A DCEFCA DCFE23
    E4ADCA E4CA5F E84F25 E8E8B7 EC5C84 F02765 F03E05 FC84A7 FCC2DE FCDBB3
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    /// "0:1:4a:b:c:d" → "00:01:4a:0b:0c:0d"
    static func normal(_ mac: String) -> String {
        mac.lowercased().split(separator: ":").map { $0.count == 1 ? "0" + $0 : String($0) }.joined(separator: ":")
    }
    static func vendor(_ mac: String?) -> String? {
        guard let m = mac else { return nil }
        let p = normal(m).replacingOccurrences(of: ":", with: "").uppercased().prefix(6)
        if sony.contains(String(p)) { return sonyName }
        if murata.contains(String(p)) { return murataName }
        return nil
    }
}

final class SonyScan {
    enum State: String { case idle, running, done }
    // main thread
    private(set) var state: State = .idle
    private(set) var stage = ""
    private(set) var lines: [String] = []
    private(set) var candidates: [SonyCandidate] = []
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    var onChange: (() -> Void)?

    private let queue = DispatchQueue(label: "webcamrecorder.sony.scan", qos: .utility)

    static let defaultMac = "80:99:9b:13:ad:3f"            // this α7 V, measured 21.11.2026
    static var rememberedMac: String {
        get { UserDefaults.standard.string(forKey: "sony.mac") ?? defaultMac }
        set { UserDefaults.standard.set(SonyOUI.normal(newValue), forKey: "sony.mac") }
    }
    static var lastGood: String {
        get { UserDefaults.standard.string(forKey: "sony.lastGood") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "sony.lastGood") }
    }

    /// the best network camera (fills the address), nil when only the cable or nothing was found
    var best: SonyCandidate? { candidates.first { !$0.isUSB } }
    var usb: SonyCandidate? { candidates.first { $0.isUSB } }

    var json: [String: Any] {
        let f = ISO8601DateFormatter()
        return ["state": state.rawValue, "stage": stage, "lines": lines, "candidates": candidates.map(\.json),
                "address": orNull(best?.address), "usb": orNull(usb?.title),
                "startedAt": orNull(startedAt.map { f.string(from: $0) }), "finishedAt": orNull(finishedAt.map { f.string(from: $0) }),
                "rememberedMac": Self.rememberedMac, "lastGood": Self.lastGood]
    }

    private func post(_ f: @escaping () -> Void) { DispatchQueue.main.async { f(); self.onChange?() } }
    private func line(_ s: String) { NSLog("[Sony scan] %@", s); post { self.lines.append(s); self.stage = s } }

    /// start once; a second press while running does nothing. `skipPTP` = the address held by our own Wi-Fi session now.
    func start(saved: String, skipPTP: String?, done: (() -> Void)? = nil) {
        guard state != .running else { return }
        state = .running; stage = "SCAN: starting…"; lines = []; candidates = []; startedAt = Date(); finishedAt = nil
        onChange?()
        queue.async {
            let found = self.run(saved: saved, skipPTP: skipPTP)
            self.post {
                self.candidates = found
                self.state = .done; self.finishedAt = Date()
                let wifi = found.filter { !$0.isUSB }, cable = found.filter(\.isUSB)
                var s = "SCAN done: "
                if wifi.isEmpty && cable.isEmpty { s += "no Sony found (Wi-Fi off on the camera? cable out?)" }
                else {
                    var parts: [String] = []
                    if let b = wifi.first { parts.append("\(b.address)\(b.ptpVerified ? " (PTP/IP answered)" : " (on the network, remote port closed)")") }
                    if wifi.count > 1 { parts.append("\(wifi.count - 1) more on the network") }
                    if let u = cable.first { parts.append(u.title) }
                    s += parts.joined(separator: " · ")
                }
                self.stage = s; self.lines.append(s)
                done?()
            }
        }
    }

    // MARK: the work, on the scan queue
    private func run(saved: String, skipPTP: String?) -> [SonyCandidate] {
        var byIP: [String: SonyCandidate] = [:]
        let lans = SonySSDP.interfaces().filter { Self.isPrivate($0.1) }
        let myIPs = Set(lans.map { $0.1 } + Lan.Net.activeInterfaces().map(\.ip))
        let lastGood = Self.lastGood, remembered = SonyOUI.normal(Self.rememberedMac)
        func add(_ ip: String, _ how: String, _ f: (inout SonyCandidate) -> Void) {
            var c = byIP[ip] ?? SonyCandidate(address: ip)
            if !c.how.contains(how) { c.how.append(how) }
            f(&c); byIP[ip] = c
        }

        // 1 SSDP, in the background while the sweep runs
        line("1 SSDP: asking 239.255.255.250:1900 for Sony's DigitalImaging service on " +
             (lans.isEmpty ? "no LAN" : lans.map { "\($0.0) \($0.1)" }.joined(separator: ", ")) + "…")
        var locations: [String] = []
        let ssdpDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async { locations = SonySSDP.search(seconds: 3); ssdpDone.signal() }

        // 2 LAN Scanner's sweep (LanSweep.swift, copied from LAN_SCANNER): ICMP echo + NetBIOS to every host of each LAN
        //   (capped to the /22 around the Mac), a second look at the quiet ones, then the kernel's ARP table as the truth
        var table: [String: String] = [:]
        var pinged = Set<String>()
        let nets = Lan.Net.activeInterfaces().filter { Self.isPrivate($0.ip) }
        for net in nets {
            guard let own = Lan.CIDR.parse(net.ip) else { continue }
            var plan = Lan.CIDR.hosts(ip: own, prefix: net.prefix).hosts
            for extra in [lastGood, saved, "192.168.1.100"] {
                if let v = Lan.CIDR.parse(extra), v != own, Lan.CIDR.contains(ip: v, net: own, prefix: net.prefix), !plan.contains(v) { plan.append(v) }
            }
            line("2 LAN sweep: \(net.title) \(net.ip), \(Lan.CIDR.network(ip: own, prefix: net.prefix)), \(plan.count) addresses (ICMP + NetBIOS, then ARP)…")
            let sweep = Lan.Sweep(ifaceIndex: net.index)
            guard sweep.usable else { line("2 LAN sweep: cannot open the network sockets on \(net.iface)"); continue }
            sweep.pass(plan, tail: 1000, progress: { _ in }, cancelled: { false })
            var arp = Lan.ARP.read(net: net)
            let have = Set(arp.compactMap { Lan.CIDR.parse($0.ip) }).union(sweep.pinged)
            let missing = plan.filter { !have.contains($0) }
            if !missing.isEmpty && missing.count < plan.count {
                sweep.pass(missing, tail: 600, progress: { _ in }, cancelled: { false })
                arp = Lan.ARP.read(net: net)
            }
            for e in arp { table[e.ip] = SonyOUI.normal(e.mac) }
            for v in sweep.pinged { pinged.insert(Lan.CIDR.string(v)) }
        }
        if nets.isEmpty { line("2 LAN sweep: this Mac has no local network now") }
        let onWire = table.map { ($0.key, $0.value) }.filter { !myIPs.contains($0.0) }.sorted { $0.0 < $1.0 }
        var sonyish = 0
        for (ip, mac) in onWire {
            let v = SonyOUI.vendor(mac), isRemembered = mac == remembered
            guard v != nil || isRemembered || ip == lastGood || ip == saved else { continue }
            if v != nil || isRemembered { sonyish += 1 }
            add(ip, "ARP") { c in c.mac = mac; c.vendor = v; c.remembered = isRemembered; c.lastGood = ip == lastGood; c.ping = pinged.contains(ip) }
        }
        line("2 LAN sweep: \(onWire.count) devices on the wire (ARP), \(pinged.count) answered ping, \(sonyish) with a Sony or Murata MAC" +
             (onWire.contains { $0.1 == remembered } ? " (this camera's MAC \(remembered.uppercased()) is at \(onWire.first { $0.1 == remembered }!.0))" : ""))
        for ip in [saved, lastGood] where !ip.isEmpty && Self.isIPv4(ip) {
            if let mac = table[ip], SonyOUI.vendor(mac) == nil, mac != remembered {
                line("   \(ip) (the saved address) is MAC \(mac.uppercased()), not a Sony or Murata prefix: another device")
                byIP[ip] = nil
            } else if table[ip] == nil {
                line("   \(ip) (the saved address): no ARP answer, nothing there now")
            }
        }

        _ = ssdpDone.wait(timeout: .now() + 4)
        var sonyLocs = 0
        for loc in locations {
            guard let url = URL(string: loc), let host = url.host, let dd = Self.fetch(loc),
                  dd.contains("DigitalImaging") || dd.lowercased().contains("sony") else { continue }
            sonyLocs += 1
            let model = Self.tag(dd, "modelName") ?? Self.tag(dd, "friendlyName")
            add(host, "SSDP") { c in c.ssdp = true; c.model = c.model ?? model; if c.mac == nil { c.mac = table[host] }; if c.vendor == nil { c.vendor = SonyOUI.vendor(c.mac) } }
        }
        line("1 SSDP: " + (sonyLocs == 0 ? "no Sony answered (\(locations.count) other UPnP answers)" : "\(sonyLocs) Sony answered"))

        // 3 ping and the PTP/IP handshake for every candidate
        let ips = Array(byIP.keys).sorted()
        if ips.isEmpty { line("3 PTP/IP: no candidate on the network to ask") }
        let lock = NSLock(), group = DispatchGroup()
        for ip in ips {
            group.enter()
            let swept = byIP[ip]?.ping == true          // read before any worker writes
            DispatchQueue.global(qos: .utility).async {
                let pong = swept || SonyDiagnosis.ping(ip)
                var ptp = "not tried", ok = false, name: String?
                if ip == skipPTP { ptp = "connected from this app now"; ok = true }
                else { (ptp, ok, name) = Self.ptpProbe(ip) }
                lock.lock()
                if var c = byIP[ip] {
                    c.ping = pong; c.ptp = ptp; c.ptpVerified = ok
                    if let name, !name.isEmpty, c.model == nil { c.model = name }
                    if ok { c.how.append("PTP/IP") }
                    byIP[ip] = c
                }
                lock.unlock()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 12)
        for ip in ips { if let c = byIP[ip] { line("3 \(ip)\(c.mac.map { " (\($0.uppercased()))" } ?? ""): \(c.ping ? "answers ping" : "no ping") · PTP/IP \(c.ptp)") } }

        // 4 the cable
        var out = byIP.values.sorted { ($0.score, $0.address) > ($1.score, $1.address) }
        if let u = SonyUSBPresence.find() {
            var c = SonyCandidate(address: "USB")
            c.model = u.product; c.how = ["USB"]
            c.note = u.heldByOther ? "controlled by \(u.ownerName)" : (u.owner?.contains("\(getpid())") == true ? "this app holds it" : "free")
            c.ptp = "USB PTP"
            line("4 USB: \(u.product) on the cable, \(c.note)")
            out.append(c)
        } else { line("4 USB: no Sony on the cable") }
        if let b = out.first(where: { $0.ptpVerified && !$0.isUSB }) { Self.lastGood = b.address }
        return out
    }

    /// InitCommandRequest on 15740: (words, a PTP/IP responder answered, the name it gave)
    static func ptpProbe(_ ip: String) -> (String, Bool, String?) {
        let t: SonyTCP
        do { t = try SonyTCP(host: ip, port: 15740, connectTimeout: 1.5) } catch { return ("port 15740 closed (remote off or on USB)", false, nil) }
        defer { t.close() }
        do {
            var w = SonyWriter()
            w.bytes(SonyLink.guid); w.utf16z(SonyLink.pairName); w.u32(0x0001_0000)
            try SonyPtpIp.packet(t, type: 1, w.data)
            t.setReadTimeout(3)
            let (type, body) = try SonyPtpIp.readPacket(t)
            var r = SonyReader(body)
            if type == 2 {
                _ = try? r.u32(); _ = try? r.take(16)
                let name = (try? r.utf16z()) ?? ""
                return ("answered InitCommandAck\(name.isEmpty ? "" : " “\(name)”")", true, name)
            }
            if type == 5 {
                let why = (try? r.u32()) ?? 0
                return ("answered InitFail \(String(format: "0x%08X", why)) (busy or not approved): a camera", true, nil)
            }
            return ("answered packet type \(type), not PTP/IP", false, nil)
        } catch SonyNetError.timeout {
            return ("port open, no PTP/IP answer in 3 s (approve “\(SonyLink.pairName)” on the camera?)", false, nil)
        } catch {
            return ("port open but no PTP/IP (\(error)): not the camera", false, nil)
        }
    }

    // MARK: helpers
    static func isIPv4(_ s: String) -> Bool { s.split(separator: ".").count == 4 && s.split(separator: ".").allSatisfy { UInt8($0) != nil } }
    static func isPrivate(_ ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1]))
    }

    static func fetch(_ url: String) -> String? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u); req.timeoutInterval = 2
        let sem = DispatchSemaphore(value: 0)
        var out: String?
        URLSession.shared.dataTask(with: req) { d, _, _ in out = d.map { String(decoding: $0, as: UTF8.self) }; sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 3)
        return out
    }
    static func tag(_ s: String, _ t: String) -> String? {
        guard let a = s.range(of: "<\(t)>"), let b = s.range(of: "</\(t)>", range: a.upperBound..<s.endIndex) else { return nil }
        return String(s[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
