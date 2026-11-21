// SonyProps.swift (v21): the camera's settings as it reports them in SDIO_GetAllExtDevicePropInfo (0x9209): a UINT64
// count, then per setting: code, datatype, GetSet (1 = the Mac may set it), IsEnabled (0 greyed, 1 valid, 2 display only),
// factory default, current value, form (0 none, 1 range min/max/step, 2 enumeration: the "Set" list, then the "Get/Set"
// list). Unlike SONY_REMOTE_MAC's reader this keeps everything, because the overlay shows every setting the camera offers.
// The labels come from SonyCatalog (names) and a few number formats (F-number, shutter, ISO, EV, Kelvin).
import Foundation

struct SonyProp {
    var code: UInt16
    var type: UInt16
    var getSet: UInt8
    var enabled: UInt8
    var factory = Data()
    var current = Data()
    var form: UInt8 = 0
    var rangeMin: UInt64 = 0, rangeMax: UInt64 = 0, rangeStep: UInt64 = 0
    var setList: [UInt64] = []
    var allList: [UInt64] = []

    /// the current value as a raw unsigned number (integer types)
    var value: UInt64 { SonyProp.raw(current) }
    var signedValue: Int64 { SonyProp.signed(value, type) }
    var string: String? {
        guard type == 0xFFFF, current.count >= 1 else { return nil }
        var r = SonyReader(current); let n = Int((try? r.u8()) ?? 0)
        var u: [UInt16] = []
        for _ in 0..<n { if let c = try? r.u16(), c != 0 { u.append(c) } }
        return String(decoding: u, as: UTF16.self)
    }
    /// the Mac may change it now (GetSet and IsEnabled both say so)
    var settable: Bool { getSet == 1 && enabled == 1 && SonyProp.size(type) != nil }
    /// what the pop-up offers: the camera's "Set" list, else its "Get/Set" list
    var options: [UInt64] { setList.isEmpty ? allList : setList }

    static func size(_ type: UInt16) -> Int? {
        switch type {
        case 0x0001, 0x0002: return 1
        case 0x0003, 0x0004: return 2
        case 0x0005, 0x0006: return 4
        case 0x0007, 0x0008: return 8
        default: return nil
        }
    }
    static func raw(_ d: Data) -> UInt64 {
        var v: UInt64 = 0
        for (i, b) in d.prefix(8).enumerated() { v |= UInt64(b) << (8 * UInt64(i)) }
        return v
    }
    static func signed(_ v: UInt64, _ type: UInt16) -> Int64 {
        switch type {
        case 0x0001: return Int64(Int8(truncatingIfNeeded: v))
        case 0x0003: return Int64(Int16(truncatingIfNeeded: v))
        case 0x0005: return Int64(Int32(truncatingIfNeeded: v))
        case 0x0007: return Int64(bitPattern: v)
        default: return Int64(bitPattern: v)
        }
    }
    var isSigned: Bool { [0x0001, 0x0003, 0x0005, 0x0007].contains(type) }
    func encode(_ v: UInt64) -> Data? {
        guard let n = SonyProp.size(type) else { return nil }
        var w = SonyWriter(); w.uint(v, bytes: n); return w.data
    }
}

enum SonyProps {
    static func readValue(_ r: inout SonyReader, _ type: UInt16) throws -> Data {
        let start = r.at
        if let n = SonyProp.size(type) { try r.skip(n) }
        else {
            switch type {
            case 0x0009, 0x000A: try r.skip(16)
            case 0x4001...0x400A:
                let n = Int(try r.u32())
                let each: Int = [0x4001: 1, 0x4002: 1, 0x4003: 2, 0x4004: 2, 0x4005: 4, 0x4006: 4,
                                 0x4007: 8, 0x4008: 8, 0x4009: 16, 0x400A: 16][Int(type)] ?? 1
                try r.skip(n * each)
            case 0xFFFF: let n = Int(try r.u8()); try r.skip(n * 2)
            default: throw SonyReader.Short.end
            }
        }
        return r.data.subdata(in: start..<r.at)
    }

    static func parse(_ d: Data) -> [UInt16: SonyProp] {
        var out: [UInt16: SonyProp] = [:]
        var r = SonyReader(d)
        guard let count = try? r.u64(), count < 5000 else { return out }
        for _ in 0..<count {
            do {
                let code = try r.u16(), type = try r.u16()
                let gs = try r.u8(), en = try r.u8()
                var p = SonyProp(code: code, type: type, getSet: gs, enabled: en)
                p.factory = try readValue(&r, type)
                p.current = try readValue(&r, type)
                p.form = try r.u8()
                if p.form == 1 {
                    p.rangeMin = SonyProp.raw(try readValue(&r, type))
                    p.rangeMax = SonyProp.raw(try readValue(&r, type))
                    p.rangeStep = SonyProp.raw(try readValue(&r, type))
                } else if p.form == 2 {
                    for list in 0..<2 {
                        let n = Int(try r.u16())
                        var vals: [UInt64] = []
                        for _ in 0..<n { vals.append(SonyProp.raw(try readValue(&r, type))) }
                        if list == 0 { p.setList = vals } else { p.allList = vals }
                    }
                }
                out[code] = p
            } catch { break }                                   // keep what was read
        }
        return out
    }

