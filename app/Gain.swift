import Foundation
import CoreAudio
import AVFoundation

// v31, 25.11.2026: GAIN per sound input with AUTO GAIN, and 32-bit float takes. Marko (momentaryupdates.md):
// "I'm trying now to record with my Rode microphone, and the gain is too much ... I just need simple gain thing ...
// Just to press auto gain and then it adjust the gain level. It's not compressor, it's just like in my Mixer CQ 10
// (CQ-12T). Listening and adjusting the gain." and "Can we enable also 32 bit recording in our web recorder app so there
// is no need for gain at all?"
//
// The gain G (dB, -36…+24, 0.5 dB steps) is one number per sound input, `gain.dB.<audioUID>`, applied where the input
// enters the app. A device with a settable Core Audio input volume in dB (the RØDE NT1 5th Gen: 0…60 dB) is moved on the
// DEVICE first, as a mixer's gain knob: 0 dB = the device's top, G below 0 turns the device down; what the device cannot
// give (above its top, below its bottom) is done digitally. A device without one: all of G is digital, in the PCM of the
// take (AudioTrack) and in the meter. A pure gain: one multiplication, no compressor, no limiter, no AGC. In an AAC take
// the samples are held at full scale (a guard that only protects); a 32-bit float take keeps every sample as it is.
enum Gain {
    static let minDB = -36.0, maxDB = 24.0, step = 0.5
    static let changed = Notification.Name("GainValuesChanged")
    static func key(_ uid: String) -> String { "gain.dB.\(uid)" }
    static func stored(_ uid: String) -> Double? {
        UserDefaults.standard.object(forKey: key(uid)).flatMap { ($0 as? NSNumber)?.doubleValue }
    }
    /// `lo`: the bottom for this input (a device's own volume may reach lower: the RØDE's 0…60 dB gives -60)
    static func clamp(_ db: Double, lo: Double = minDB) -> Double { min(maxDB, max(lo, (db / step).rounded() * step)) }
    static func text(_ db: Double) -> String { db == 0 ? "0.0 dB" : String(format: "%+.1f dB", db) }
    static func dbfs(_ x: Float) -> Double { x <= 1e-6 ? -120 : Double(20 * log10(x)) }

    // ------------------------------------------------------------------ the take's audio format
    /// "aac" (default, as before v31) or "f32": track 1 as 32-bit float PCM (pcm_f32le), nothing clips, the level can be
    /// corrected later without damage. The camera scratch track stays AAC.
    static let formatKey = "audio.format"
    static var floatTakes: Bool {
        get { UserDefaults.standard.string(forKey: formatKey) == "f32" }
        set { UserDefaults.standard.set(newValue ? "f32" : "aac", forKey: formatKey); NotificationCenter.default.post(name: changed, object: nil) }
    }

    // ------------------------------------------------------------------ the digital factor (capture queue reads it)
    private static let lock = NSLock()
    private static var _linear: Float = 1
    private static var _db: Double = 0
    /// the digital part now, linear; set on the main thread, read on the capture queue for every buffer
    static var digitalLinear: Float { lock.lock(); defer { lock.unlock() }; return _linear }
    static var digitalDB: Double { lock.lock(); defer { lock.unlock() }; return _db }
    static func setDigital(_ db: Double) {
        lock.lock(); _db = db; _linear = Float(pow(10, db / 20)); lock.unlock()
    }

    // ------------------------------------------------------------------ levels (capture queue)
    struct Levels { var peak: Float = 0; var rawPeak: Float = 0; var rms: [Float] = []; var clipped = false; var overRaw = 0 }

