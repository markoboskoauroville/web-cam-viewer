import Foundation
import ImageCaptureCore

// The α7 V spoken to in Sony's Camera Control PTP 3 (Camera Remote Command 2.02.00 reference; page numbers below are
// that PDF's). Camera: MENU → Setup → USB → USB Cnct Mode (PORT1) = Remote Shoot/Trn. (Help Guide p.552).
// USB Streaming cannot be controlled at the same time (Help Guide p.416).
final class SonyCamera {
    struct State {
        var model = "SONY"
        var battery: Int?            // 0xD218, %
        var focus: UInt8 = 0         // 0xD213: 02 / 06 focused
        var fnumber: UInt16?         // 0x5007, /100
        var shutter: UInt32?         // 0xD20D, num<<16 | den
        var iso: UInt32?             // 0xD21E
        var recording = false        // 0xD21D == 1
        var focused: Bool { focus == 0x02 || focus == 0x06 }
    }

    let link = SonyLink()
    private(set) var state = State()
    private(set) var ready = false
    var onChange: ((State) -> Void)?
    var onConnected: ((Bool) -> Void)?
    var log: (String) -> Void = { _ in }
    private var poll: Timer?

    // codes
    static let pFNumber: UInt16 = 0x5007, pShutter: UInt16 = 0xD20D, pFocus: UInt16 = 0xD213, pBattery: UInt16 = 0xD218
    static let pRecState: UInt16 = 0xD21D, pISO: UInt16 = 0xD21E
    static let cS1: UInt16 = 0xD2C1, cMovieRec: UInt16 = 0xD2C8, cRemoteTouch: UInt16 = 0xD2E4
    static let pTCPreset: UInt16 = 0xD0D3, pTCRun: UInt16 = 0xD0D6, pTCMake: UInt16 = 0xD0D7
    static let down: UInt16 = 0x0002, up: UInt16 = 0x0001

    func start() {
        link.log = { [weak self] in self?.log($0) }
        link.onReady = { [weak self] cam in self?.handshake(cam) }
        link.onGone = { [weak self] in
            guard let self else { return }
            self.ready = false; self.poll?.invalidate(); self.poll = nil
            self.onConnected?(false)
        }
        link.onEvent = { [weak self] code, params in
            // SDIE_AFStatus 0xC223, p1 = the focus indication (p.695); any property change: read again
            guard let self else { return }
            if code == 0xC223, let v = params.first { self.state.focus = UInt8(truncatingIfNeeded: v); self.onChange?(self.state) }
            else { self.readAll(changedOnly: true) }
        }
        link.start()
    }

    // MARK: the handshake (pp.43–44, 114–116; TcJamActivity.kt)

    private func handshake(_ cam: ICCameraDevice) {
        state.model = cam.name ?? "SONY"
        link.send(0x1002, [1]) { _, _ in }                       // OpenSession; 0x201E "already open" is fine
        link.send(0x9201, [1, 0, 0])
        link.send(0x9201, [2, 0, 0])
        getExtInfo(tries: 30)
    }

