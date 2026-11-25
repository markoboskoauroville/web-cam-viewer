import Accelerate
import AVFoundation
import CoreAudio
import Foundation
import os

// v40, 25.11.2026: INSERT, a send/return loop per microphone with measured plug-in delay compensation.
// Marko: "[A] setting to mimic to have some kind of insert system so it can send to BlackHole the sound and receive it from
// the BlackHole. And then I can process it in Blue Cat, for example. And it needs to also be able to measure delay. So called
// plugin compensation delay, which is very popular in every DAW." / "A mic setting [s] please for insert via BlackHole" /
// "Insert via BlackHole is a universal route. I can plug in any application. Blue Cat or Ableton Live doesn't make any
// difference. All what application know, there is an insert path and it can send a signal to get the delay."
//
// Application-agnostic: the app knows only a SEND device and a RETURN device (any two Core Audio devices). The chosen mic's
// sound (gain, on the host clock) goes out of SEND; whatever runs in between (PatchWork, Ableton Live, a hardware loop,
// nothing) is unknown; the RETURN comes back on the host clock, and the round trip R is learned only by MEASURE DELAY
// (a known test signal out of SEND, cross-correlation on RETURN, several bursts, median). R plugs into the composite:
//   L = Dsend + R,  A = -SYNC + L + LappRet + Ldrv  (VirtualMic.swift, Composite)
// Safe bypass: no return for 0.3 s, or digital silence for 1.5 s while the send carries sound = the dry sound, with a note.
// Takes stay dry in v40 (the processed sound reaches Zoom through VMIC); the take path comes next.

/// The VMIC ring read (VirtualMic.render v34-v40) for any ring on the host clock: the sample of time (H + k/outRate - delay)
/// for every output frame, drift by one-sample steps, a 5 ms crossfade on a jump, silence before the start, never old sound.
enum RingRead {
    static func fill(ring: UnsafeMutablePointer<Float>, size: Int, sh: VirtualMic.Shared, delay: Double,
                     r: UnsafeMutablePointer<VirtualMic.Reader>, H: Double, outRate: Double, n: Int, out: UnsafeMutablePointer<Float>) {
        let mask = Int64(size - 1)
        guard sh.rateIn > 0, sh.writeIndex > 0 else { for k in 0..<n { out[k] = 0 }; r.pointee.waitingCycles += 1; return }
        let rateIn = sh.rateIn
        let step = rateIn / outRate
        let box = step >= 1.5 ? Int(step.rounded()) : 1
        let c0 = H - delay
        let T = Double(sh.anchorIndex) + (c0 - sh.anchorTime - sh.driftSec) * rateIn
        let err = r.pointee.pos - T
        r.pointee.lastErrSamples = err
        if !r.pointee.started || r.pointee.generation != sh.generation || abs(err) > 0.003 * rateIn {
            r.pointee.fadeFrom = r.pointee.started ? r.pointee.pos : -1
            r.pointee.fadeLeft = 240
            r.pointee.pos = step == 1 ? T.rounded() : T
            if r.pointee.started { r.pointee.jumps += 1 }
            r.pointee.started = true; r.pointee.generation = sh.generation; r.pointee.correcting = false
        } else {
            if abs(err) >= 0.00025 * rateIn { r.pointee.correcting = true }
            if r.pointee.correcting {
                if err < -0.5 { r.pointee.pos += 1; r.pointee.drops += 1 }
                else if err > 0.5 { r.pointee.pos -= 1; r.pointee.repeats += 1 }
                else { r.pointee.correcting = false }
            }
        }
        let avail = sh.writeIndex
        let oldest = max(sh.validFrom, avail - Int64(size) + 16384)
        var under = 0, old = 0
        @inline(__always) func at(_ p: Double) -> Float {
            let fl = floor(p); let i = Int64(fl); let f = Float(p - fl)
            if i < oldest { old += 1; return 0 }
            if i >= avail || (f > 0 && i + 1 >= avail) { under += 1; return 0 }
            if box > 1, i + Int64(box) <= avail {
                var s: Float = 0
                for j in 0..<box { s += ring[Int((i + Int64(j)) & mask)] }
                return s / Float(box)
            }
            let a = ring[Int(i & mask)]
            return f > 0 ? a * (1 - f) + ring[Int((i + 1) & mask)] * f : a
        }
        for k in 0..<n {
            var v = at(r.pointee.pos + Double(k) * step)
            if r.pointee.fadeLeft > 0 {
                let w = Float(240 - r.pointee.fadeLeft) / 240
                let from: Float = r.pointee.fadeFrom < 0 ? 0 : at(r.pointee.fadeFrom + Double(k) * step)
                v = from * (1 - w) + v * w
                r.pointee.fadeLeft -= 1
            }
            out[k] = v
        }
        if r.pointee.fadeLeft > 0 && r.pointee.fadeFrom >= 0 { r.pointee.fadeFrom += Double(n) * step }
        if under > 0 { r.pointee.underrunFrames += under; r.pointee.underrunCycles += 1 }
        r.pointee.tooOldFrames += old
        r.pointee.lastFillSec = (Double(avail) - r.pointee.pos) / rateIn
        r.pointee.pos += Double(n) * step
        r.pointee.frames += n
        r.pointee.cycles += 1
        r.pointee.lastHostSec = H
    }
}

