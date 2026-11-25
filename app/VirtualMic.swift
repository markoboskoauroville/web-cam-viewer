import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import os

// v34, 25.11.2026 = VC-3/VC-4 of Mantra VirtualCam (docs/VIRTUALCAM_BUILD.md, docs/VIRTUALCAM_PLAN.md §7-8).
// Marko: "I'm in Zoom. I choose my camera as OBS virtual camera. That's fine. I get image. But how to get sound which is
// processed with the same application webcam recorder and then have it in sync with sound, with images perfectly? ... So we
// solve this issue in recordings but how to do it in live stream" and "you need a composite for plugin delays so my
// students always see me playing in sync."
//
// VMIC: the chosen sound input (its hardware gain on the device, the digital gain of v31) goes, mono on both channels, into
// the hidden Feed of the Mantra VirtualCam driver ("Mantra VirtualCam Feed", found by UID only); Zoom picks the microphone
// "Mantra VirtualCam". Every sample is placed on the host clock: the sample captured at true time c is written for the
// Feed's output host time c + writeDelay, and the driver hands it to Zoom with that same host time (loopback exact, §3).
//
// The composite delay (one side held, never both; all ms on the host clock, against the camera's own HDMI sound):
//   A = micOffset + L + Lapp + Ldrv          micOffset = -SYNC of the mic (SYNC > 0 = the mic hears EARLIER than the camera)
//   V = Vpath - videoDelay                   Vpath = VCAM's measured capture stamp → sink (without its hold)
//   video_hold = max(0, A - V + trim)        audio_hold = max(0, V - A - trim)
//   writeDelay = Lapp + L + audio_hold       (after the mic's own stamp; Ldrv comes after the write)
// trim = virtualcam.trimMs, signed, positive = in the clap test the sound was still LATER than the picture.
//
// Real time: the IO proc allocates nothing, never waits on a lock (one os_unfair_lock_trylock of a few words; on a miss it
// uses the last copy), never calls Objective-C or prints. The ring is 2^19 mono Float32 samples, written by the capture
// queue, read by the IO proc; drift of the mic's crystal against the host clock comes from the arrival times (LESSONS 49)
// and is corrected by dropping or repeating one sample at a time; a delay change or a time stamp jump crossfades 5 ms.

/// The plan of both holds, shared by VCAM (the picture) and VMIC (the sound). Thread safe.
final class Composite {
    static let shared = Composite()
    static let lastVKey = "virtualmic.lastVideoPathMs"
    static let defaultVpathMs = 65.0, maxAudioHoldMs = 1000.0

    private let lock = NSLock()
    // inputs
    private var micUID: String?, micName: String?, micSyncMs = 0.0, micReference = false
    private var videoDelayMs = 0.0, trimMs = 0.0
    private var processorMs = 0.0                 // L: the processor in the chain (PatchWork, v35); 0 now
    private var lappMs = 30.0, lappMeasured = false
    private var ldrvMs = 0.0
    private var vpathMs = Composite.storedV, vSource = UserDefaults.standard.object(forKey: Composite.lastVKey) == nil ? "default" : "last measured"
    private var mantra = true                     // Zoom's microphone is Mantra VirtualCam (v34 default)
    private var bypass = false                    // test only (POST /virtualmic {"composite": false}): both holds 0
    // outputs (applied with a 2 ms hysteresis (v35; 1 ms in v34), so measurement noise never moves the sound)
    private var vHold = 0.0, aHold = 0.0, writeDelay = 30.0, aMs = 0.0, vMs = 0.0, applied = false
    private var changes = 0
    private var lastSave = 0.0

    static var storedV: Double {
        let v = UserDefaults.standard.double(forKey: lastVKey)
        return v > 0 ? v : defaultVpathMs
    }

    func setMic(uid: String?, name: String?, syncMs: Double, reference: Bool) {
        lock.lock(); micUID = uid; micName = name; micSyncMs = reference ? 0 : syncMs; micReference = reference; lock.unlock(); recompute()
    }
    func setVideoDelay(_ ms: Double) { lock.lock(); videoDelayMs = ms; lock.unlock(); recompute() }
    func setTrim(_ ms: Double) { lock.lock(); trimMs = ms; lock.unlock(); recompute() }
    func setProcessor(_ ms: Double) { lock.lock(); processorMs = max(0, min(2000, ms)); lock.unlock(); recompute(force: true) }
    func setDriver(_ ms: Double) { lock.lock(); ldrvMs = max(0, ms); lock.unlock(); recompute() }
    func setLapp(_ ms: Double, measured: Bool) { lock.lock(); lappMs = ms; lappMeasured = measured; lock.unlock(); recompute() }
    func setBypass(_ on: Bool) { lock.lock(); bypass = on; lock.unlock(); recompute(force: true) }
    func setMantra(_ on: Bool) { lock.lock(); let was = mantra; mantra = on; lock.unlock(); recompute(force: was != on) }
    /// VCAM's measured path (capture stamp → enqueue, without the hold), 4 times a second while it feeds
    func setVideoPath(_ ms: Double) {
        // v35: smoothed (time constant about 5 s at 4 updates a second); the first measurement is taken as it is
        lock.lock(); vpathMs = vSource == "VCAM measured" ? vpathMs + (ms - vpathMs) * 0.05 : ms; vSource = "VCAM measured"
        let save = VirtualMic.now() - lastSave > 30; if save { lastSave = VirtualMic.now() }
        lock.unlock()
        if save { UserDefaults.standard.set((ms * 10).rounded() / 10, forKey: Self.lastVKey) }
        recompute()
    }

