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
        UserDefaults.standard.set((max(-1000, min(1000, ms)) * 10).rounded() / 10, forKey: audioKey(uid))
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
        String(format: ms > 0 ? "+%.1f ms" : "%.1f ms", ms)
    }
}
