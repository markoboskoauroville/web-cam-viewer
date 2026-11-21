// SonyLink.swift (v21): the Sony α7 V (ILCE-7M5) as a remote-controlled camera inside the Webcam Recorder. Marko,
// 21.11.2026: "I need to have button Sony control, and all its icons and pop up menus you overlay over my image ... and I can
// change all the settings inside my own window, not digging through the sub menus." Our own Camera Control PTP 3 code
// (from SONY_REMOTE_MAC): find (SSDP on every LAN interface, then the saved address), SSH tunnel when the camera asks for
// Access Authentication, PTP-IP, OpenSession, SDIO_Connect 1 and 2, SDIO_GetExtDeviceInfo 0x012C, SDIO_Connect 3, then
// GetAllExtDevicePropInfo (0x9209) every half second. A setting is changed with SDIO_SetExtDevicePropValue (0x9205, Sony's
// "Set Camera Setting Sequence") and read back; a button (AEL, FEL, AWBL, movie REC) is SDIO_ControlDevice (0x9207) Down
// then Up. The picture itself stays the HDMI capture: no live view is fetched over Wi-Fi.
// The demo camera (SonyDemo) answers the same operations from memory, so the overlay can be seen and tested without the body.
import Foundation

protocol SonyTransport: AnyObject {
    func tx(_ op: UInt16, _ params: [UInt32], out: Data?, timeout: Double) throws -> SonyReply
    func close()
}
extension SonyPtpIp: SonyTransport {}

struct SonyFound: Equatable {
    var ip: String
    var location: String
    var model: String
    var name: String
    var ssh: Bool
}

/// what one Picture Profile slot holds, as the camera reported it while that slot was selected
struct SonySlot: Codable, Equatable { var gamma: UInt64; var color: UInt64 }

final class SonyLink {
    enum Phase: String { case idle, searching, notFound, needLogin, connecting, connected, failed }

    // MARK: state, read and changed on the main thread only
    private(set) var phase: Phase = .idle
    private(set) var message = ""
    private(set) var found: SonyFound?
    private(set) var hostKey: SonyHostKey?
    private(set) var props: [UInt16: SonyProp] = [:]
    private(set) var demo = false
    private(set) var busy: String?               // "reading the Picture Profile slots…" while a scan runs
    private(set) var slots: [UInt64: SonySlot] = [:]
    private(set) var log: [String] = []
    var onChange: (() -> Void)?
    var connected: Bool { phase == .connected }