    /// the same dataset array, written (the demo camera answers with it, the selftest checks the round trip)
    static func encode(_ props: [SonyProp]) -> Data {
        var w = SonyWriter()
        w.u64(UInt64(props.count))
        for p in props {
            w.u16(p.code); w.u16(p.type); w.u8(p.getSet); w.u8(p.enabled)
            let n = SonyProp.size(p.type) ?? 0
            if n > 0 { w.uint(SonyProp.raw(p.factory), bytes: n); w.uint(p.value, bytes: n) }
            else { w.bytes(p.factory.isEmpty ? Data([0]) : p.factory); w.bytes(p.current.isEmpty ? Data([0]) : p.current) }
            w.u8(p.form)
            if p.form == 1 { for v in [p.rangeMin, p.rangeMax, p.rangeStep] { w.uint(v, bytes: n) } }
            if p.form == 2 {
                for list in [p.setList, p.allList] { w.u16(UInt16(list.count)); for v in list { w.uint(v, bytes: n) } }
            }
        }
        return w.data
    }
}

/// names and value labels
enum SonyLabels {
    struct Entry { let name: String; let settable: Bool; let values: [UInt64: String] }
    static let entries: [UInt16: Entry] = {
        var out: [UInt16: Entry] = [:]
        for line in SonyCatalog.table.split(separator: "\n") {
            let f = line.split(separator: "|", omittingEmptySubsequences: false)
            guard f.count >= 4, let code = UInt16(f[0], radix: 16) else { continue }
            var vals: [UInt64: String] = [:]
            for kv in f[3].split(separator: ";") {
                let p = kv.split(separator: "=", maxSplits: 1)
                if p.count == 2, let v = UInt64(p[0], radix: 16) { vals[v] = String(p[1]).trimmingCharacters(in: .whitespaces) }
            }
            out[code] = Entry(name: String(f[1]), settable: f[2] == "1", values: vals)
        }
        return out
    }()
    /// the order of the codes in the catalogue (a stable order for "every other setting")
    static let order: [UInt16: Int] = {
        var o: [UInt16: Int] = [:]
        for (i, line) in SonyCatalog.table.split(separator: "\n").enumerated() {
            if let c = UInt16(line.prefix(4), radix: 16) { o[c] = i }
        }
        return o
    }()

    static func name(_ code: UInt16) -> String { entries[code]?.name ?? "Setting \(sonyHex(code))" }

    static func trim(_ v: Double) -> String {
        let s = String(format: "%.1f", v)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    /// a value as the camera would show it
    static func label(_ code: UInt16, _ v: UInt64, type: UInt16 = 0) -> String {
        switch code {
        case 0x5007:   // F-number ×100
            if v == 0xFFFD { return "Iris close" }
            if v == 0xFFFE || v == 0xFFFF || v == 0 { return "--" }
            return "F" + trim(Double(v) / 100)
        case 0xD20D:   // shutter: numerator << 16 | denominator
            if v == 0 { return "BULB" }
            if v == 0xFFFF_FFFF { return "--" }
            let num = Double((v >> 16) & 0xFFFF), den = Double(v & 0xFFFF)
            if den == 0 { return "--" }
            if num == 1 && den > 1 { return "1/\(Int(den))" }
            return trim(num / den) + "\""
        case 0xD21E:   // ISO: low 24 bits the number, the top byte the multi-frame NR kind
            let n = v & 0xFF_FFFF, kind = (v >> 24) & 0xFF
            let pre = kind == 1 ? "MFNR " : kind == 2 ? "MFNR High " : ""
            return pre + (n == 0xFF_FFFF ? "ISO AUTO" : "ISO \(n)")
        case 0x5010:   // exposure compensation ×1000
            let e = Double(Int16(truncatingIfNeeded: v)) / 1000
            return (e > 0 ? "+" : e < 0 ? "−" : "±") + String(format: "%.1f", abs(e)) + " EV"
        case 0xD20F: return "\(v) K"
        case 0xD218: return "\(Int8(truncatingIfNeeded: v)) %"
        case 0xD24A: return v == 0xFFFF_FFFF ? "--" : String(format: "%d:%02d:%02d", v / 3600, (v / 60) % 60, v % 60)
        case 0xD23F: return ppShort(v)
        default: break
        }
        if let l = entries[code]?.values[v] { return l }
        if type != 0, [0x0001, 0x0003, 0x0005, 0x0007].contains(type) {
            let s = SonyProp.signed(v, type); return s > 0 ? "+\(s)" : "\(s)"
        }
        return v > 0xFFFF ? String(format: "0x%llX", v) : "\(v)"
    }

    /// "PP8", "PP LUT1", "PP off"
    static func ppShort(_ slot: UInt64) -> String {
        if slot == 0 { return "PP off" }
        if slot >= 0x41 && slot <= 0x44 { return "PP LUT\(slot - 0x40)" }
        return "PP\(slot)"
    }
    static func gamma(_ v: UInt64) -> String { entries[0xD0E1]?.values[v] ?? "gamma \(v)" }
    static func colorMode(_ v: UInt64) -> String { entries[0xD0E9]?.values[v] ?? "color \(v)" }
}