    var isMantra: Bool { lock.lock(); defer { lock.unlock() }; return mantra }
    var videoHoldMs: Double { lock.lock(); defer { lock.unlock() }; return vHold }
    var audioHoldMs: Double { lock.lock(); defer { lock.unlock() }; return aHold }
    var writeDelayMs: Double { lock.lock(); defer { lock.unlock() }; return writeDelay }
    /// mic → reference time (s): the mic's sample at true time c belongs to the camera's frame stamped c + SYNC − videoDelay
    var micToPictureSec: Double { lock.lock(); defer { lock.unlock() }; return (micSyncMs - videoDelayMs) / 1000 }

    private func recompute(force: Bool = false) {
        lock.lock()
        let micOffset = -micSyncMs
        let A = micOffset + processorMs + lappMs + ldrvMs
        let V = vpathMs - videoDelayMs
        let vh = bypass ? 0 : max(0, A - V + trimMs)
        let ah = bypass ? 0 : min(Self.maxAudioHoldMs, max(0, V - A - trimMs))
        let wd = lappMs + processorMs + ah
        aMs = A; vMs = V
        if !applied || force || abs(wd - writeDelay) > 2.0 || abs(vh - vHold) > 2.0 || (vh > 0) != (vHold > 0) {
            if applied { changes += 1 }
            vHold = vh; aHold = ah; writeDelay = wd; applied = true
        }
        lock.unlock()
    }

    private static func r1(_ x: Double) -> Double { (x * 10).rounded() / 10 }

    /// the readable line for the VCAM/VMIC tooltips
    var line: String { lock.lock(); defer { lock.unlock() }; return lineLocked }
    private var lineLocked: String {
        let total = writeDelay + ldrvMs
        if vHold > 0 { return String(format: "picture held %.0f ms to match the sound (sound path %.0f ms)", vHold, total) }
        return String(format: "sound held %.0f ms to match the picture", total)
    }

    func status() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return [
            "zoomMicIsMantra": mantra, "bypassed": bypass,
            "mic": ["uid": vnn(micUID), "name": vnn(micName), "syncMs": micSyncMs, "reference": micReference] as [String: Any],
            "micOffsetMs": Self.r1(-micSyncMs), "LpwMs": Self.r1(processorMs), "LauMs": 0, "LappMs": Self.r1(lappMs),
            "LappMeasured": lappMeasured, "LdrvMs": Self.r1(ldrvMs),
            "AMs": Self.r1(aMs), "VpathMs": Self.r1(vpathMs), "VpathSource": vSource, "videoDelayMs": videoDelayMs, "VMs": Self.r1(vMs),
            "trimMs": trimMs,
            "videoHoldMs": Self.r1(vHold), "audioHoldMs": Self.r1(aHold),
            "soundDelayMs": Self.r1(writeDelay + ldrvMs), "pictureDelayMs": Self.r1(vMs + videoDelayMs + vHold),
            "changes": changes,
            "line": lineLocked,
            "formula": "A = micOffset + L + Lapp + Ldrv (micOffset = -SYNC); V = Vpath - videoDelay; video_hold = max(0, A - V + trim); audio_hold = max(0, V - A - trim); the sound is written at mic stamp + Lapp + L + audio_hold; trim > 0 = the sound was later than the picture",
        ]
    }
}

final class VirtualMic {
    static let feedUID = "MantraVirtualCamFeed_UID", micUID = "MantraVirtualCam_UID", aggregateUID = "MantraVirtualCamAggregate_UID"
    static let onKey = "virtualmic.on"
    static let feedName = "Mantra VirtualCam Feed", micName = "Mantra VirtualCam"
    static let outRate = 48000.0
    static let ringSize = 1 << 19
    static let mask = Int64(ringSize - 1)
    static let maxFrames = 8192

    /// what the producer publishes (and the control thread: the delay, the flash); copied by the IO proc under trylock
    struct Shared {
        var writeIndex: Int64 = 0          // samples written so far (the next sample's index)
        var anchorIndex: Int64 = 0
        var anchorTime = 0.0               // host seconds of the sample at anchorIndex (its capture stamp)
        var rateIn = 0.0
        var driftSec = 0.0                 // true capture time − stamp time (arrival envelope)
        var generation = 0                 // a new input / a stamp jump: the reader jumps (crossfade)
        var delaySec = 0.03                // writeDelay
        var flash = false
        var flashOffsetSec = 0.0           // mic time → picture time (SYNC − videoDelay)
        var validFrom: Int64 = 0           // the first sample of this run/timeline: anything older is silence, never old sound
    }
    /// the IO proc's own state (only the IO proc writes; the status thread reads the counters, racy but harmless)
    struct Reader {
        var started = false
        var generation = -1
        var pos = 0.0                      // read position in input samples
        var fadeLeft = 0, fadeFrom = 0.0
        var correcting = false
        var cycles = 0, underrunFrames = 0, underrunCycles = 0, tooOldFrames = 0, drops = 0, repeats = 0, jumps = 0
        var aheadMax = 0.0, aheadMaxPrev = 0.0, aheadWindowStart = 0.0
        var procMaxUs = 0.0, procSumUs = 0.0
        var lastFillSec = 0.0, lastErrSamples = 0.0, lastHostSec = 0.0, frames = 0
        var waitingCycles = 0
        var flashes = 0
        var boxN = 1
    }