    /// one pass over a buffer: the raw peak (unclamped, a float input may go above 1.0 = above 0 dBFS), the peak and the
    /// per-channel RMS after the digital factor `g`, clipped = the converter (raw ≥ 0.999) or the guard (raw·g ≥ 0.999)
    static func levels(_ sb: CMSampleBuffer, g: Float) -> Levels {
        var out = Levels()
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { return out }
        var size = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &size, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let cap = max(size, MemoryLayout<AudioBufferList>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 16)
        defer { raw.deallocate() }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: list,
            bufferListSize: cap, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr else { return out }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = Int(asbd.mBitsPerChannel)
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        var sums = [Double](repeating: 0, count: channels), counts = [Int](repeating: 0, count: channels)
        var base = 0, peak: Float = 0
        for buf in UnsafeMutableAudioBufferListPointer(list) {
            guard let d = buf.mData else { continue }
            let per = max(1, Int(buf.mNumberChannels))
            let bytes = bits / 8
            guard bytes > 0 else { continue }
            let n = Int(buf.mDataByteSize) / bytes
            for k in 0..<n {
                let v: Float
                if isFloat && bits == 32 { v = d.load(fromByteOffset: k * 4, as: Float.self) }
                else if bits == 16 { v = Float(d.load(fromByteOffset: k * 2, as: Int16.self)) / 32768 }
                else if bits == 32 { v = Float(Double(d.load(fromByteOffset: k * 4, as: Int32.self)) / 2147483648) }
                else { continue }
                let a = abs(v)
                if a > peak { peak = a }
                if a > 1 { out.overRaw += 1 }
                let c = min(channels - 1, base + k % per)
                let x = Double(v * g)
                sums[c] += x * x; counts[c] += 1
            }
            base += per
        }
        out.rawPeak = peak
        out.peak = peak * g
        out.clipped = peak >= 0.999 || peak * g >= 0.999
        out.rms = (0..<channels).map { counts[$0] > 0 ? Float((sums[$0] / Double(counts[$0])).squareRoot()) : 0 }
        return out
    }

    /// the take's PCM (interleaved, AudioTrack's format) times `g`; `guardFullScale` holds every sample at full scale
    /// (only protects: a sample under full scale is never touched), a float take keeps samples above 1.0 as they are
    static func apply(_ pcm: inout Data, format: String, g: Float, guardFullScale: Bool) {
        if g == 1 && !(guardFullScale && format == "f32le") { return }
        pcm.withUnsafeMutableBytes { (b: UnsafeMutableRawBufferPointer) in
            switch format {
            case "f32le":
                let p = b.bindMemory(to: Float.self)
                for i in 0..<p.count {
                    var x = p[i] * g
                    if guardFullScale { x = min(1, max(-1, x)) }
                    p[i] = x
                }
            case "s16le":
                let p = b.bindMemory(to: Int16.self)
                for i in 0..<p.count { p[i] = Int16(max(-32768, min(32767, (Float(p[i]) * g).rounded()))) }
            case "s32le":
                let p = b.bindMemory(to: Int32.self)
                for i in 0..<p.count { p[i] = Int32(max(-2147483648.0, min(2147483647.0, (Double(p[i]) * Double(g)).rounded()))) }
            default: break
            }
        }
    }
}

/// A device's own input volume in dB (MANTRA_SOUND_RECORDER app/Audio.swift VolumeWatch: decibels, dbRange, setDecibels,
/// the same Core Audio calls), found by the AVCaptureDevice's uniqueID = the Core Audio device UID.
struct HardwareGain {
    let device: AudioDeviceID
    let elements: [UInt32]
    let range: (Double, Double)

    static func find(uid: String) -> HardwareGain? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: CFString = uid as CFString
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = withUnsafeMutablePointer(to: &cf) { p in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<CFString>.size), p, &size, &dev)
        }
        guard st == noErr, dev != 0 else { return nil }
        // the main element when it has the volume (the RØDE), else every channel that has it
        var els: [UInt32] = []
        for e in [kAudioObjectPropertyElementMain] + Array(UInt32(1)...UInt32(8)) {
            if settable(dev, e) { els.append(e); if e == kAudioObjectPropertyElementMain { break } }
        }
        guard let first = els.first else { return nil }
        var ra = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeRangeDecibels, mScope: kAudioDevicePropertyScopeInput, mElement: first)
        var r = AudioValueRange(); var rs = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectHasProperty(dev, &ra), AudioObjectGetPropertyData(dev, &ra, 0, nil, &rs, &r) == noErr, r.mMaximum > r.mMinimum else { return nil }
        return HardwareGain(device: dev, elements: els, range: (r.mMinimum, r.mMaximum))
    }

    private static func settable(_ dev: AudioDeviceID, _ e: UInt32) -> Bool {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeDecibels, mScope: kAudioDevicePropertyScopeInput, mElement: e)
        var s: DarwinBoolean = false
        return AudioObjectHasProperty(dev, &a) && AudioObjectIsPropertySettable(dev, &a, &s) == noErr && s.boolValue
    }

    /// the device's volume now, dB (read back from the device, never from our request)
    var db: Double? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeDecibels, mScope: kAudioDevicePropertyScopeInput, mElement: elements[0])
        var v = Float32(0); var sz = UInt32(4)
        return AudioObjectGetPropertyData(device, &a, 0, nil, &sz, &v) == noErr ? Double(v) : nil
    }

    func set(_ db: Double) {
        for e in elements {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeDecibels, mScope: kAudioDevicePropertyScopeInput, mElement: e)
            var x = Float32(min(range.1, max(range.0, db)))
            AudioObjectSetPropertyData(device, &a, 0, nil, 4, &x)
        }
    }

    /// G (0 = the device's top) split into the device's part and the digital rest
    func split(_ g: Double) -> (hw: Double, digital: Double) {
        let hw = min(range.1, max(range.0, range.1 + min(g, 0)))
        return (hw, g - (hw - range.1))
    }
}

