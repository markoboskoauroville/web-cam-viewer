// SonyDemo.swift (v21): a pretend α7 V that answers the PTP operations SonyLink sends (OpenSession, SDIO_Connect,
// SDIO_GetExtDeviceInfo, GetAllExtDevicePropInfo, SetExtDevicePropValue, ControlDevice) from memory, written in the real
// dataset format and read back by the real parser. It lets the overlay be opened, screenshot-checked and tested with no
// camera (`--sony-demo`, or Option-click on the SONY key). Its values are invented to look like a body in movie mode;
// its Picture Profile slots follow Sony's usual factory set (PP8 = S-Log3 / S-Gamut3.Cine) only so the demo has one: the
// real camera's slots are always read from the camera.
import Foundation

final class SonyDemo: SonyTransport {
    private var props: [UInt16: SonyProp] = [:]
    private let lock = NSLock()
    private let ppTable: [UInt64: (UInt64, UInt64)] = [
        1: (0x0001, 0x0001), 2: (0x0002, 0x0002), 3: (0x0201, 0x0005), 4: (0x0201, 0x0006), 5: (0x0101, 0x0004),
        6: (0x0102, 0x0004), 7: (0x0302, 0x000C), 8: (0x0303, 0x0008), 9: (0x0303, 0x0009), 10: (0x0403, 0x000A),
        11: (0x0003, 0x0003)]

    init() {
        func add(_ code: UInt16, _ type: UInt16, set: Bool = true, en: UInt8 = 1, _ cur: UInt64, _ list: [UInt64] = [],
                 range: (UInt64, UInt64, UInt64)? = nil) {
            let n = SonyProp.size(type) ?? 1
            var w = SonyWriter(); w.uint(cur, bytes: n)
            var p = SonyProp(code: code, type: type, getSet: set ? 1 : 0, enabled: en, factory: w.data, current: w.data)
            if let r = range { p.form = 1; p.rangeMin = r.0; p.rangeMax = r.1; p.rangeStep = r.2 }
            else if !list.isEmpty { p.form = 2; p.setList = list; p.allList = list }
            props[code] = p
        }
        func ev(_ thirds: Int) -> UInt64 {
            let sign = thirds < 0 ? -1 : 1, a = abs(thirds)
            let v = sign * ((a / 3) * 1000 + [0, 300, 700][a % 3])
            return UInt64(UInt16(bitPattern: Int16(v)))
        }
        let fr: [UInt64] = [140, 160, 180, 200, 220, 250, 280, 320, 350, 400, 450, 500, 560, 630, 710, 800, 900, 1000, 1100, 1300, 1400, 1600, 1800, 2000, 2200]
        let dens: [UInt64] = [8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800, 640, 500, 400, 320, 250, 200, 160,
                              125, 100, 80, 60, 50, 40, 30, 25, 20, 15, 13, 10, 8, 6, 5, 4, 3]
        let longs: [UInt64] = [4, 5, 6, 8, 10, 13, 16, 20, 25, 30, 40, 50, 60, 80, 100, 130, 150, 200, 250, 300]
        let shutters = dens.map { (1 << 16) | $0 } + longs.map { ($0 << 16) | 10 }
        let isos: [UInt64] = [0xFF_FFFF, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200,
                              4000, 5000, 6400, 8000, 10000, 12800, 16000, 20000, 25600, 32000, 40000, 51200]
        add(0xD25A, 0x0002, 0, [0, 1])                                       // Position Key: camera dial first
        add(0x500E, 0x0006, en: 0, 1, [1, 0x10002, 0x20003, 0x30004])         // exposure program: greyed until PC Remote priority
        add(0x5007, 0x0004, 400, fr)
        add(0xD20D, 0x0006, (1 << 16) | 50, shutters)
        add(0xD21E, 0x0006, 800, isos)
        add(0x5010, 0x0003, ev(0), (-15...15).map(ev))
        add(0x5005, 0x0004, 2, [2, 4, 0x8011, 0x8010, 6, 0x8001, 0x8002, 0x8003, 0x8004, 7, 0x8030, 0x8012, 0x8020, 0x8021, 0x8022])
        add(0xD20F, 0x0004, en: 0, 5500, range: (2500, 9900, 100))           // Kelvin: only with WB C.Temp.
        add(0xD201, 0x0002, 1, [1, 0x1F, 0x11, 0x12, 0x13, 0x14, 0x15])
        add(0x500B, 0x0004, 0x8001, [0x8001, 0x8002, 0x8003, 0x8004, 0x8005, 0x8006])
        add(0x500A, 0x0004, 0x8004, [2, 0x8004, 0x8005, 0x8006, 1])
        add(0xD22C, 0x0004, 1, [1, 2, 3, 0x0101, 0x0102, 0x0103, 0x0104])
        add(0xD253, 0x0002, 2, [1, 2, 3, 4, 5])
        add(0xD203, 0x0002, 1, [1, 2, 3])
        add(0xD288, 0x0002, 2, [1, 2, 3, 4, 5])
        add(0xD287, 0x0002, 1, [1, 2, 3])
        add(0xD23F, 0x0002, 1, [0] + (1...11).map { UInt64($0) })
        add(0xD0E1, 0x0004, 0x0001, [0x0001, 0x0002, 0x0003, 0x0101, 0x0102, 0x0103, 0x0104, 0x0201, 0x0202, 0x0302, 0x0303, 0x0403])
        add(0xD0E9, 0x0004, 0x0001, (1...12).map { UInt64($0) })
        add(0xD0FA, 0x0004, 1, (1...12).map { UInt64($0) })
        add(0xD0DA, 0x0002, 3, [1, 3])
        add(0xD0DB, 0x0002, 1, [1, 2])
        add(0xD0DF, 0x0002, 1, [1, 2, 3])
        add(0xD21D, 0x0002, set: false, 0, range: (0, 3, 1))
        add(0xD217, 0x0002, set: false, 1, [1, 2])
        add(0xD21F, 0x0002, set: false, 1, [1, 2])
        add(0xD24E, 0x0004, set: false, 1, [1, 2])
        add(0xD218, 0x0001, set: false, 72, range: (0, 100, 1))
        add(0xD24A, 0x0006, set: false, 7840, range: (0, 0xFFFF_FFFF, 1))
    }

