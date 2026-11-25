import Foundation

// v30, 25.11.2026: the A/V sync values (docs/AVSYNC_PLAN.md §2, docs/VIRTUALCAM_PLAN.md §7).
// Marko: "It must be exactly in the same frame, the sound. So when I'm doing my online lessons with drumming, there is no
// shift, and I can use any microphone." The α7 V's own HDMI sound (UGREEN 15389 (A)) is the reference: delay 0.
// Every other sound input is held back by its own number, remembered per Core Audio UID (= AVCaptureDevice.uniqueID):
//   sync.audioDelayMs.<audioUID>   Double, ms, positive = hold this input's sound back (negative = bring it earlier)
//   sync.videoDelayMs.<videoUID>   Double, ms, positive = hold this camera's picture back
// In a take both are one shift of the sound against the picture: audio offset = audioDelay - videoDelay.
enum Sync {
    static let referenceName = "UGREEN 15389"
    static let changed = Notification.Name("SyncValuesChanged")
    static let store = NSString(string: "~/Library/Application Support/Webcam Recorder (Mantra)/avsync.json").expandingTildeInPath

    static func audioKey(_ uid: String) -> String { "sync.audioDelayMs.\(uid)" }
    static func videoKey(_ uid: String) -> String { "sync.videoDelayMs.\(uid)" }

    static func isReference(uid: String, name: String) -> Bool {
        name == referenceName || uid.contains("UGREEN 15389")
    }

    /// the stored value, nil when this input has none yet
    static func storedAudio(_ uid: String) -> Double? {
        UserDefaults.standard.object(forKey: audioKey(uid)).flatMap { ($0 as? NSNumber)?.doubleValue }
    }
    static func audioDelayMs(uid: String, name: String) -> Double {
        storedAudio(uid) ?? 0   // the reference and an input never measured: 0
    }
    static func videoDelayMs(_ uid: String) -> Double {
        UserDefaults.standard.object(forKey: videoKey(uid)).flatMap { ($0 as? NSNumber)?.doubleValue } ?? 0
    }
    static func setAudio(_ uid: String, _ ms: Double) {
        // v36-v37: kept to the nanosecond (a whole number of samples or a fraction of a frame must survive; v30-v35: 0.1 ms)
        UserDefaults.standard.set((max(-1000, min(1000, ms)) * 1_000_000).rounded() / 1_000_000, forKey: audioKey(uid))
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static func setVideo(_ uid: String, _ ms: Double) {
        UserDefaults.standard.set((max(0, min(1000, ms)) * 10).rounded() / 10, forKey: videoKey(uid))
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// measured on the Mac 25.11.2026 (avsync.py, chirps from the ADAM, settled after 200 s): device minus camera sound
    /// -72.48 / -44.15 / -74.55 ms, so these are held back by the opposite. Used only when avsync.json has no value.
    static let measuredByName: [String: Double] = [
        "RØDE NT1 5th Gen": 72.5, "MacBook Pro Microphone": 44.2, "External Microphone": 74.6,
    ]

    /// the measurement record of tools/avsync.py (never in the repository): hold-back = -median_ms
    static func measured(uid: String, name: String) -> (ms: Double, source: String)? {
        if let data = FileManager.default.contents(atPath: store),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let devices = obj["devices"] as? [String: Any],
           let d = (devices[uid] as? [String: Any]) ?? devices.values.compactMap({ $0 as? [String: Any] }).first(where: { ($0["name"] as? String) == name }),
           let median = (d["median_ms"] as? NSNumber)?.doubleValue {
            let when = (d["measured"] as? String).map { " " + $0.prefix(10) } ?? ""
            return ((-median * 10).rounded() / 10, "avsync.json\(when)")
        }
        if let v = measuredByName[name] { return (v, "measured 25.11.2026") }
        return nil
    }

    /// first run (and every new input): a measured value is stored for an input that has no value yet; a value set by
    /// hand always wins (it is never overwritten)
    static func seed(uid: String, name: String) {
        guard storedAudio(uid) == nil, !isReference(uid: uid, name: name), let m = measured(uid: uid, name: name) else { return }
        UserDefaults.standard.set(m.ms, forKey: audioKey(uid))
        NSLog("Webcam Recorder: sync delay of %@ seeded to %.1f ms (%@)", name, m.ms, m.source)
    }

    /// the "+72" on the key: whole milliseconds with the sign
    static func short(_ ms: Double) -> String {
        let r = Int(ms.rounded())
        return r > 0 ? "+\(r)" : "\(r)"
    }
    static func text(_ ms: Double) -> String {
        // v36: three decimals only when the value needs them (2.083 ms = 100 samples at 48 kHz)
        let r1 = (ms * 10).rounded() / 10
        let body = abs(ms - r1) < 0.0005 ? String(format: "%.1f", ms) : String(format: "%.3f", ms)
        return (ms > 0 ? "+" : "") + body + " ms"
    }

    // ------------------------------------------------------------------ v36: units and presets
    // Marko, 25.11.2026: "A small side surgery for the app to add the custom delay for sync. So it can be expressed in frames,
    // milliseconds, and samples. In the same menu, when there are already predefined syncs for my devices. It will be great
    // if you can have also custom one for future." The stored value stays sync.audioDelayMs.<uid> in ms; frames are at the
    // record frame rate, samples at the input's own rate (a sample value is rounded to a whole sample when applied).
    enum Unit: String, CaseIterable { case ms, frames, samples }
    static let unitKey = "sync.unit", presetsKey = "sync.presets"
    static var unit: Unit {
        get { Unit(rawValue: UserDefaults.standard.string(forKey: unitKey) ?? "") ?? .ms }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: unitKey); NotificationCenter.default.post(name: changed, object: nil) }
    }
    static func toUnit(_ ms: Double, _ u: Unit, fps: Double, rate: Double) -> Double {
        switch u { case .ms: return ms; case .frames: return ms * fps / 1000; case .samples: return ms * rate / 1000 }
    }
    static func fromUnit(_ v: Double, _ u: Unit, fps: Double, rate: Double) -> Double {
        switch u {
        case .ms: return v
        case .frames: return fps > 0 ? v / fps * 1000 : v
        case .samples: return rate > 0 ? v.rounded() / rate * 1000 : v
        }
    }
    /// the step keys of each unit
    static func steps(_ u: Unit) -> [Double] {
        switch u { case .ms: return [-1, -0.1, 0.1, 1]; case .frames: return [-1, -0.1, 0.1, 1]; case .samples: return [-10, -1, 1, 10] }
    }
    static func unitText(_ v: Double, _ u: Unit) -> String {
        switch u {
        case .ms: return text(v)
        case .frames: return String(format: v > 0 ? "+%.2f frames" : "%.2f frames", v)
        case .samples: return String(format: v > 0 ? "+%.0f samples" : "%.0f samples", v.rounded())
        }
    }
    /// the field's plain number in a unit
    static func plain(_ v: Double, _ u: Unit) -> String {
        switch u {
        case .ms: let t = text(v); return t.replacingOccurrences(of: " ms", with: "")
        case .frames: return String(format: v > 0 ? "+%.2f" : "%.2f", v)
        case .samples: return String(format: v > 0 ? "+%.0f" : "%.0f", v.rounded())
        }
    }
    /// "+72.5 ms = 2.18 frames at 30 fps = 3480 samples at 48 kHz"
    static func threeUnits(_ ms: Double, fps: Double, rate: Double) -> String {
        let f = toUnit(ms, .frames, fps: fps, rate: rate), n = toUnit(ms, .samples, fps: fps, rate: rate)
        let khz = rate.truncatingRemainder(dividingBy: 1000) == 0 ? String(format: "%.0f", rate / 1000) : String(format: "%.1f", rate / 1000)
        return "\(text(ms)) = \(unitText(f, .frames)) at \(Int(fps)) fps = \(unitText(n, .samples)) at \(khz) kHz"
    }