/// A mono ring filled by an INPUT IO proc, every buffer anchored at its own HAL input time (host clock)
final class AudioRing {
    static let size = 1 << 19
    let ring: UnsafeMutablePointer<Float>
    let shared: UnsafeMutablePointer<VirtualMic.Shared>
    let lk: UnsafeMutablePointer<os_unfair_lock>
    private let w: UnsafeMutablePointer<WriterState>
    struct WriterState { var index: Int64 = 0; var nextSampleTime = -1.0; var generation = 0; var lastHost = 0.0; var peak: Float = 0; var lagMax = 0.0 }
    private let tickSec: Double

    init() {
        ring = .allocate(capacity: Self.size); ring.initialize(repeating: 0, count: Self.size)
        shared = .allocate(capacity: 1); shared.initialize(to: VirtualMic.Shared())
        lk = .allocate(capacity: 1); lk.initialize(to: os_unfair_lock())
        w = .allocate(capacity: 1); w.initialize(to: WriterState())
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        tickSec = Double(tb.numer) / Double(tb.denom) / 1e9
    }

    /// a new start: everything before is silence
    func reset(rate: Double) {
        os_unfair_lock_lock(lk)
        w.pointee.generation += 1; w.pointee.nextSampleTime = -1
        shared.pointee.validFrom = w.pointee.index; shared.pointee.rateIn = rate; shared.pointee.generation = w.pointee.generation
        os_unfair_lock_unlock(lk)
    }

    /// real time (the return device's IO proc): the first two channels mixed to mono, anchored at the buffer's input time
    func write(_ list: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>, rate: Double) {
        let bufs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard bufs.count > 0, let d0 = bufs[0].mData else { return }
        let ch0 = max(1, Int(bufs[0].mNumberChannels))
        let n = Int(bufs[0].mDataByteSize) / (4 * ch0)
        guard n > 0, time.pointee.mFlags.contains(.hostTimeValid) else { return }
        let H = Double(time.pointee.mHostTime) * tickSec
        let st = time.pointee.mSampleTime
        var gen = w.pointee.generation
        if w.pointee.nextSampleTime >= 0 && abs(st - w.pointee.nextSampleTime) > 2 { gen += 1; w.pointee.generation = gen }
        w.pointee.nextSampleTime = st + Double(n)
        let start = w.pointee.index
        var peak: Float = 0
        if bufs.count == 1 {
            let p = d0.assumingMemoryBound(to: Float.self)
            let use = min(2, ch0)
            for k in 0..<n {
                var s: Float = 0
                for c in 0..<use { s += p[k * ch0 + c] }
                s /= Float(use)
                ring[Int((start + Int64(k)) & Int64(Self.size - 1))] = s
                let a = abs(s); if a > peak { peak = a }
            }
        } else {
            let use = min(2, bufs.count)
            for k in 0..<n {
                var s: Float = 0
                for c in 0..<use { if let d = bufs[c].mData { s += d.assumingMemoryBound(to: Float.self)[k] } }
                s /= Float(use)
                ring[Int((start + Int64(k)) & Int64(Self.size - 1))] = s
                let a = abs(s); if a > peak { peak = a }
            }
        }
        w.pointee.index = start + Int64(n)
        let now = Double(mach_absolute_time()) * tickSec
        let lag = now - H
        if lag > w.pointee.lagMax { w.pointee.lagMax = lag }
        w.pointee.lastHost = now
        w.pointee.peak = max(w.pointee.peak * 0.999, peak)
        if os_unfair_lock_trylock(lk) {
            shared.pointee.writeIndex = start + Int64(n)
            shared.pointee.anchorIndex = start; shared.pointee.anchorTime = H
            shared.pointee.rateIn = rate; shared.pointee.generation = gen
            os_unfair_lock_unlock(lk)
        }
    }