    private func getExtInfo(tries: Int) {
        link.send(0x9202, [0x012C, 1]) { [weak self] data, r in
            guard let self else { return }
            let v = data.count >= 2 ? data.withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian : 0
            if v != 0x012C && tries > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.getExtInfo(tries: tries - 1) }
                return
            }
            self.log(String(format: "ext info 0x%04X (%d bytes), response 0x%04X", v, data.count, r.code))
            self.link.send(0x9201, [3, 0, 0]) { _, _ in
                DispatchQueue.main.async { self.connected() }
            }
        }
    }

    private func connected() {
        ready = true
        onConnected?(true)
        jamTimecode()
        readAll(changedOnly: false)
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.readAll(changedOnly: true) }
    }

    // MARK: reading (0x9209, pp.118–120)

    private func readAll(changedOnly: Bool) {
        guard ready else { return }
        link.send(0x9209, [changedOnly ? 1 : 0, 1]) { [weak self] data, r in
            guard let self, r.ok else { return }
            let props = Self.parseProps(data)
            DispatchQueue.main.async {
                var s = self.state
                if let v = props[Self.pBattery] { s.battery = v == 0xFF ? nil : Int(Int8(truncatingIfNeeded: v)) }
                if let v = props[Self.pFocus] { s.focus = UInt8(truncatingIfNeeded: v) }
                if let v = props[Self.pFNumber] { s.fnumber = UInt16(truncatingIfNeeded: v) }
                if let v = props[Self.pShutter] { s.shutter = UInt32(truncatingIfNeeded: v) }
                if let v = props[Self.pISO] { s.iso = UInt32(truncatingIfNeeded: v) }
                if let v = props[Self.pRecState] { s.recording = v == 1 }
                self.state = s
                self.onChange?(s)
            }
        }
    }

    /// code → current value of every dataset with a plain integer type
    static func parseProps(_ d: Data) -> [UInt16: UInt64] {
        var out: [UInt16: UInt64] = [:]
        let b = [UInt8](d)
        var o = 0
        func u(_ n: Int) -> UInt64? {
            guard o + n <= b.count else { return nil }
            var v: UInt64 = 0
            for i in 0..<min(n, 8) { v |= UInt64(b[o + i]) << (8 * UInt64(i)) }
            o += n; return v
        }
        func size(_ t: UInt16) -> Int? {
            switch t { case 1, 2: return 1; case 3, 4: return 2; case 5, 6: return 4; case 7, 8: return 8; case 9, 10: return 16; default: return nil }
        }
        // skip one value of type t (arrays and strings too); returns the value for plain types
        func value(_ t: UInt16) -> UInt64?? {
            if let n = size(t) { return .some(u(n)) }
            if t == 0xFFFF { guard let len = u(1) else { return nil }; o += Int(len) * 2; return .some(nil) }
            if t & 0x4000 != 0, let n = size(t & 0x0FFF) { guard let c = u(4) else { return nil }; o += Int(c) * n; return .some(nil) }
            return nil
        }
        guard let count = u(8) else { return out }
        for _ in 0..<count {
            guard let code = u(2), let type = u(2), u(1) != nil, u(1) != nil else { break }
            let t = UInt16(type)
            guard value(t) != nil, let cur = value(t), let flag = u(1) else { break }
            if let c = cur { out[UInt16(code)] = c }
            if flag == 1 { for _ in 0..<3 { guard value(t) != nil else { return out } } }
            else if flag == 2 {
                for _ in 0..<2 {
                    guard let n = u(2) else { return out }
                    for _ in 0..<n { guard value(t) != nil else { return out } }
                }
            }
        }
        return out
    }

    // MARK: controls (0x9207, pp.117–118); the camera answers OK even when nothing happened, so the state is read back

    private func control(_ code: UInt16, u16 v: UInt16, done: (() -> Void)? = nil) {
        var x = v.littleEndian
        link.send(0x9207, [UInt32(code), 1], out: Data(bytes: &x, count: 2)) { _, _ in done?() }
    }
    private func control(_ code: UInt16, u32 v: UInt32) {
        var x = v.littleEndian
        link.send(0x9207, [UInt32(code), 1], out: Data(bytes: &x, count: 4))
    }

    /// REC: the movie button pressed and released (0xD2C8 "Hold", p.647); 0xD21D tells what it did
    func toggleRecord() {
        guard ready else { return }
        control(Self.cMovieRec, u16: Self.down)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.control(Self.cMovieRec, u16: Self.up) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.readAll(changedOnly: false) } }
        }
    }

    /// AF: half-press held until the camera reports focus (green), at most 3 s, then released
    func focus() {
        guard ready else { return }
        control(Self.cS1, u16: Self.down)
        let start = Date()
        func check() {
            readAll(changedOnly: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if self.state.focused || Date().timeIntervalSince(start) > 3 { self.control(Self.cS1, u16: Self.up) }
                else { check() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { check() }
    }

    /// a click on the picture as a touch on the camera's screen: x 0…639, y 0…479 (0xD2E4, pp.498–499)
    func touch(nx: Double, ny: Double) {
        guard ready else { return }
        let x = UInt32(max(0, min(639, (nx * 640).rounded(.down)))), y = UInt32(max(0, min(479, (ny * 480).rounded(.down))))
        control(Self.cRemoteTouch, u32: x << 16 | y)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.readAll(changedOnly: false) }
    }

    // MARK: the time code jammed to the Mac clock on every connect (Marko, 1.11.2026), as TC Jam does
    // (TcJamActivity.kt:682–698): Run = Free Run, Make = Preset, then the preset h<<24|m<<16|s<<8|f sent at the next
    // whole second (less 3 ms) carrying that second, f = 0.

    private func setProp(_ code: UInt16, _ bytes: Data) { link.send(0x9205, [UInt32(code)], out: bytes) }

    func jamTimecode() {
        setProp(Self.pTCRun, Data([0x02]))
        setProp(Self.pTCMake, Data([0x01]))
        let now = Date()
        let next = (now.timeIntervalSince1970 + 1).rounded(.down) + (now.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) > 0.7 ? 1 : 0)
        let when = Date(timeIntervalSince1970: next)
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: when)
        var v = (UInt32(c.hour!) << 24 | UInt32(c.minute!) << 16 | UInt32(c.second!) << 8).littleEndian
        let data = Data(bytes: &v, count: 4)
        let delay = max(0, when.timeIntervalSinceNow - 0.003)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.setProp(Self.pTCPreset, data)
            self.log(String(format: "time code jammed to %02d:%02d:%02d:00", c.hour!, c.minute!, c.second!))
        }
    }

    // MARK: words for the bar

    static func fText(_ v: UInt16?) -> String {
        guard let v, v < 0xFFFD else { return "F—" }
        let f = Double(v) / 100
        return f >= 10 ? String(format: "F%.0f", f) : String(format: "F%.1f", f)
    }
    static func shutterText(_ v: UInt32?) -> String {
        guard let v, v != 0xFFFF_FFFF else { return "—" }
        if v == 0 { return "BULB" }
        let num = v >> 16, den = v & 0xFFFF
        guard den > 0 else { return "—" }
        if num == 1 && den > 1 { return "1/\(den)" }
        let s = Double(num) / Double(den)
        return s == s.rounded() ? "\(Int(s))\"" : String(format: "%.1f\"", s)
    }
    static func isoText(_ v: UInt32?) -> String {
        guard let v else { return "ISO —" }
        if v & 0x00FF_FFFF == 0x00FF_FFFF { return "ISO AUTO" }
        return "ISO \(v & 0x00FF_FFFF)"
    }
}