    var savedAddress: String {
        get { UserDefaults.standard.string(forKey: "sony.ip") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "sony.ip") }
    }
    var user: String {
        get { UserDefaults.standard.string(forKey: "sony.user") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "sony.user") }
    }
    var savedModel: String { UserDefaults.standard.string(forKey: "sony.model") ?? "" }

    // MARK: the work side: one serial queue owns the transport and the raw settings
    private let work = DispatchQueue(label: "webcamrecorder.sony")
    private var link: SonyTransport?
    private let tunnel = SonyTunnel()
    private var raw: [UInt16: SonyProp] = [:]        // work queue
    private var extFlag: UInt32 = 1
    private var polling = false
    private var wantConnected = false
    private var lastSlot: UInt64?
    private var slotSince = Date()

    static let guid: Data = {
        if let d = UserDefaults.standard.data(forKey: "sony.guid"), d.count == 16 { return d }
        var b = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { b[i] = UInt8.random(in: 0...255) }
        let d = Data(b); UserDefaults.standard.set(d, forKey: "sony.guid"); return d
    }()
    static let pairName = "Webcam Recorder Mac"

    private func ui(_ f: @escaping () -> Void) { DispatchQueue.main.async { f(); self.onChange?() } }
    func say(_ m: String) {
        NSLog("[Sony] %@", m)
        DispatchQueue.main.async { self.log.append(m); if self.log.count > 200 { self.log.removeFirst(50) }; self.onChange?() }
    }
    private func set(_ p: Phase, _ m: String) { say(m); ui { self.phase = p; self.message = m } }

    // MARK: find
    func findAndConnect() {
        wantConnected = true
        if demo { return }
        work.async { self.findNow(connectAfter: true) }
    }

    private func fetch(_ url: String) -> String? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u); req.timeoutInterval = 3
        let sem = DispatchSemaphore(value: 0)
        var out: String?
        URLSession.shared.dataTask(with: req) { d, _, _ in out = d.map { String(decoding: $0, as: UTF8.self) }; sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 4)
        return out
    }
    private func tag(_ s: String, _ t: String) -> String? {
        guard let a = s.range(of: "<\(t)>"), let b = s.range(of: "</\(t)>", range: a.upperBound..<s.endIndex) else { return nil }
        return String(s[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func describe(_ loc: String) -> SonyFound? {
        guard let dd = fetch(loc), dd.contains("DigitalImaging") || dd.contains("Sony"),
              let url = URL(string: loc), let host = url.host else { return nil }
        let name = tag(dd, "friendlyName") ?? "Sony"
        var model = name, ssh = false
        if let scpd = tag(dd, "SCPDURL"), let desc = fetch(URL(string: scpd, relativeTo: url)?.absoluteString ?? "") {
            model = tag(desc, "X_ModelName") ?? name
            ssh = (tag(desc, "X_SSH_Support") ?? "").lowercased() == "enable"
        }
        return SonyFound(ip: host, location: loc, model: model, name: name, ssh: ssh)
    }

    private func findNow(connectAfter: Bool) {
        if link != nil { return }
        set(.searching, "looking for the Sony on the network…")
        var locs = SonySSDP.search(seconds: 4, log: say)
        if let last = UserDefaults.standard.string(forKey: "sony.location"), !locs.contains(last) { locs.append(last) }
        let addr = savedAddress
        if !addr.isEmpty {
            let l = "http://\(addr):64321/dd.xml"
            if !locs.contains(l) { locs.append(l) }
        }
        for loc in locs {
            guard let f = describe(loc) else { continue }
            remember(f)
            proceed(f, connectAfter: connectAfter); return
        }
        // no description answered: a camera at the typed address may still speak PTP-IP (or SSH) directly
        if !addr.isEmpty {
            if SonyTCP.canConnect(addr, 15740, timeout: 1.5) {
                proceed(SonyFound(ip: addr, location: "", model: savedModel.isEmpty ? "Sony" : savedModel, name: "Sony", ssh: false), connectAfter: connectAfter); return
            }
            if SonyTCP.canConnect(addr, 22, timeout: 1.5) {
                proceed(SonyFound(ip: addr, location: "", model: savedModel.isEmpty ? "Sony" : savedModel, name: "Sony", ssh: true), connectAfter: connectAfter); return
            }
        }
        let ifs = SonySSDP.interfaces()
        let onMantra = ifs.contains { $0.1.hasPrefix("192.168.1.") }
        set(.notFound, (onMantra ? "No Sony answered on the Mantra network." : "This Mac is not on the Mantra router (192.168.1.x) now; the Sony cannot be reached on the Nothing hotspot.")
            + " On the camera: Wi-Fi joined to “mantra” and Remote Shooting On.")
    }

    private func remember(_ f: SonyFound) {
        if !f.location.isEmpty { UserDefaults.standard.set(f.location, forKey: "sony.location") }
        UserDefaults.standard.set(f.ip, forKey: "sony.ip")
        UserDefaults.standard.set(f.model, forKey: "sony.model")
        ui { self.found = f; self.loadSlots(f.model) }
    }

    private func account(_ f: SonyFound) -> String { "\(user)@\(f.name)" }

    private func proceed(_ f: SonyFound, connectAfter: Bool) {
        ui { self.found = f }
        say("found \(f.model) “\(f.name)” at \(f.ip)\(f.ssh ? ", Access Authentication (SSH)" : "")")
        if f.ssh && !SonyTunnel.isKnown(f.ip) {
            let k = SonyTunnel.scan(f.ip)
            ui { self.hostKey = k }
            set(.needLogin, k == nil ? "The camera answers, but its SSH key could not be read." :
                "Compare the fingerprint with the camera's Access Authen. Info, type its user and password.")
            return
        }
        if f.ssh && (user.isEmpty || SonyKeychain.load(account: account(f)) == nil) {
            set(.needLogin, "Type the user and password from the camera's Access Authen. Info."); return
        }
        if connectAfter { connectNow(f) } else { set(.idle, "\(f.model) at \(f.ip)") }
    }

    /// Marko pressed SAME AS CAMERA · CONNECT: the fingerprint matched, the user and password are typed
    func approveAndConnect(user u: String, password pw: String) {
        guard let f = found else { findAndConnect(); return }
        wantConnected = true
        let u = u.trimmingCharacters(in: .whitespaces)
        work.async {
            if f.ssh {
                if let k = self.hostKey { SonyTunnel.approve(k, ip: f.ip); self.ui { self.hostKey = nil } }
                guard !u.isEmpty else { self.set(.needLogin, "Type the user from the camera's Access Authen. Info."); return }
                self.user = u
                if !pw.isEmpty { SonyKeychain.save(account: "\(u)@\(f.name)", password: pw) }
            }
            self.connectNow(f)
        }
    }

    // MARK: connect
    private func connectNow(_ f: SonyFound) {
        if link != nil { return }
        do {
            var host = f.ip, port: UInt16 = 15740
            if f.ssh {
                set(.connecting, "opening the SSH tunnel to \(f.ip)…")
                guard let pw = SonyKeychain.load(account: account(f)) else {
                    set(.needLogin, "Type the user and password from the camera's Access Authen. Info."); return
                }
                port = try tunnel.open(ip: f.ip, user: user, password: pw, log: say)
                host = "127.0.0.1"
            } else { set(.connecting, "connecting to \(f.model) at \(f.ip)… (approve “\(Self.pairName)” on the camera if it asks)") }
            let p = try SonyPtpIp(host: host, port: port, guid: Self.guid, name: Self.pairName)
            say("PTP-IP up, the camera calls itself “\(p.cameraName)”")
            try startSession(p)
            set(.connected, "\(f.model) connected")
        } catch {
            link?.close(); link = nil; tunnel.close()
            set(.failed, "\(error)")
        }
    }

    /// the Sony session on any transport (the camera or the demo)
    private func startSession(_ p: SonyTransport) throws {
        var r = try p.tx(0x1002, [1], out: nil, timeout: 10)                           // OpenSession
        if !r.ok && r.code != 0x201E {
            r = try p.tx(0x9210, [1, 0], out: nil, timeout: 10)                         // SDIO_OpenSession
            if !r.ok && r.code != 0x201E { throw SonyPtpError.refused(r.code, "OpenSession") }
        }
        _ = try p.tx(0x9201, [1, 0, 0], out: nil, timeout: 10)
        _ = try p.tx(0x9201, [2, 0, 0], out: nil, timeout: 10)
        var version: UInt16 = 0
        for _ in 0..<30 {
            let i = try p.tx(0x9202, [0x012C], out: nil, timeout: 10)
            if i.data.count >= 2 { version = UInt16(i.data[i.data.startIndex]) | UInt16(i.data[i.data.startIndex + 1]) << 8; break }
            usleep(100_000)
        }
        say("Sony protocol \(sonyHex(version))\(version == 0x012C ? " (PTP 3)" : "")")
        let c3 = try p.tx(0x9201, [3, 0, 0], out: nil, timeout: 10)
        if !c3.ok { throw SonyPtpError.refused(c3.code, "SDIO_Connect 3") }
        link = p
        extFlag = 1
        try readProps(all: true)
        let n = raw.count, s = raw.values.filter { $0.getSet == 1 }.count
        say("\(n) settings reported, \(s) settable by the Mac")
        startPolling()
    }

    private func readProps(all: Bool) throws {
        guard let p = link else { return }
        var r = try p.tx(0x9209, [all ? 0 : 1, extFlag], out: nil, timeout: 10)
        if !r.ok && extFlag == 1 { extFlag = 0; r = try p.tx(0x9209, [all ? 0 : 1, 0], out: nil, timeout: 10) }
        guard r.ok else { throw SonyPtpError.refused(r.code, "GetAllExtDevicePropInfo") }
        let got = SonyProps.parse(r.data)
        if all { raw = got } else { raw.merge(got) { _, new in new } }
        if all || !got.isEmpty {
            let snapshot = raw
            ui { self.props = snapshot; self.learnSlot() }
        }
    }

    private func startPolling() {
        polling = true
        func tick() {
            work.asyncAfter(deadline: .now() + 0.5) {
                guard self.polling, self.link != nil else { return }
                do { try self.readProps(all: false) } catch { self.lost(error); return }
                tick()
            }
        }
        tick()
    }

    private func lost(_ e: Error) {
        polling = false
        link?.close(); link = nil; tunnel.close()
        set(.failed, "connection lost: \(e)")
        if wantConnected && !demo {
            work.asyncAfter(deadline: .now() + 3) { if self.wantConnected && self.link == nil { self.findNow(connectAfter: true) } }
        }
    }

    func disconnect() {
        wantConnected = false
        work.async {
            self.polling = false
            if let p = self.link { _ = try? p.tx(0x1003, [], out: nil, timeout: 3); p.close() }
            self.link = nil; self.tunnel.close(); self.raw = [:]
            let wasDemo = self.demo
            self.ui { self.props = [:]; self.demo = false }
            self.set(.idle, wasDemo ? "demo camera closed" : "disconnected")
        }
    }

    /// the app quits: the ssh child must not outlive it
    func shutdown() {
        wantConnected = false
        tunnel.close()
    }

    // MARK: the demo camera
    func startDemo() {
        work.async {
            if self.link != nil { return }
            self.ui { self.demo = true; self.found = SonyFound(ip: "demo", location: "", model: "ILCE-7M5 (demo)", name: "demo", ssh: false); self.loadSlots("ILCE-7M5 (demo)") }
            do { try self.startSession(SonyDemo()); self.set(.connected, "DEMO camera: no Sony is touched, every value is simulated") }
            catch { self.set(.failed, "demo: \(error)") }
        }
    }

    // MARK: changing the camera
    /// SDIO_SetExtDevicePropValue, then the camera's own answer is what the overlay shows (read back)
    func setValue(_ code: UInt16, _ v: UInt64, done: ((Bool) -> Void)? = nil) {
        work.async {
            guard let p = self.link, let prop = self.raw[code], let data = prop.encode(v) else {
                self.ui { done?(false) }; return
            }
            do {
                let r = try p.tx(0x9205, [UInt32(code), self.extFlag], out: data, timeout: 10)
                if !r.ok { self.say("\(SonyLabels.name(code)) → \(SonyLabels.label(code, v, type: prop.type)): the camera answered \(sonyHex(r.code))") }
                // the camera may take a moment: read back up to 1.5 s
                var ok = false
                for _ in 0..<6 {
                    try self.readProps(all: false)
                    if self.raw[code]?.value == v { ok = true; break }
                    usleep(250_000)
                }
                if !ok { self.say("\(SonyLabels.name(code)): the camera kept \(SonyLabels.label(code, self.raw[code]?.value ?? 0, type: prop.type))") }
                else { self.say("\(SonyLabels.name(code)) = \(SonyLabels.label(code, v, type: prop.type))") }
                self.ui { done?(ok) }
            } catch { self.lost(error); self.ui { done?(false) } }
        }
    }

    /// a camera button: SDIO_ControlDevice Down, then Up (Sony's "Execute Control" sequence)
    func press(_ code: UInt16, name: String) {
        work.async {
            guard let p = self.link else { return }
            do {
                _ = try p.tx(0x9207, [UInt32(code), self.extFlag], out: self.u16(2), timeout: 10)
                try self.readProps(all: false)
                usleep(120_000)
                _ = try p.tx(0x9207, [UInt32(code), self.extFlag], out: self.u16(1), timeout: 10)
                try self.readProps(all: false)
                self.say("\(name) pressed")
            } catch { self.lost(error) }
        }
    }

    private func u16(_ v: UInt16) -> Data { var w = SonyWriter(); w.u16(v); return w.data }

    var recording: Bool { props[0xD21D]?.value == 1 }

    /// REC start/stop, answered once the camera's Movie Recording State (0xD21D) shows it (same steps as SONY_REMOTE_MAC)
    func toggleRec() {
        let on = !recording
        work.async {
            guard let p = self.link else { return }
            func state() -> Bool? { try? self.readProps(all: false); return self.raw[0xD21D].map { $0.value == 1 } }
            func wait(_ s: Double) -> Bool {
                let end = Date().addingTimeInterval(s)
                while Date() < end { if state() == on { return true }; usleep(250_000) }
                return false
            }
            func press(_ code: UInt32, _ v: UInt16) { _ = try? p.tx(0x9207, [code, self.extFlag], out: self.u16(v), timeout: 10) }
            if state() == on { return }
            press(0xD2C8, on ? 2 : 1)
            if wait(3) { self.say(on ? "● REC started" : "■ REC stopped"); return }
            press(0xD2C8, 2); usleep(150_000); press(0xD2C8, 1)
            if wait(3) { self.say(on ? "● REC started" : "■ REC stopped"); return }
            press(0xF001, 2); usleep(150_000); press(0xF001, 1)
            if wait(3) { self.say(on ? "● REC started" : "■ REC stopped"); return }
            self.set(.connected, "the camera did not \(on ? "start" : "stop") recording: is it in movie mode with a card?")
        }
    }

    // MARK: Picture Profile slots. The gamma (0xD0E1) and color mode (0xD0E9) the camera reports belong to the slot selected
    // in Picture Profile (0xD23F), so a slot is known only after it was selected: learned whenever a slot has been the
    // current one for a second, or by READ SLOTS (each offered slot in turn, then the one before put back). Never guessed.
    private func slotKey(_ model: String) -> String { "sony.slots.\(model)" }
    private func loadSlots(_ model: String) {
        guard let d = UserDefaults.standard.data(forKey: slotKey(model)),
              let m = try? JSONDecoder().decode([String: SonySlot].self, from: d) else { slots = [:]; return }
        var out: [UInt64: SonySlot] = [:]
        for (k, v) in m { if let s = UInt64(k) { out[s] = v } }
        slots = out
    }
    private func saveSlots() {
        guard let model = found?.model else { return }
        var m: [String: SonySlot] = [:]
        for (k, v) in slots { m[String(k)] = v }
        if let d = try? JSONEncoder().encode(m) { UserDefaults.standard.set(d, forKey: slotKey(model)) }
    }
    /// main thread, after each read
    private func learnSlot() {
        guard let pp = props[0xD23F] else { return }
        let s = pp.value
        if s != lastSlot { lastSlot = s; slotSince = Date(); return }
        guard busy == nil, Date().timeIntervalSince(slotSince) >= 1.0, s >= 1, s <= 0x0B,
              let g = props[0xD0E1], let c = props[0xD0E9], g.enabled != 0, c.enabled != 0 else { return }
        let slot = SonySlot(gamma: g.value, color: c.value)
        if slots[s] != slot { slots[s] = slot; saveSlots(); say("\(SonyLabels.ppShort(s)) = \(SonyLabels.gamma(slot.gamma)) / \(SonyLabels.colorMode(slot.color))") }
    }
    /// the slot holding S-Log3 with S-Gamut3.Cine, as the camera reported it
    var slog3Slot: UInt64? {
        slots.filter { $0.value.gamma == 0x0303 && $0.value.color == 0x0008 }.keys.sorted().first
    }

    /// READ SLOTS: select each Picture Profile slot the camera offers, note its gamma and color mode, then put back the one
    /// that was selected. Not while recording.
    func scanSlots() {
        guard connected, busy == nil, let pp = props[0xD23F], pp.settable else { return }
        if recording { say("not while recording"); return }
        busy = "reading the Picture Profile slots…"; onChange?()
        let original = pp.value
        let offered = pp.options.filter { $0 >= 1 && $0 <= 0x0B }
        work.async {
            var learned: [UInt64: SonySlot] = [:]
            defer {
                self.ui {
                    for (k, v) in learned { self.slots[k] = v }
                    self.saveSlots(); self.busy = nil
                    let s = self.slog3Slot
                    self.message = s.map { "S-Log3 / S-Gamut3.Cine is \(SonyLabels.ppShort($0))" } ?? "no slot reports S-Log3 with S-Gamut3.Cine"
                }
            }
            guard let p = self.link else { return }
            func select(_ s: UInt64) throws -> Bool {
                _ = try p.tx(0x9205, [0xD23F, self.extFlag], out: Data([UInt8(s)]), timeout: 10)
                for _ in 0..<10 { try self.readProps(all: false); if self.raw[0xD23F]?.value == s { return true }; usleep(200_000) }
                return false
            }
            do {
                for s in offered {
                    guard try select(s) else { self.say("\(SonyLabels.ppShort(s)): the camera did not select it"); continue }
                    usleep(700_000)                                   // let gamma and color mode follow the slot
                    try self.readProps(all: false)
                    if let g = self.raw[0xD0E1], let c = self.raw[0xD0E9] {
                        learned[s] = SonySlot(gamma: g.value, color: c.value)
                        self.say("\(SonyLabels.ppShort(s)) = \(SonyLabels.gamma(g.value)) / \(SonyLabels.colorMode(c.value))")
                    }
                }
                _ = try select(original)
                self.say("Picture Profile back to \(SonyLabels.ppShort(original))")
            } catch { self.lost(error) }
        }
    }
}