    var lastHost: Double { w.pointee.lastHost }
    var peak: Float { w.pointee.peak }
    func takeLagMax() -> Double { let v = w.pointee.lagMax; w.pointee.lagMax = 0; return v }
    func snapshot() -> VirtualMic.Shared { os_unfair_lock_lock(lk); defer { os_unfair_lock_unlock(lk) }; return shared.pointee }

    /// control thread: samples of host times [t, t + count/rate) (nil when not in the ring)
    func copy(from t: Double, count: Int) -> [Float]? {
        let sh = snapshot()
        guard sh.rateIn > 0 else { return nil }
        let i0 = Int64((Double(sh.anchorIndex) + (t - sh.anchorTime) * sh.rateIn).rounded())
        guard i0 >= max(sh.validFrom, sh.writeIndex - Int64(Self.size) + 4096), i0 + Int64(count) <= sh.writeIndex else { return nil }
        var out = [Float](repeating: 0, count: count)
        for k in 0..<count { out[k] = ring[Int((i0 + Int64(k)) & Int64(Self.size - 1))] }
        return out
    }
}

final class InsertEngine {
    static let blackHoleUID = "BlackHole2ch_UID"
    static let returnOutUID = "MantraInsertReturn_UID", returnInUID = "MantraInsertReturnIn_UID"
    static func key(_ what: String, _ uid: String) -> String { "insert.\(what).\(uid)" }

    // per microphone settings (UserDefaults, per audio device UID like gain and SYNC)
    struct Settings {
        var on: Bool; var send: String; var ret: String; var manualMs: Double?
        var measured: [String: Any]?
        var measuredMs: Double? { (measured?["ms"] as? NSNumber)?.doubleValue }
        var latencyMs: Double? { manualMs ?? measuredMs }
    }
    static func settings(_ uid: String) -> Settings {
        let d = UserDefaults.standard
        let defRet = VirtualMic.deviceID(uid: returnInUID) != AudioObjectID(kAudioObjectUnknown) ? returnInUID : ""
        return Settings(on: d.bool(forKey: key("on", uid)),
                        send: d.string(forKey: key("send", uid)) ?? blackHoleUID,
                        ret: d.string(forKey: key("return", uid)) ?? defRet,
                        manualMs: d.object(forKey: key("manualMs", uid)).flatMap { ($0 as? NSNumber)?.doubleValue },
                        measured: d.dictionary(forKey: key("measured", uid)))
    }

    struct Meas {   // the measurement the send IO proc plays (POD)
        var active = false
        var t0 = 0.0, period = 0.7
        var bursts = 0, length = 0
    }

    let ret = AudioRing()
    private unowned let mic: VirtualMic
    private let control = DispatchQueue(label: "webcamviewer.insert", qos: .userInitiated)
    private let lock = NSLock()
    private var sendID = AudioObjectID(kAudioObjectUnknown), retID = AudioObjectID(kAudioObjectUnknown)
    private var sendProc: AudioDeviceIOProcID?, retProc: AudioDeviceIOProcID?
    private let sendReader: UnsafeMutablePointer<VirtualMic.Reader>
    private let sendCache: UnsafeMutablePointer<VirtualMic.Shared>
    private let scratch: UnsafeMutablePointer<Float>
    private let sig: UnsafeMutablePointer<Float>
    private static let sigMax = 96000
    private let meas: UnsafeMutablePointer<Meas>
    private let ctl: UnsafeMutablePointer<SendCtl>
    struct SendCtl { var delaySec = 0.04; var testDelaySec = 0.0; var peak: Float = 0; var lastHost = 0.0; var rate = 48000.0 }
    private let tickSec: Double
    private var timer: DispatchSourceTimer?