    private let ring: UnsafeMutablePointer<Float>
    private let scratch: UnsafeMutablePointer<Float>
    private let shared: UnsafeMutablePointer<Shared>
    private let cache: UnsafeMutablePointer<Shared>
    private let reader: UnsafeMutablePointer<Reader>
    private let lk: UnsafeMutablePointer<os_unfair_lock>
    private let tickSec: Double

    private let control = DispatchQueue(label: "webcamviewer.vmic.control", qos: .userInitiated)
    private let lock = NSLock()   // control-side values (never in the IO proc)
    private var feedID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var running = false
    private var route = "none"
    private var problem: String?
    private var note: String?
    private var feedFormat = ""
    private var bufferFrames: UInt32 = 0
    private var outChannels = 2
    private var listening = false
    private var timer: DispatchSourceTimer?
    private var driver: [String: Any] = [:]
    private var driverPrev: (silent: Int, overloads: Int, gap: Int, at: Double)?
    private var silentRate = 0.0, newOverloads = 0, newGap = 0
    private var underrunPrev = 0, underrunRecent = 0, lastUnderrunAt = 0.0
    private var startedAt = 0.0
    private var lastWriteSeenAt = 0.0, lastWriteIndexSeen: Int64 = 0
    var onChange: (() -> Void)?

    // producer (capture queue only)
    private var pIndex: Int64 = 0
    private var pRate = 0.0, pChannels = 0
    private var pAnchorIndex: Int64 = 0, pAnchorTime = 0.0
    private var pGeneration = 0
    private var pWindowMin = Double.infinity, pWindowStart = 0.0, pBase: Double?, pDrift = 0.0
    private var pWindows: [(t: Double, lag: Double)] = []
    private var pStartLags: [Double] = []
    private var pStampJumps = 0, pBuffers = 0
    private var pFormat = ""
    private var pLastLappAt = 0.0
    private var pValidFrom: Int64 = 0
    private var pFresh = true                 // set by start(): the next buffer begins a new timeline
    private var driftPpmLocked: Double?   // lock

    init() {
        ring = .allocate(capacity: Self.ringSize); ring.initialize(repeating: 0, count: Self.ringSize)
        scratch = .allocate(capacity: Self.maxFrames); scratch.initialize(repeating: 0, count: Self.maxFrames)
        shared = .allocate(capacity: 1); shared.initialize(to: Shared())
        cache = .allocate(capacity: 1); cache.initialize(to: Shared())
        reader = .allocate(capacity: 1); reader.initialize(to: Reader())
        lk = .allocate(capacity: 1); lk.initialize(to: os_unfair_lock())
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        tickSec = Double(tb.numer) / Double(tb.denom) / 1e9
    }