/// AUTO GAIN, the Gain Assistant of MANTRA_SOUND_RECORDER (app/Audio.swift, toggleAutoGain / stepAutoGain, v3 of
/// 31.10.2026, itself the "KAuto Gain Steps" of the CQ's MixPad): it waits for sound (a peak over -45 dBFS, 15 s at most),
/// measures the loudest peak, moves the gain so that peak sits at -12 dBFS, measures again (0.3 s to settle) until it is
/// within 1.5 dB, 8 rounds at most. Here the first measurement lasts 5 s (Marko plays or speaks at his loudest), the
/// checks after a move 2 s as in the Sound Recorder. One press; it is never running while he records.
final class AutoGain {
    enum Step: String { case idle, listening, measuring, done, failed }
    static let target = -12.0, wake = -45.0, tolerance = 1.5, firstWindow = 5.0, checkWindow = 2.0, maxRounds = 8, wait = 15.0
    private(set) var step: Step = .idle
    private(set) var note: String?
    private(set) var before: Double?            // the gain before the last press: UNDO
    private var start = Date(), listenStart = Date(), peak = -120.0, round = 0, doneAt = Date()
    var get: () -> Double = { 0 }
    var lo: () -> Double = { Gain.minDB }
    var set: (Double) -> Void = { _ in }
    var running: Bool { step == .listening || step == .measuring }

    func begin() {
        before = get()
        step = .listening; listenStart = Date(); round = 0; peak = -120
        note = "AUTO GAIN: play or speak at your normal loudest level"
    }
    func cancel() { if running { step = .idle; note = "AUTO GAIN: stopped" } }
    func say(_ t: String?) { if !running { note = t } }
    func forgetUndo() { before = nil }

    /// seconds left in the measurement now (the countdown), nil when not measuring
    var secondsLeft: Double? {
        guard step == .measuring else { return step == .listening ? max(0, Self.wait - Date().timeIntervalSince(listenStart)) : nil }
        let w = round == 0 ? Self.firstWindow : Self.checkWindow
        return max(0, w - Date().timeIntervalSince(start))
    }

    private func fail(_ why: String) { step = .failed; doneAt = Date(); note = "AUTO GAIN: " + why }

    /// main thread, every buffer: the peak of the buffer after the gain, dBFS
    func feed(_ peakNow: Double) {
        let now = Date()
        switch step {
        case .idle, .done, .failed: break
        case .listening:
            if peakNow > Self.wake { step = .measuring; start = now; peak = peakNow }
            else if now.timeIntervalSince(listenStart) > Self.wait {
                let moved = round > 0
                fail(moved ? "the sound stopped; the gain stays at \(Gain.text(get())) (UNDO goes back)"
                           : "no sound came in for 15 s: SILENT, nothing changed")
                if !moved { before = nil }
            }
        case .measuring:
            if now < start { break }                                   // the new gain settling
            peak = max(peak, peakNow)
            let w = round == 0 ? Self.firstWindow : Self.checkWindow
            guard now.timeIntervalSince(start) >= w else { break }
            if peak < Self.wake { step = .listening; listenStart = now; note = "AUTO GAIN: waiting for sound"; break }
            let delta = Self.target - peak
            if abs(delta) <= Self.tolerance {
                step = .done; doneAt = now
                note = String(format: "AUTO GAIN: set, the loudest peak at %.1f dBFS, the gain %@", peak, Gain.text(get()))
            } else if round >= Self.maxRounds {
                fail("the level would not settle; try again")
            } else {
                let was = get()
                let to = Gain.clamp(was + delta, lo: lo())
                if abs(to - was) < Gain.step / 2 {
                    fail(delta > 0 ? "too quiet even at \(Gain.text(Gain.maxDB)): closer to the microphone"
                                   : "too loud even at \(Gain.text(lo()))")
                } else {
                    set(to)
                    round += 1; peak = -120; start = now.addingTimeInterval(0.3)
                }
            }
        }
    }
}