    private func put(_ code: UInt16, _ v: UInt64) {
        guard var p = props[code], let d = p.encode(v) else { return }
        p.current = d; props[code] = p
    }
    private func enable(_ code: UInt16, _ on: Bool) { props[code]?.enabled = on ? 1 : 0 }

    func tx(_ op: UInt16, _ params: [UInt32], out: Data?, timeout: Double) throws -> SonyReply {
        lock.lock(); defer { lock.unlock() }
        usleep(15_000)                                                       // a little like Wi-Fi
        switch op {
        case 0x9202: var w = SonyWriter(); w.u16(0x012C); return SonyReply(code: 0x2001, data: w.data, params: [])
        case 0x9209: return SonyReply(code: 0x2001, data: SonyProps.encode(props.values.sorted { $0.code < $1.code }), params: [])
        case 0x9205:
            guard let c = params.first.map({ UInt16(truncatingIfNeeded: $0) }), let p = props[c], let d = out else {
                return SonyReply(code: 0x2006, data: Data(), params: [])
            }
            let v = SonyProp.raw(d)
            guard p.settable, p.form != 2 || p.options.contains(v),
                  p.form != 1 || (v >= p.rangeMin && v <= p.rangeMax) else { return SonyReply(code: 0x2001, data: Data(), params: []) }  // Sony: OK, value kept
            put(c, v)
            if c == 0xD23F, let t = ppTable[v] { put(0xD0E1, t.0); put(0xD0E9, t.1) }
            if c == 0xD25A { enable(0x500E, v == 1) }
            if c == 0x5005 { enable(0xD20F, v == 0x8012) }
            return SonyReply(code: 0x2001, data: Data(), params: [])
        case 0x9207:
            let c = params.first.map { UInt16(truncatingIfNeeded: $0) } ?? 0
            let down = out.map { SonyProp.raw($0) == 2 } ?? false
            if down {
                switch c {
                case 0xD2C8, 0xF001: put(0xD21D, props[0xD21D]?.value == 1 ? 0 : 1)
                case 0xD2C3: put(0xD217, props[0xD217]?.value == 2 ? 1 : 2)
                case 0xD2C9: put(0xD21F, props[0xD21F]?.value == 2 ? 1 : 2)
                case 0xD2D9: put(0xD24E, props[0xD24E]?.value == 2 ? 1 : 2)
                default: break
                }
            }
            return SonyReply(code: 0x2001, data: Data(), params: [])
        default: return SonyReply(code: 0x2001, data: Data(), params: [])
        }
    }
    func close() {}

    /// selftest: the demo's dataset written and parsed again must give back every setting unchanged
    static func roundTrip() -> (Bool, String) {
        let d = SonyDemo()
        let list = d.props.values.sorted { $0.code < $1.code }
        let back = SonyProps.parse(SonyProps.encode(list))
        var bad: [String] = []
        for p in list {
            guard let q = back[p.code] else { bad.append("\(sonyHex(p.code)) missing"); continue }
            if q.value != p.value || q.type != p.type || q.getSet != p.getSet || q.enabled != p.enabled || q.form != p.form
                || q.setList != p.setList || q.allList != p.allList || q.rangeMin != p.rangeMin || q.rangeMax != p.rangeMax {
                bad.append("\(sonyHex(p.code)) differs")
            }
        }
        let labels = [SonyLabels.label(0x5007, 400), SonyLabels.label(0xD20D, (1 << 16) | 50), SonyLabels.label(0xD20D, (25 << 16) | 10),
                      SonyLabels.label(0xD21E, 0xFF_FFFF), SonyLabels.label(0x5010, UInt64(UInt16(bitPattern: -700))),
                      SonyLabels.label(0x5005, 0x8012), SonyLabels.label(0xD0E1, 0x0303), SonyLabels.label(0xD0E9, 0x0008)]
        let want = ["F4", "1/50", "2.5\"", "ISO AUTO", "−0.7 EV", "C.Temp.", "S-Log3", "S-Gamut3.Cine"]
        if labels != want { bad.append("labels \(labels) ≠ \(want)") }
        return (bad.isEmpty, "Sony dataset round trip: \(list.count) settings, \(back.count) parsed, catalogue \(SonyLabels.entries.count) names; "
                + (bad.isEmpty ? "OK" : "FAILED " + bad.joined(separator: ", ")))
    }
}