    static func now() -> Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }

    // MARK: Core Audio helpers

    private static func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// VIRTUALCAM_BUILD §2: the hidden Feed is not in the device list, only TranslateUIDToDevice finds it
    static func deviceID(uid: String) -> AudioObjectID {
        var a = addr(kAudioHardwarePropertyTranslateUIDToDevice)
        var cf = uid as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafeMutablePointer(to: &cf) { q in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<CFString>.size), q, &size, &id) }
        return err == noErr ? id : AudioObjectID(kAudioObjectUnknown)
    }

    private static func u32(_ dev: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32? {
        var a = addr(sel, scope); var v: UInt32 = 0; var size = UInt32(4)
        guard AudioObjectHasProperty(dev, &a), AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }
    private static func rate(_ dev: AudioObjectID) -> Double? {
        var a = addr(kAudioDevicePropertyNominalSampleRate); var v = Float64(0); var size = UInt32(8)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }
    /// device + safety offset + first stream latency, frames, in one scope
    private static func latencyFrames(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> UInt32 {
        var total = (u32(dev, kAudioDevicePropertyLatency, scope) ?? 0) + (u32(dev, kAudioDevicePropertySafetyOffset, scope) ?? 0)
        var a = addr(kAudioDevicePropertyStreams, scope); var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size >= 4 {
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / 4)
            if AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &streams) == noErr, let s = streams.first {
                total += u32(s, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal) ?? 0
            }
        }
        return total
    }

    /// the driver's status property 'mvst' (VIRTUALCAM_BUILD §4), never in the IO proc
    static func driverStatus(_ dev: AudioObjectID) -> [String: Any]? {
        guard dev != AudioObjectID(kAudioObjectUnknown) else { return nil }
        var a = AudioObjectPropertyAddress(mSelector: 0x6D76_7374, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(dev, &a) else { return nil }
        var ref: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &ref) == noErr, let r = ref else { return nil }
        return (r.takeRetainedValue() as? NSDictionary) as? [String: Any]
    }

    static var installed: Bool { deviceID(uid: feedUID) != AudioObjectID(kAudioObjectUnknown) }

    // MARK: on / off

    func setOn(_ on: Bool, _ done: (() -> Void)? = nil) {
        control.async {
            if on { if !self.running { self.start() } } else { self.stop(); self.lock.lock(); self.problem = nil; self.note = nil; self.lock.unlock() }
            DispatchQueue.main.async { self.onChange?(); done?() }
        }
    }
    func shutdown() { control.sync { self.stop() } }

    private func setProblem(_ s: String) {
        lock.lock(); problem = s; lock.unlock()
        NSLog("Webcam Recorder: VMIC: %@", s)
    }

    private func start() {
        lock.lock(); problem = nil; note = nil; lock.unlock()
        listen()
        var dev = Self.deviceID(uid: Self.feedUID), r = "driver"
        if dev == AudioObjectID(kAudioObjectUnknown) {
            let agg = Self.deviceID(uid: Self.aggregateUID)
            if agg != AudioObjectID(kAudioObjectUnknown) { dev = agg; r = "aggregate" }
        }
        guard dev != AudioObjectID(kAudioObjectUnknown) else {
            lock.lock(); route = "none"; lock.unlock()
            setProblem("Mantra VirtualCam driver not installed: its hidden Feed (MantraVirtualCamFeed_UID) is not on this Mac, so VMIC writes nothing. Install it once at a quiet moment from github.com/markoboskoauroville/MANTRA_VIRTUALCAM_DRIVER (./install.sh, your own admin password; Core Audio restarts, about 2 s of silence).")
            return
        }
        // one rate for the Feed and the Mic (one ring in the driver): 48 kHz, set only when it is not so already
        if let rt = Self.rate(dev), abs(rt - Self.outRate) > 0.5 {
            var a = Self.addr(kAudioDevicePropertyNominalSampleRate); var v = Float64(Self.outRate)
            let st = AudioObjectSetPropertyData(dev, &a, 0, nil, 8, &v)
            NSLog("Webcam Recorder: VMIC: Feed rate %.0f → 48000 (%d)", rt, st)
        }
        let actualRate = Self.rate(dev) ?? 0
        guard abs(actualRate - Self.outRate) < 0.5 else { setProblem(String(format: "the Feed runs at %.0f Hz and would not take 48000 Hz.", actualRate)); return }
        // 256 frames (5.3 ms) per cycle
        var bf = UInt32(256)
        var ba = Self.addr(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeOutput)
        _ = AudioObjectSetPropertyData(dev, &ba, 0, nil, 4, &bf)
        let frames = Self.u32(dev, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeOutput) ?? 0
        // the stream format: Float32, 2 channels (BlackHole's model)
        var fa = Self.addr(kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeOutput)
        var asbd = AudioStreamBasicDescription(); var fs = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let fok = AudioObjectGetPropertyData(dev, &fa, 0, nil, &fs, &asbd) == noErr
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32
        guard fok, isFloat else { setProblem("the Feed's stream is not 32-bit float (\(asbd.mBitsPerChannel) bit): VMIC writes Float32 only."); return }
        let ldrv = Double(Self.latencyFrames(dev, kAudioObjectPropertyScopeOutput)
                          + Self.latencyFrames(Self.deviceID(uid: Self.micUID), kAudioObjectPropertyScopeInput)) / Self.outRate * 1000
        Composite.shared.setDriver(ldrv)
        // the reader starts fresh, the producer begins a new timeline with its next buffer
        reader.pointee = Reader()
        pFresh = true
        var pid: AudioDeviceIOProcID?
        let st = AudioDeviceCreateIOProcIDWithBlock(&pid, dev, nil) { [unowned self] _, _, _, out, outTime in
            self.render(out, outTime)
        }
        guard st == noErr, let p = pid else { setProblem("the Feed refused an IO proc (\(st))."); return }
        guard AudioDeviceStart(dev, p) == noErr else {
            AudioDeviceDestroyIOProcID(dev, p)
            setProblem("the Feed would not start."); return
        }
        feedID = dev; procID = p; running = true
        lock.lock()
        route = r; bufferFrames = frames; outChannels = Int(asbd.mChannelsPerFrame); startedAt = Self.now()
        feedFormat = String(format: "%.0f Hz, %d ch Float32, %u frames", actualRate, asbd.mChannelsPerFrame, frames)
        if r == "aggregate" { note = "VMIC writes into the fallback aggregate (BlackHole 2ch): Ableton shares it. The driver is the better route." }
        driverPrev = nil; underrunPrev = 0; underrunRecent = 0
        lock.unlock()
        let t = DispatchSource.makeTimerSource(queue: control)
        t.schedule(deadline: .now() + 0.25, repeating: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume(); timer = t
        NSLog("Webcam Recorder: VMIC feeding %@ (%@, route %@)", Self.feedName, feedFormat, r)
    }

    private func stop() {
        timer?.cancel(); timer = nil
        if let p = procID, feedID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(feedID, p)
            AudioDeviceDestroyIOProcID(feedID, p)
        }
        procID = nil; feedID = AudioObjectID(kAudioObjectUnknown); running = false
        lock.lock(); route = "none"; lock.unlock()
    }

    /// a coreaudiod restart or an install/uninstall gives new object ids: resolve the Feed again
    private func listen() {
        guard !listening else { return }
        listening = true
        var a = Self.addr(kAudioHardwarePropertyDevices)
        _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, control) { [weak self] _, _ in
            guard let self else { return }
            let wanted = UserDefaults.standard.bool(forKey: VirtualMic.onKey)
            let now = VirtualMic.deviceID(uid: VirtualMic.feedUID)
            if self.running && now != self.feedID {
                NSLog("Webcam Recorder: VMIC: the Feed changed (%u → %u), starting again", self.feedID, now)
                self.stop()
                if wanted { self.start() }
            } else if !self.running && wanted && now != AudioObjectID(kAudioObjectUnknown) {
                self.start()
            }
            DispatchQueue.main.async { self.onChange?() }
        }
    }

    // MARK: control (4 times a second)

    private func poll() {
        // the plan → the reader
        let wd = Composite.shared.writeDelayMs / 1000
        let off = Composite.shared.micToPictureSec
        os_unfair_lock_lock(lk); shared.pointee.delaySec = wd; shared.pointee.flashOffsetSec = off; os_unfair_lock_unlock(lk)
        let r = reader.pointee
        let now = Self.now()
        var changed = false
        lock.lock()
        if let d = Self.driverStatus(feedID) {
            driver = d
            let silent = (d["silentReads"] as? NSNumber)?.intValue ?? 0
            let ov = (d["overloads"] as? NSNumber)?.intValue ?? 0
            let gap = (d["gapFrames"] as? NSNumber)?.intValue ?? 0
            if let p = driverPrev, now > p.at {
                silentRate = Double(silent - p.silent) / (now - p.at)
                newOverloads = ov - p.overloads; newGap = gap - p.gap
            }
            driverPrev = (silent, ov, gap, now)
        }
        let u = r.underrunFrames
        if u > underrunPrev { underrunRecent += u - underrunPrev; lastUnderrunAt = now }
        underrunPrev = u
        if now - lastUnderrunAt > 5 { underrunRecent = 0 }
        os_unfair_lock_lock(lk); let w = shared.pointee.writeIndex; os_unfair_lock_unlock(lk)
        if w != lastWriteIndexSeen { lastWriteIndexSeen = w; lastWriteSeenAt = now }
        lock.unlock()
        // Lapp: the newest sample must have arrived before the IO proc wants it
        let ahead = max(r.aheadMax, r.aheadMaxPrev)
        lappUpdate(ahead: ahead)
        let st = summary.state
        if st != lastState { lastState = st; changed = true }
        if changed { DispatchQueue.main.async { self.onChange?() } }
    }
    private var lastState = ""
    private var lappLatest = 0.0

    /// Lapp = p98 of (arrival − first-sample stamp) + how far ahead the IO proc writes + one cycle + 3 ms, rounded up to
    /// 0.5 ms; it only grows while VMIC runs (a new input starts it again), so the sound never moves back and forth
    private func lappUpdate(ahead: Double) {
        lock.lock(); let lags = lagSnapshot; lock.unlock()
        guard lags.count >= 40, ahead > 0 else { return }
        let s = lags.sorted()
        let p98 = s[min(s.count - 1, Int(Double(s.count) * 0.98))]
        let need = ((p98 + ahead) * 1000 + 3)
        let rounded = (need * 2).rounded(.up) / 2
        if rounded > lappLatest + 0.25 || lappLatest == 0 {
            lappLatest = max(lappLatest, rounded)
            Composite.shared.setLapp(lappLatest, measured: true)
        }
    }
    private var lagSnapshot: [Double] = []   // lock

    // MARK: sound in (capture queue): mono, the digital gain, the stamps

    func submit(_ sb: CMSampleBuffer, gain: Float) {
        guard running else { return }
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { return }
        let n = CMSampleBufferGetNumSamples(sb)
        guard n > 0 else { return }
        let arrival = Self.now()
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
        let rate = asbd.mSampleRate
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        guard rate > 1000 else { return }
        if n > monoCap { mono?.deallocate(); mono = .allocate(capacity: n); monoCap = n }
        guard let m = mono, Self.mix(sb, asbd: asbd, frames: n, into: m) else { return }
        if gain != 1 { for i in 0..<n { m[i] *= gain } }
        // a new input or rate: a new timeline
        var newGen = false
        if pFresh || rate != pRate || channels != pChannels {
            pFresh = false; pValidFrom = pIndex
            pRate = rate; pChannels = channels; pAnchorIndex = pIndex; pAnchorTime = pts; newGen = true
            pBase = nil; pDrift = 0; pWindowMin = .infinity; pWindowStart = arrival; pWindows.removeAll()
            pStartLags.removeAll()
            let bits = asbd.mBitsPerChannel, fl = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "float" : "int"
            let text = "\(Int(rate)) Hz, \(channels) ch, \(bits)-bit \(fl)"
            lock.lock(); pFormat = text; driftPpmLocked = nil; lock.unlock()
            control.async { self.lappLatest = 0 }
        } else {
            let expected = pAnchorTime + Double(pIndex - pAnchorIndex) / pRate
            if abs(pts - expected) > 0.002 {     // a gap or a jump of the stamps: place the buffer by its own stamp
                pStampJumps += 1; pAnchorIndex = pIndex; pAnchorTime = pts; newGen = abs(pts - expected) > 0.070
                if newGen { pBase = nil; pDrift = 0; pWindowMin = .infinity; pWindowStart = arrival; pWindows.removeAll() }
                NSLog("Webcam Recorder: VMIC: sound stamp off by %.1f ms, placed by its stamp", (pts - expected) * 1000)
            }
        }
        // into the ring (wrapping)
        var i = 0
        while i < n {
            let at = Int(pIndex & Self.mask)
            let k = min(n - i, Self.ringSize - at)
            (ring + at).update(from: m + i, count: k)
            i += k; pIndex += Int64(k)
        }
        pBuffers += 1
        // drift from the arrival times (LESSONS 49): the lower envelope of (arrival − stamp of the last sample), 10 s windows
        let lag = arrival - (pts + Double(n) / rate)
        pWindowMin = min(pWindowMin, lag)
        if arrival - pWindowStart >= 10 {
            if pBase == nil { pBase = pWindowMin } else {
                let raw = pWindowMin - pBase!
                pDrift += max(-0.001, min(0.001, (raw - pDrift) * 0.2))
            }
            pWindows.append((arrival, pWindowMin)); if pWindows.count > 60 { pWindows.removeFirst() }
            if pWindows.count >= 6 {   // ppm from a straight line through the window minima (1 min and more)
                let t0 = pWindows[0].t
                let xs = pWindows.map { $0.t - t0 }, ys = pWindows.map { $0.lag }
                let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
                var sxy = 0.0, sxx = 0.0
                for (x, y) in zip(xs, ys) { sxy += (x - mx) * (y - my); sxx += (x - mx) * (x - mx) }
                if sxx > 0 { let ppm = (sxy / sxx * 1e6 * 100).rounded() / 100; lock.lock(); driftPpmLocked = ppm; lock.unlock() }
            }
            pWindowMin = .infinity; pWindowStart = arrival
        }
        pStartLags.append(arrival - pts); if pStartLags.count > 400 { pStartLags.removeFirst(pStartLags.count - 400) }
        if arrival - pLastLappAt > 0.5 { pLastLappAt = arrival; let snap = pStartLags; lock.lock(); lagSnapshot = snap; lock.unlock() }
        if newGen { pGeneration += 1 }
        os_unfair_lock_lock(lk)
        shared.pointee.writeIndex = pIndex
        shared.pointee.validFrom = pValidFrom
        shared.pointee.anchorIndex = pAnchorIndex; shared.pointee.anchorTime = pAnchorTime
        shared.pointee.rateIn = pRate; shared.pointee.driftSec = pDrift; shared.pointee.generation = pGeneration
        os_unfair_lock_unlock(lk)
    }
    private var mono: UnsafeMutablePointer<Float>?
    private var monoCap = 0

    /// any PCM layout (interleaved or not; Float32/64, Int16/24/32) → mono Float32 (the mean of the channels)
    private static func mix(_ sb: CMSampleBuffer, asbd: AudioStreamBasicDescription, frames n: Int, into m: UnsafeMutablePointer<Float>) -> Bool {
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
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr else { return false }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = Int(asbd.mBitsPerChannel)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let totalCh = max(1, buffers.reduce(0) { $0 + Int($1.mNumberChannels) })
        for i in 0..<n { m[i] = 0 }
        for buf in buffers {
            guard let d = buf.mData else { continue }
            let per = max(1, Int(buf.mNumberChannels))
            let bytesPer = per > 0 ? Int(buf.mDataByteSize) / max(1, n * per) : 0
            guard bytesPer > 0 else { continue }
            for k in 0..<n {
                for c in 0..<per {
                    let o = (k * per + c) * bytesPer
                    let v: Float
                    if isFloat && bits == 32 { v = d.load(fromByteOffset: o, as: Float.self) }
                    else if isFloat && bits == 64 { v = Float(d.load(fromByteOffset: o, as: Double.self)) }
                    else if bits == 16 { v = Float(d.load(fromByteOffset: o, as: Int16.self)) / 32768 }
                    else if bits == 24 && bytesPer == 3 {
                        let b0 = Int32(d.load(fromByteOffset: o, as: UInt8.self)), b1 = Int32(d.load(fromByteOffset: o + 1, as: UInt8.self))
                        let b2 = Int32(Int8(bitPattern: d.load(fromByteOffset: o + 2, as: UInt8.self)))
                        v = Float(b0 | (b1 << 8) | (b2 << 16)) / 8388608
                    }
                    else if bytesPer == 4 { v = Float(Double(d.load(fromByteOffset: o, as: Int32.self)) / 2147483648) }
                    else { continue }
                    m[k] += v
                }
            }
        }
        if totalCh > 1 { let g = 1 / Float(totalCh); for i in 0..<n { m[i] *= g } }
        return true
    }

    // MARK: the IO proc (real time: no allocation, no waiting, no Objective-C)

    private func render(_ out: UnsafeMutablePointer<AudioBufferList>, _ outTime: UnsafePointer<AudioTimeStamp>) {
        let t0 = mach_absolute_time()
        let r = reader
        if os_unfair_lock_trylock(lk) { cache.pointee = shared.pointee; os_unfair_lock_unlock(lk) }
        let sh = cache.pointee
        let bufs = UnsafeMutableAudioBufferListPointer(out)
        guard bufs.count > 0 else { return }
        let ch0 = max(1, Int(bufs[0].mNumberChannels))
        let n = min(Self.maxFrames, Int(bufs[0].mDataByteSize) / (4 * ch0))
        guard n > 0 else { return }
        r.pointee.cycles += 1
        let hostValid = outTime.pointee.mFlags.contains(.hostTimeValid)
        if !hostValid || sh.rateIn <= 0 || sh.writeIndex == 0 {
            for k in 0..<n { scratch[k] = 0 }
            r.pointee.waitingCycles += 1
            write(bufs, n)
            return
        }
        let nowSec = Double(t0) * tickSec
        let H = Double(outTime.pointee.mHostTime) * tickSec
        let ahead = H - nowSec + Double(n) / Self.outRate
        if nowSec - r.pointee.aheadWindowStart > 3 { r.pointee.aheadMaxPrev = r.pointee.aheadMax; r.pointee.aheadMax = 0; r.pointee.aheadWindowStart = nowSec }
        if ahead > r.pointee.aheadMax { r.pointee.aheadMax = ahead }
        let rateIn = sh.rateIn
        let step = rateIn / Self.outRate
        r.pointee.boxN = step >= 1.5 ? Int(step.rounded()) : 1
        let c0 = H - sh.delaySec                                   // the true capture time of this cycle's first frame
        let T = Double(sh.anchorIndex) + (c0 - sh.anchorTime - sh.driftSec) * rateIn
        let err = r.pointee.pos - T
        r.pointee.lastErrSamples = err
        if !r.pointee.started || r.pointee.generation != sh.generation || abs(err) > 0.003 * rateIn {
            // a jump: 5 ms crossfade from where we were (silence at the start)
            r.pointee.fadeFrom = r.pointee.started ? r.pointee.pos : -1
            r.pointee.fadeLeft = 240
            r.pointee.pos = step == 1 ? T.rounded() : T
            if r.pointee.started { r.pointee.jumps += 1 }
            r.pointee.started = true; r.pointee.generation = sh.generation; r.pointee.correcting = false
        } else {
            // drift: one sample at a time, from 0.25 ms off down to half a sample
            if abs(err) >= 0.00025 * rateIn { r.pointee.correcting = true }
            if r.pointee.correcting {
                if err < -0.5 { r.pointee.pos += 1; r.pointee.drops += 1 }
                else if err > 0.5 { r.pointee.pos -= 1; r.pointee.repeats += 1 }
                else { r.pointee.correcting = false }
            }
        }
        let avail = sh.writeIndex
        let oldest = max(sh.validFrom, avail - Int64(Self.ringSize) + 16384)
        var under = 0, old = 0
        let fadeTotal = 240
        let flash = sh.flash
        let flashOff = sh.flashOffsetSec
        for k in 0..<n {
            let p = r.pointee.pos + Double(k) * step
            var v = sample(p, avail, oldest, &under, &old)
            if r.pointee.fadeLeft > 0 {
                let w = Float(fadeTotal - r.pointee.fadeLeft) / Float(fadeTotal)
                let from: Float = r.pointee.fadeFrom < 0 ? 0 : sample(r.pointee.fadeFrom + Double(k) * step, avail, oldest, &under, &old)
                v = from * (1 - w) + v * w
                r.pointee.fadeLeft -= 1
            }
            if flash {
                // test only: a 3 ms click at every whole second of the picture's clock (the same moments VCAM flashes)
                let tp = c0 + Double(k) / Self.outRate + flashOff
                let f = tp - floor(tp)
                if f < 0.003 { v = 0.7 * Float(sin(2 * Double.pi * 2000 * f)); if f < 1.0 / Self.outRate { r.pointee.flashes += 1 } }
            }
            scratch[k] = v
        }
        if r.pointee.fadeLeft > 0 && r.pointee.fadeFrom >= 0 { r.pointee.fadeFrom += Double(n) * step }
        if under > 0 { r.pointee.underrunFrames += under; r.pointee.underrunCycles += 1 }
        r.pointee.tooOldFrames += old
        r.pointee.lastFillSec = (Double(avail) - r.pointee.pos) / rateIn
        r.pointee.pos += Double(n) * step
        r.pointee.frames += n
        r.pointee.lastHostSec = H
        write(bufs, n)
        let us = Double(mach_absolute_time() - t0) * tickSec * 1e6
        r.pointee.procSumUs += us
        if us > r.pointee.procMaxUs { r.pointee.procMaxUs = us }
    }

    @inline(__always) private func sample(_ p: Double, _ avail: Int64, _ oldest: Int64, _ under: inout Int, _ old: inout Int) -> Float {
        let fl = floor(p)
        let i = Int64(fl)
        let f = Float(p - fl)
        if i < oldest { old += 1; return 0 }
        if i >= avail || (f > 0 && i + 1 >= avail) { under += 1; return 0 }
        // v35: an input faster than the Feed (96 kHz → 48 kHz) is averaged over the samples one output frame spans
        // (a box low-pass against aliasing); slower inputs (44.1 kHz) are interpolated
        let boxN = reader.pointee.boxN
        if boxN > 1, i + Int64(boxN) <= avail {
            var sum: Float = 0
            for j in 0..<boxN { sum += ring[Int((i + Int64(j)) & Self.mask)] }
            return sum / Float(boxN)
        }
        let a = ring[Int(i & Self.mask)]
        return f > 0 ? a * (1 - f) + ring[Int((i + 1) & Self.mask)] * f : a
    }

    @inline(__always) private func write(_ bufs: UnsafeMutableAudioBufferListPointer, _ n: Int) {
        for b in bufs {
            guard let d = b.mData else { continue }
            let ch = max(1, Int(b.mNumberChannels))
            let frames = min(n, Int(b.mDataByteSize) / (4 * ch))
            let o = d.assumingMemoryBound(to: Float.self)
            for k in 0..<frames { let v = scratch[k]; for c in 0..<ch { o[k * ch + c] = v } }
        }
    }

    // MARK: API

    /// POST /virtualmic {processorLatencyMs, flash (test only), composite (test only)}; "on" is setOn
    func configure(_ b: [String: Any]) -> String? {
        if let v = (b["processorLatencyMs"] as? NSNumber)?.doubleValue {
            guard v >= 0, v <= 2000 else { return "processorLatencyMs must be 0 … 2000" }
            Composite.shared.setProcessor(v)
        }
        if let f = b["flash"] as? Bool { os_unfair_lock_lock(lk); shared.pointee.flash = f; os_unfair_lock_unlock(lk) }
        if let c = b["composite"] as? Bool { Composite.shared.setBypass(!c) }   // test only: false = no holds (the "before")
        return nil
    }
    var flashOn: Bool { os_unfair_lock_lock(lk); defer { os_unfair_lock_unlock(lk) }; return shared.pointee.flash }

    /// one line for the key's tooltip and the red note: off | feeding | waiting | problem
    var summary: (state: String, text: String?) {
        lock.lock(); defer { lock.unlock() }
        if let p = problem { return ("problem", "VMIC: " + p) }
        guard running else { return ("off", nil) }
        let now = Self.now()
        if lastWriteIndexSeen == 0 || now - lastWriteSeenAt > 1.0 {
            return ("waiting", "VMIC: waiting for sound from the chosen input (none chosen, or it sends nothing).")
        }
        if underrunRecent > 0 && now - startedAt > 3 {
            return ("problem", "VMIC: the sound came too late for the Feed (\(underrunRecent) frames of silence in the last 5 s).")
        }
        return ("feeding", nil)
    }

    private static func r1(_ x: Double) -> Double { (x * 10).rounded() / 10 }

    /// GET /virtualmic/status
    func status(wanted: Bool) -> [String: Any] {
        let sum = summary
        let r = reader.pointee
        os_unfair_lock_lock(lk); let sh = shared.pointee; os_unfair_lock_unlock(lk)
        lock.lock(); defer { lock.unlock() }
        let installedNow = Self.installed
        let micDev = Self.deviceID(uid: Self.micUID)
        var out: [String: Any] = [
            "on": wanted, "state": sum.state, "text": vnn(sum.text), "feeding": sum.state == "feeding",
            "driverInstalled": installedNow, "route": route, "feed": Self.feedName, "feedUID": Self.feedUID,
            "microphone": Self.micName, "micFound": micDev != AudioObjectID(kAudioObjectUnknown),
            "feedFormat": feedFormat, "bufferFrames": bufferFrames, "problem": vnn(problem), "note": vnn(note),
            "input": ["format": pFormat, "rate": sh.rateIn, "generation": sh.generation, "buffers": pBuffers, "stampJumps": pStampJumps,
                      "samplesWritten": sh.writeIndex] as [String: Any],
            "gainDigitalDB": Gain.digitalDB,
            "soundDelayMs": Self.r1(sh.delaySec * 1000 + 0),
            "audioHoldMs": Self.r1(Composite.shared.audioHoldMs),
            "ringFillMs": Self.r1(r.lastFillSec * 1000),
            "readErrorMs": sh.rateIn > 0 ? (r.lastErrSamples / sh.rateIn * 100_000).rounded() / 100 : 0,
            "drift": ["ppm": vnn(driftPpmLocked), "correctionMs": (sh.driftSec * 100_000).rounded() / 100,
                      "samplesDropped": r.drops, "samplesRepeated": r.repeats] as [String: Any],
            "jumps": r.jumps,
            "underruns": ["frames": r.underrunFrames, "cycles": r.underrunCycles, "recentFrames": underrunRecent] as [String: Any],
            "tooOldFrames": r.tooOldFrames,
            "cycles": r.cycles, "framesOut": r.frames, "waitingCycles": r.waitingCycles,
            "aheadMs": Self.r1(max(r.aheadMax, r.aheadMaxPrev) * 1000),
            "ioProcUs": ["max": Self.r1(r.procMaxUs), "mean": r.cycles > 0 ? Self.r1(r.procSumUs / Double(r.cycles)) : 0] as [String: Any],
            "flash": sh.flash, "clicks": r.flashes,
            "composite": Composite.shared.status(),
            "zoom": "In Zoom: Audio → Microphone → Mantra VirtualCam (with Camera → OBS Virtual Camera); Original sound for musicians on, automatic volume off",
        ]
        var drv: [String: Any] = [:]
        for k in ["fillMs", "silentReads", "overloads", "gapFrames", "micClients", "feedClients", "writeCycles", "readCycles", "sampleRate", "clockRatio", "latencyFrames", "safetyOffsetFrames"] {
            if let v = driver[k] { drv[k] = v }
        }
        drv["silentReadsPerSec"] = Self.r1(silentRate); drv["newOverloads"] = newOverloads; drv["newGapFrames"] = newGap
        out["driver"] = drv
        if running { out["secondsFeeding"] = Int(Self.now() - startedAt) }
        return out
    }
}

private func vnn(_ x: Any?) -> Any { x ?? NSNull() }