    struct Preset { var id: String; var name: String; var ms: Double; var device: String?; var deviceName: String?; var builtIn: Bool }
    /// the built-in presets: the measured values of 25.11.2026 and the reference
    static var builtInPresets: [Preset] {
        var out = measuredByName.sorted { $0.key < $1.key }.map {
            Preset(id: "builtin." + $0.key, name: $0.key + " (measured 25.11.2026)", ms: $0.value, device: nil, deviceName: $0.key, builtIn: true)
        }
        out.append(Preset(id: "builtin.reference", name: referenceName + " (the reference)", ms: 0, device: nil, deviceName: nil, builtIn: true))
        return out
    }
    static var customPresets: [Preset] {
        let a = UserDefaults.standard.array(forKey: presetsKey) as? [[String: Any]] ?? []
        return a.compactMap { d in
            guard let id = d["id"] as? String, let name = d["name"] as? String, let ms = (d["ms"] as? NSNumber)?.doubleValue else { return nil }
            return Preset(id: id, name: name, ms: ms, device: d["device"] as? String, deviceName: d["deviceName"] as? String, builtIn: false)
        }
    }
    static var allPresets: [Preset] { builtInPresets + customPresets }
    private static func storeCustom(_ list: [Preset]) {
        UserDefaults.standard.set(list.map { p -> [String: Any] in
            var d: [String: Any] = ["id": p.id, "name": p.name, "ms": p.ms]
            if let x = p.device { d["device"] = x }
            if let x = p.deviceName { d["deviceName"] = x }
            return d
        }, forKey: presetsKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }
    @discardableResult
    static func savePreset(name: String, ms: Double, device: String?, deviceName: String?) -> Preset {
        var list = customPresets
        let p = Preset(id: "custom." + UUID().uuidString.prefix(8).lowercased(), name: name, ms: (ms * 1_000_000).rounded() / 1_000_000,
                       device: device, deviceName: deviceName, builtIn: false)
        list.append(p); storeCustom(list); return p
    }
    static func renamePreset(_ id: String, to name: String) -> Bool {
        var list = customPresets
        guard let i = list.firstIndex(where: { $0.id == id }), !name.isEmpty else { return false }
        list[i].name = name; storeCustom(list); return true
    }
    static func deletePreset(_ id: String) -> Bool {
        var list = customPresets
        guard let i = list.firstIndex(where: { $0.id == id }) else { return false }
        list.remove(at: i); storeCustom(list); return true
    }
    static func presetText(_ p: Preset) -> String {
        let scope = p.builtIn ? "built-in" : (p.device == nil ? "any input" : (p.deviceName ?? "one input"))
        return "\(p.name)   \(text(p.ms))   (\(scope))"
    }
    static func presetJSON(_ p: Preset) -> [String: Any] {
        ["id": p.id, "name": p.name, "ms": p.ms, "builtIn": p.builtIn, "device": p.device ?? "any", "deviceName": p.deviceName.map { $0 as Any } ?? NSNull()]
    }
}