    // state (lock)
    private var curUID: String?             // lock
    var uid: String? { lock.withLock { curUID } }
    private var sendRate = 0.0, retRate = 0.0
    private var problem: String?, note: String?, warnings: [String] = []
    private var measuring = false
    private var lastResult: [String: Any]?
    private var silentSince: Double?
    private var healthy = false
    private var lappRet = 0.0
    private(set) var testDelaySamples = 0
    var allowSameDevice = false            // test only (API): send and return may be one device (a plain loop)
    var onChange: (() -> Void)?

    init(mic: VirtualMic) {
        self.mic = mic
        sendReader = .allocate(capacity: 1); sendReader.initialize(to: VirtualMic.Reader())
        sendCache = .allocate(capacity: 1); sendCache.initialize(to: VirtualMic.Shared())
        scratch = .allocate(capacity: VirtualMic.maxFrames); scratch.initialize(repeating: 0, count: VirtualMic.maxFrames)
        sig = .allocate(capacity: Self.sigMax); sig.initialize(repeating: 0, count: Self.sigMax)
        meas = .allocate(capacity: 1); meas.initialize(to: Meas())
        ctl = .allocate(capacity: 1); ctl.initialize(to: SendCtl())
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        tickSec = Double(tb.numer) / Double(tb.denom) / 1e9
    }

    static func now() -> Double { VirtualMic.now() }

    // MARK: devices

    struct Device { let id: AudioObjectID; let uid: String; let name: String; let inputs: Int; let outputs: Int; let hidden: Bool }
    private static func str(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var s: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &s) == noErr, let v = s else { return nil }
        return v.takeRetainedValue() as String
    }
    private static func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    static func describe(_ id: AudioObjectID) -> Device? {
        guard id != AudioObjectID(kAudioObjectUnknown), let uid = str(id, kAudioDevicePropertyDeviceUID) else { return nil }
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIsHidden, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var h: UInt32 = 0; var size = UInt32(4)
        _ = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &h)
        return Device(id: id, uid: uid, name: str(id, kAudioObjectPropertyName) ?? uid,
                      inputs: channels(id, kAudioObjectPropertyScopeInput), outputs: channels(id, kAudioObjectPropertyScopeOutput), hidden: h != 0)
    }
    /// every device the INSERT may use: the visible ones and the hidden return twin of the Mantra Insert pair
    static func devices() -> [Device] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        var out = ids.compactMap { describe($0) }
        if let twin = describe(VirtualMic.deviceID(uid: returnInUID)), !out.contains(where: { $0.uid == twin.uid }) { out.append(twin) }
        // the VirtualCam pair is the Zoom path: never an insert device
        return out.filter { !$0.uid.hasPrefix("MantraVirtualCam") }
    }
    static func name(_ uid: String) -> String { describe(VirtualMic.deviceID(uid: uid))?.name ?? (uid.isEmpty ? "none" : uid) }

    /// what is wrong with a pair (nil = usable) and the warnings
    static func check(send: String, ret: String, micUID: String, allowSame: Bool) -> (error: String?, warnings: [String]) {
        var w: [String] = []
        guard !send.isEmpty else { return ("choose a SEND device", w) }
        guard !ret.isEmpty else { return ("choose a RETURN device (Mantra Insert Return needs the driver v3 install)", w) }
        guard let s = describe(VirtualMic.deviceID(uid: send)) else { return ("the SEND device \(send) is not on this Mac", w) }
        guard let r = describe(VirtualMic.deviceID(uid: ret)) else { return ("the RETURN device \(ret) is not on this Mac", w) }
        if s.outputs == 0 { return ("\(s.name) has no output: it cannot be the SEND", w) }
        if r.inputs == 0 { return ("\(r.name) has no input: it cannot be the RETURN", w) }
        if send.hasPrefix("MantraVirtualCam") || ret.hasPrefix("MantraVirtualCam") { return ("the Mantra VirtualCam pair is Zoom's path, never an insert", w) }
        if ret == micUID { return ("the RETURN cannot be this microphone itself", w) }
        if send == ret && !allowSame {
            return ("SEND and RETURN are the same device (\(s.name)): the other app would hear its own output (a feedback loop). Use a separate RETURN such as Mantra Insert Return.", w)
        }
        if send == returnOutUID && ret == returnInUID { w.append("SEND and RETURN are the two halves of the same Mantra Insert pair: a direct loop with nothing in between.") }
        if send == blackHoleUID || ret == blackHoleUID { w.append("BlackHole 2ch is also your Ableton route: what Ableton sends into it mixes with the insert.") }
        return (nil, w)
    }

    // MARK: start / stop (control queue)

    func apply(uid: String?, _ done: (() -> Void)? = nil) {
        control.async {
            self.stopIO()
            self.lock.lock(); self.curUID = uid; self.problem = nil; self.warnings = []; self.note = nil; self.lastResult = nil; self.lock.unlock()
            if let uid, Self.settings(uid).on { self.startIO(uid) }
            DispatchQueue.main.async { self.onChange?(); done?() }
        }
    }
    func shutdown() { control.sync { self.stopIO() } }

    private func setProblem(_ s: String) { lock.lock(); problem = s; lock.unlock(); NSLog("Webcam Recorder: INSERT: %@", s) }

    private static func rate(_ id: AudioObjectID) -> Double {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v = Float64(0); var size = UInt32(8)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : 0
    }

    private func startIO(_ uid: String) {
        let s = Self.settings(uid)
        let c = Self.check(send: s.send, ret: s.ret, micUID: uid, allowSame: allowSameDevice)
        lock.lock(); warnings = c.warnings; lock.unlock()
        if let e = c.error { setProblem(e); return }
        let sid = VirtualMic.deviceID(uid: s.send), rid = VirtualMic.deviceID(uid: s.ret)
        let sr = Self.rate(sid), rr = Self.rate(rid)
        guard sr > 0, rr > 0 else { setProblem("the devices report no sample rate"); return }
        // the return, an input IO proc: every buffer into the ring at its own input time
        ret.reset(rate: rr)
        var rp: AudioDeviceIOProcID?
        let ring = ret
        guard AudioDeviceCreateIOProcIDWithBlock(&rp, rid, nil, { _, inData, inTime, _, _ in ring.write(inData, inTime, rate: rr) }) == noErr,
              let rproc = rp, AudioDeviceStart(rid, rproc) == noErr else { setProblem("the RETURN device would not start"); return }
        // the send, an output IO proc reading the mic ring (or playing the test signal)
        sendReader.pointee = VirtualMic.Reader()
        ctl.pointee.rate = sr
        var sp: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcIDWithBlock(&sp, sid, nil, { [unowned self] _, _, _, out, outTime in self.renderSend(out, outTime) }) == noErr,
              let sproc = sp, AudioDeviceStart(sid, sproc) == noErr else {
            AudioDeviceStop(rid, rproc); AudioDeviceDestroyIOProcID(rid, rproc)
            setProblem("the SEND device would not start"); return
        }
        sendID = sid; retID = rid; sendProc = sproc; retProc = rproc
        lock.lock(); sendRate = sr; retRate = rr; silentSince = nil; healthy = false; lappRet = 0; lock.unlock()
        let t = DispatchSource.makeTimerSource(queue: control)
        t.schedule(deadline: .now() + 0.25, repeating: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume(); timer = t
        NSLog("Webcam Recorder: INSERT on for %@: send %@ (%.0f Hz), return %@ (%.0f Hz)", uid, s.send, sr, s.ret, rr)
    }

    private func stopIO() {
        timer?.cancel(); timer = nil
        if let p = sendProc { AudioDeviceStop(sendID, p); AudioDeviceDestroyIOProcID(sendID, p) }
        if let p = retProc { AudioDeviceStop(retID, p); AudioDeviceDestroyIOProcID(retID, p) }
        sendProc = nil; retProc = nil; sendID = AudioObjectID(kAudioObjectUnknown); retID = AudioObjectID(kAudioObjectUnknown)
        meas.pointee.active = false
        mic.setReturnRoute(nil, delaySec: 0)
        Composite.shared.setInsert(active: false, lMs: 0, lappRetMs: 0)
        lock.lock(); healthy = false; measuring = false; lock.unlock()
    }

    // MARK: the send IO proc (real time)

    private func renderSend(_ out: UnsafeMutablePointer<AudioBufferList>, _ outTime: UnsafePointer<AudioTimeStamp>) {
        let bufs = UnsafeMutableAudioBufferListPointer(out)
        guard bufs.count > 0 else { return }
        let ch0 = max(1, Int(bufs[0].mNumberChannels))
        let n = min(VirtualMic.maxFrames, Int(bufs[0].mDataByteSize) / (4 * ch0))
        guard n > 0, outTime.pointee.mFlags.contains(.hostTimeValid) else { return }
        let H = Double(outTime.pointee.mHostTime) * tickSec
        let rate = ctl.pointee.rate
        let td = ctl.pointee.testDelaySec
        if meas.pointee.active {
            let m = meas.pointee
            for k in 0..<n {
                let t = H + Double(k) / rate - td - m.t0
                var v: Float = 0
                if t >= 0 {
                    let j = Int(t / m.period)
                    let o = Int(((t - Double(j) * m.period) * rate).rounded(.down))
                    if j < m.bursts && o < m.length { v = sig[o] }
                }
                scratch[k] = v
            }
        } else {
            mic.trySnapshot(sendCache)
            RingRead.fill(ring: mic.ringPointer, size: VirtualMic.ringSize, sh: sendCache.pointee, delay: ctl.pointee.delaySec + td,
                          r: sendReader, H: H, outRate: rate, n: n, out: scratch)
        }
        var peak: Float = 0
        for k in 0..<n { let a = abs(scratch[k]); if a > peak { peak = a } }
        ctl.pointee.peak = max(ctl.pointee.peak * 0.999, peak)
        ctl.pointee.lastHost = H
        for b in bufs {
            guard let d = b.mData else { continue }
            let ch = max(1, Int(b.mNumberChannels))
            let frames = min(n, Int(b.mDataByteSize) / (4 * ch))
            let o = d.assumingMemoryBound(to: Float.self)
            for k in 0..<frames { let v = scratch[k]; for c in 0..<ch { o[k * ch + c] = c < 2 ? v : 0 } }
        }
    }

    // MARK: health and the route (4 times a second)

    private func poll() {
        guard let uid = self.uid else { return }
        let s = Self.settings(uid)
        let now = Self.now()
        // Dsend: the mic ring must hold the sample when the send wants it (VMIC's measured Lapp + 6 ms)
        ctl.pointee.delaySec = (Composite.shared.micLappMs + 6) / 1000
        ctl.pointee.testDelaySec = Double(testDelaySamples) / max(1, ctl.pointee.rate)
        // LappRet: the return sample of time t is in the ring at t + its buffer + lag; the Feed writes ahead
        let lag = ret.takeLagMax()
        lock.lock()
        if lag > 0 { let need = (lag + mic.feedAheadSec) * 1000 + 3; lappRet = max(lappRet, (need * 2).rounded(.up) / 2) }
        let fresh = now - ret.lastHost < 0.3
        let returnSilent = ret.peak < 1e-6
        let sendLoud = ctl.pointee.peak > 1e-3
        if returnSilent && sendLoud && !measuring { if silentSince == nil { silentSince = now } } else { silentSince = nil }
        let deadSilent = silentSince.map { now - $0 > 1.5 } ?? false
        var why: String?
        if measuring { why = "measuring: the dry sound goes to Zoom meanwhile" }
        else if !fresh { why = "no sound comes back from the RETURN (\(Self.name(s.ret))): the dry sound goes on. Is the other app running with output = \(Self.name(s.ret))?" }
        else if deadSilent { why = "the RETURN is silent while the SEND carries sound: the dry sound goes on. In the other app: input = \(Self.name(s.send)), output = \(Self.name(s.ret)), monitoring on." }
        else if s.latencyMs == nil { why = "the insert delay is not measured yet: press MEASURE DELAY (the dry sound goes on until then)" }
        let ok = why == nil
        let changed = ok != healthy || note != why
        healthy = ok; note = why
        // L = Dsend + R: the measured round trip R already holds a test delay (the send itself is shifted by it)
        let L = (s.latencyMs ?? 0) + ctl.pointee.delaySec * 1000
        let lr = max(lappRet, 10)
        lock.unlock()
        Composite.shared.setInsert(active: ok, lMs: L, lappRetMs: lr)
        mic.setReturnRoute(ok ? ret : nil, delaySec: Composite.shared.returnReadDelayMs / 1000)
        if changed { DispatchQueue.main.async { self.onChange?() } }
    }

    // MARK: MEASURE DELAY

    enum Signal: String { case chirp, click, noise }
    /// the test signal at `rate`: a 0.2 s log sweep 100 Hz-8 kHz (Hann edges), one click, or a 0.2 s white-noise burst
    static func make(_ s: Signal, rate: Double, level: Double) -> [Float] {
        let g = Float(pow(10, level / 20))
        switch s {
        case .click:
            var x = [Float](repeating: 0, count: Int(rate * 0.01)); x[0] = g; return x
        case .noise:
            var seed: UInt32 = 0x1234567
            return (0..<Int(rate * 0.2)).map { _ in seed = seed &* 1664525 &+ 1013904223; return g * (Float(seed >> 8) / Float(1 << 24) * 2 - 1) }
        case .chirp:
            let n = Int(rate * 0.2), f0 = 100.0, f1 = 8000.0, T = 0.2
            let k = log(f1 / f0)
            return (0..<n).map { i in
                let t = Double(i) / rate
                let ph = 2 * Double.pi * f0 * T / k * (exp(t / T * k) - 1)
                let e = min(1, min(Double(i), Double(n - 1 - i)) / (rate * 0.005))
                return g * Float(sin(ph) * (0.5 - 0.5 * cos(Double.pi * e)))
            }
        }
    }

    /// sends `repeats` bursts out of SEND, finds each on RETURN; the median round trip is stored for this microphone when
    /// the result is clean. The dry sound goes to Zoom meanwhile. Never while a take runs (the caller checks).
    func measure(signal: Signal, levelDB: Double, repeats: Int, _ done: @escaping ([String: Any]) -> Void) {
        control.async {
            func fail(_ e: String, _ extra: [String: Any] = [:]) {
                var r = extra; r["ok"] = false; r["error"] = e
                self.lock.lock(); self.measuring = false; self.lastResult = r; self.lock.unlock()
                self.meas.pointee.active = false
                DispatchQueue.main.async { self.onChange?(); done(r) }
            }
            guard let uid = self.uid, self.sendProc != nil else { fail("INSERT is not running for this microphone (switch it on first)"); return }
            let (sr, rr) = self.lock.withLock { (self.sendRate, self.retRate) }
            guard abs(sr - rr) < 1 else { fail(String(format: "SEND runs at %.0f Hz and RETURN at %.0f Hz: set both to the same rate", sr, rr)); return }
            let x = Self.make(signal, rate: sr, level: levelDB)
            guard x.count <= Self.sigMax else { fail("test signal too long"); return }
            for i in 0..<x.count { self.sig[i] = x[i] }
            let reps = max(2, min(12, repeats)), period = 0.8
            self.lock.lock(); self.measuring = true; self.lock.unlock()
            self.poll()   // the route goes dry before the first burst
            let t0 = Self.now() + 0.4
            self.meas.pointee = Meas(active: true, t0: t0, period: period, bursts: reps, length: x.count)
            DispatchQueue.main.async { self.onChange?() }
            Thread.sleep(forTimeInterval: 0.4 + period * Double(reps) + 0.3)
            self.meas.pointee.active = false
            // each burst: the return from its send time on, 0.75 s of lags
            let td = Double(self.testDelaySamples) / sr
            var lags: [Double] = [], confs: [Double] = [], signs: [Double] = [], levels: [Double] = []
            let maxLag = Int(sr * 0.75)
            for j in 0..<reps {
                let ts = t0 + Double(j) * period
                guard let seg = self.ret.copy(from: ts, count: maxLag + x.count) else { continue }
                var corr = [Float](repeating: 0, count: maxLag)
                seg.withUnsafeBufferPointer { s in x.withUnsafeBufferPointer { f in
                    vDSP_conv(s.baseAddress!, 1, f.baseAddress!, 1, &corr, 1, vDSP_Length(maxLag), vDSP_Length(x.count)) } }
                var best = 0; var bestV: Float = 0
                for i in 0..<maxLag where abs(corr[i]) > bestV { bestV = abs(corr[i]); best = i }
                // the window energy at the peak for a normalised confidence
                var e: Float = 0; var et: Float = 0
                for i in 0..<x.count { let v = seg[best + i]; e += v * v; et += x[i] * x[i] }
                let conf = Double(bestV / max(1e-12, sqrt(e * et)))
                var frac = 0.0
                if best > 0 && best < maxLag - 1 {
                    let a = Double(abs(corr[best - 1])), b = Double(abs(corr[best])), c = Double(abs(corr[best + 1]))
                    let den = a - 2 * b + c
                    if abs(den) > 1e-12 { frac = 0.5 * (a - c) / den }
                }
                var rms: Float = 0; vDSP_rmsqv(seg, 1, &rms, vDSP_Length(seg.count))
                levels.append(20 * log10(Double(max(rms, 1e-9))))
                lags.append((Double(best) + frac) / sr * 1000)
                confs.append(conf); signs.append(corr[best] < 0 ? -1 : 1)
            }
            let base: [String: Any] = ["signal": signal.rawValue, "levelDB": levelDB, "repeats": reps,
                                       "valuesMs": lags.map { ($0 * 1000).rounded() / 1000 }, "confidence": confs.map { ($0 * 1000).rounded() / 1000 },
                                       "returnLevelDB": levels.map { ($0 * 10).rounded() / 10 }, "testDelaySamples": self.testDelaySamples]
            guard lags.count >= 2 else { fail("no signal came back (the RETURN ring held nothing for the bursts)", base); return }
            if (levels.max() ?? -200) < -90 { fail("no signal came back: the RETURN stayed silent (is the other app passing its input to its output?)", base); return }
            let med = lags.sorted()[lags.count / 2]
            let spread = (lags.max() ?? 0) - (lags.min() ?? 0)
            let conf = confs.sorted()[confs.count / 2]
            var r = base
            r["ms"] = (med * 1000).rounded() / 1000; r["spreadMs"] = (spread * 1000).rounded() / 1000
            r["medianConfidence"] = (conf * 1000).rounded() / 1000
            r["polarity"] = signs.filter { $0 < 0 }.count > signs.count / 2 ? "inverted" : "normal"
            r["at"] = ISO8601DateFormatter().string(from: Date())
            if conf < 0.3 { fail("the processor changes the signal too much (confidence \(String(format: "%.2f", conf))): try another test signal", r); return }
            if spread > 1.0 { fail(String(format: "the delay is not steady (spread %.2f ms): measure again", spread), r); return }
            UserDefaults.standard.set(r, forKey: Self.key("measured", uid))
            r["ok"] = true
            self.lock.lock(); self.measuring = false; self.lastResult = r; self.lock.unlock()
            self.poll()
            DispatchQueue.main.async { self.onChange?(); done(r) }
        }
    }

    func setTestDelay(_ samples: Int) { lock.lock(); testDelaySamples = max(0, min(48000, samples)); lock.unlock() }

    // MARK: status

    var state: String {
        lock.lock(); defer { lock.unlock() }
        guard let u = curUID, Self.settings(u).on else { return "off" }
        if problem != nil { return "problem" }
        if measuring { return "measuring" }
        return healthy ? "active" : "bypassed"
    }

    func status() -> [String: Any] {
        let st = state
        lock.lock(); defer { lock.unlock() }
        var out: [String: Any] = ["state": st, "problem": inn(problem), "note": inn(note), "warnings": warnings,
                                  "sendRate": sendRate, "returnRate": retRate, "lappReturnMs": lappRet,
                                  "sendDelayMs": (ctl.pointee.delaySec * 10000).rounded() / 10, "testDelaySamples": testDelaySamples,
                                  "sendPeak": Double(ctl.pointee.peak), "returnPeak": Double(ret.peak),
                                  "returnFresh": Self.now() - ret.lastHost < 0.3, "lastMeasure": inn(lastResult),
                                  "sendReader": ["underrunFrames": sendReader.pointee.underrunFrames, "jumps": sendReader.pointee.jumps,
                                                 "drops": sendReader.pointee.drops, "repeats": sendReader.pointee.repeats] as [String: Any]]
        if let u = curUID {
            let s = Self.settings(u)
            out["uid"] = u
            out["on"] = s.on; out["send"] = s.send; out["sendName"] = Self.name(s.send)
            out["return"] = s.ret; out["returnName"] = Self.name(s.ret)
            out["measuredMs"] = inn(s.measuredMs); out["manualMs"] = inn(s.manualMs)
            out["latencyMs"] = inn(s.latencyMs); out["measured"] = inn(s.measured)
        }
        out["help"] = InsertEngine.help
        return out
    }

    static let help = "In the other app: input = the SEND device, output = the RETURN device, monitoring on. "
        + "Blue Cat PatchWork: Edit > Audio Setup: Input BlackHole 2ch, Output Mantra Insert Return. "
        + "Ableton Live: Settings > Audio: Input BlackHole 2ch, Output Mantra Insert Return; a track with input 1/2, Monitor In."
}

private func inn(_ x: Any?) -> Any { x ?? NSNull() }
