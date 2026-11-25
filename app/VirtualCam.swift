import AppKit
import CoreImage
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation

// v32, 25.11.2026 = VC-1 of Mantra VirtualCam (docs/VIRTUALCAM_PLAN.md). Marko: "I want that our app web cam recorder stream
// through OBS virtual camera with all audio and delay processing ... you need a composite for plugin delays so my students
// always see me playing in sync." and "We are not going to use paid Apple account for now, so the name states obvious".
//
// The picture as chosen (whole frame, or the 9:16 slice pillarboxed) goes into the sink stream of OBS's approved camera
// extension; Zoom lists it as "OBS Virtual Camera". OBS itself does not have to run.
// Source: Marko's own MANTRA_VIRTUAL_CAM Sources/VirtualCamera.swift (v1-v5, 27.10.2026: sink lookup, CMSimpleQueue,
// IOSurface pool, oldest-out when the queue is full), its LESSONS 2-3 (the sink = direction 0 "Sink", 1920x1080 only; a
// reader of the OBS camera always with N frames and a deadline). New here: the sink's format read from the stream, the
// capture time stamps kept, a bounded hold ring (the video half of the composite delay), a 60 fps cadence (frames are
// repeated, never invented), owner-conflict and missing-extension detection, and everything off the capture queue:
// the capture queue only hands over a retained buffer (at most two in flight), so VCAM can never slow a take or the preview.
//
//   hold = sync.videoDelayMs.<video id> + virtualcam.trimMs + extraDelayMs   (extraDelayMs = the audio path's latency:
//   set by the API now, filled by the PatchWork/driver chain in v33), clamped to 0 … virtualcam.maxHoldMs (400 ms default)
final class VirtualCam {
    static let obsName = "OBS Virtual Camera"
    static let onKey = "virtualcam.on", trimKey = "virtualcam.trimMs", capKey = "virtualcam.maxHoldMs"
    static let defaultCapMs = 400.0, hardCapMs = 1000.0
    static let cadence = 60.0

    private struct Frame { let pb: CVPixelBuffer; let pts: Double; let ready: Double }

    private let lock = NSLock()
    private let convertQueue = DispatchQueue(label: "webcamviewer.vcam.convert", qos: .userInitiated)
    private let sendQueue = DispatchQueue(label: "webcamviewer.vcam.send", qos: .userInteractive)
    private let ci = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
    private var timer: DispatchSourceTimer?

    // the sink (send queue)
    private var device: CMIOObjectID = 0
    private var sink: CMIOStreamID = 0
    private var queue: CMSimpleQueue?
    private var format: CMVideoFormatDescription?

    // shared (lock)
    private(set) var feeding = false
    private var pool: CVPixelBufferPool?
    private var outW = 1920, outH = 1080
    private var inFlight = 0
    private var ring: [Frame] = []
    private var lastSent: Frame?
    private var lastSendAt = 0.0
    private var stampOn = false
    private var extraMs = 0.0
    private var holdMs = 0.0, requestedMs = 0.0, videoDelayMs = 0.0, trimMs = 0.0, capMs = VirtualCam.defaultCapMs
    var cameraID: String? { get { lock.lock(); defer { lock.unlock() }; return camID } set { lock.lock(); camID = newValue; lock.unlock() } }
    private var camID: String?
    private var received = 0, busyDrops = 0, poolDrops = 0, ringDrops = 0, queueFullDrops = 0, skipped = 0
    private var sentTotal = 0, sentUnique = 0
    private var latencies: [Double] = [], processing: [Double] = [], arrivals: [Double] = [], converts: [Double] = []
    private var lastFreshAt = 0.0, lastFreshPTS = 0.0, period = 1.0 / 30
    private var fpsUnique = 0.0, fpsSend = 0.0, fpsAt = 0.0, fpsU0 = 0, fpsS0 = 0
    private var stalledSince: Double?
    private(set) var conflict = false
    private var problem: String?          // the reason VCAM is not feeding (missing extension, no sink, …)
    private var note: String?             // a calm remark (the hold was capped, OBS was running at launch)
    private var sinkName: String?, sinkFormat: String?, formatOK = true, queueCapacity = 0
    private var probed: (found: Bool, at: Double)?
    private var extensionInfo: (version: String?, state: String?)? = nil
    private var startedAt = 0.0
    var onChange: (() -> Void)?

    init() {
        lock.lock(); capMs = Self.storedCap; lock.unlock()
        DispatchQueue.global(qos: .utility).async { self.readExtension() }
    }

    static var storedCap: Double {
        let v = UserDefaults.standard.double(forKey: capKey)
        return v > 0 ? min(hardCapMs, v) : defaultCapMs
    }
    static func now() -> Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }

    // MARK: CMIO helpers (MANTRA_VIRTUAL_CAM VirtualCamera.swift)

    private func addr(_ sel: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(sel), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }
    private func ids(_ obj: CMIOObjectID, _ sel: Int) -> [CMIOObjectID] {
        var a = addr(sel); var size: UInt32 = 0; var used: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == 0, size > 0 else { return [] }
        var out = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        _ = CMIOObjectGetPropertyData(obj, &a, 0, nil, size, &used, &out); return out
    }
    private func name(_ obj: CMIOObjectID) -> String {
        var a = addr(kCMIOObjectPropertyName); var s: Unmanaged<CFString>?; var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<CFString?>.size), &used, &s) == 0, let v = s else { return "" }
        return v.takeRetainedValue() as String
    }
    private func u32(_ obj: CMIOObjectID, _ sel: Int) -> UInt32? {
        var a = addr(sel); var v: UInt32 = 0; var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(obj, &a, 0, nil, 4, &used, &v) == 0 else { return nil }
        return v
    }
    private func findDevice() -> CMIOObjectID? {
        ids(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices).first { name($0) == Self.obsName }
    }
    /// the sink: direction 0 (output into the device) and "Sink" in its name (OBS 30+ "OBS Camera Extension Stream Sink")
    private func findSink(_ dev: CMIOObjectID) -> CMIOStreamID? {
        let streams = ids(dev, kCMIODevicePropertyStreams)
        return streams.first { u32($0, kCMIOStreamPropertyDirection) == 0 && name($0).lowercased().contains("sink") }
            ?? streams.first { name($0).lowercased().contains("sink") }
    }

    /// `systemextensionsctl list` (read only): the OBS camera extension's version and state
    private func readExtension() {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/systemextensionsctl"); p.arguments = ["list"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        var info: (version: String?, state: String?) = (nil, nil)
        if (try? p.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            if let line = text.components(separatedBy: "\n").first(where: { $0.contains("com.obsproject.obs-studio.mac-camera-extension") }) {
                if let r = line.range(of: "mac-camera-extension ("), let e = line[r.upperBound...].firstIndex(of: ")") {
                    info.version = String(line[r.upperBound..<e]).components(separatedBy: "/").first
                }
                if let r = line.range(of: "["), let e = line.range(of: "]", range: r.upperBound..<line.endIndex) {
                    info.state = String(line[r.upperBound..<e.lowerBound])
                } else { info.state = "listed" }
            } else { info.state = "not installed" }
        }
        lock.lock(); extensionInfo = info; lock.unlock()
    }

    private func missingText() -> String {
        lock.lock(); let ext = extensionInfo; lock.unlock()
        if ext?.state == "not installed" {
            return "OBS Virtual Camera not found: OBS Studio (with its camera extension) is not installed on this Mac."
        }
        if let s = ext?.state, !s.contains("activated enabled") {
            return "OBS Virtual Camera not found: its camera extension is \(s), not approved. System Settings → General → Login Items & Extensions → Camera Extensions → OBS."
        }
        return "OBS Virtual Camera not found: OBS's camera extension is not installed or not approved (System Settings → General → Login Items & Extensions → Camera Extensions)."
    }

    // MARK: on / off (main thread calls)

    /// `auto` = the remembered state at launch: never take the camera from OBS while OBS runs
    func setOn(_ on: Bool, auto: Bool = false, _ done: (() -> Void)? = nil) {
        sendQueue.async {
            if on {
                if self.feeding && !self.conflict { DispatchQueue.main.async { done?() }; return }
                if self.feeding { self.stopSink() }   // a press while another feeder holds it: take it back (his press)
                if auto && Self.obsRunning {
                    self.lock.lock()
                    self.problem = nil
                    self.note = "OBS is running, so VCAM did not take OBS Virtual Camera at launch. Press VCAM to feed it."
                    self.lock.unlock()
                } else { self.startSink() }
            } else {
                self.stopSink()
                self.lock.lock(); self.problem = nil; self.note = nil; self.lock.unlock()
            }
            DispatchQueue.main.async { self.onChange?(); done?() }
        }
    }

    func shutdown() { sendQueue.sync { self.stopSink() } }

    static var obsRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.obsproject.obs-studio").isEmpty }

    private func startSink() {
        lock.lock(); problem = nil; note = nil; conflict = false; stalledSince = nil; lock.unlock()
        guard let dev = findDevice() else { setProblem(missingText()); probed = (false, Self.now()); return }
        probed = (true, Self.now())
        guard let s = findSink(dev) else { setProblem("OBS Virtual Camera has no sink stream (OBS changed its camera extension?). VCAM cannot feed it."); return }
        var w = 1920, h = 1080, fmtText = "1920x1080 BGRA", ok = true
        var a = addr(kCMIOStreamPropertyFormatDescription); var fd: Unmanaged<CMFormatDescription>?; var used: UInt32 = 0
        if CMIOObjectGetPropertyData(s, &a, 0, nil, UInt32(MemoryLayout<CMFormatDescription?>.size), &used, &fd) == 0, let f = fd?.takeRetainedValue() {
            let d = CMVideoFormatDescriptionGetDimensions(f)
            let sub = CMFormatDescriptionGetMediaSubType(f)
            w = Int(d.width); h = Int(d.height)
            ok = sub == kCVPixelFormatType_32BGRA
            fmtText = "\(w)x\(h) " + (ok ? "BGRA" : Self.fourCC(sub))
        }
        guard ok, w > 0, h > 0 else { setProblem("OBS Virtual Camera's sink wants \(fmtText); VCAM makes BGRA only."); return }
        var q: Unmanaged<CMSimpleQueue>?
        guard CMIOStreamCopyBufferQueue(s, { _, _, _ in }, nil, &q) == 0, let qq = q?.takeRetainedValue()
        else { setProblem("OBS Virtual Camera's sink refused its queue."); return }
        guard CMIODeviceStartStream(dev, s) == 0 else { setProblem("OBS Virtual Camera's sink would not start."); return }
        device = dev; sink = s; queue = qq; format = nil
        let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                    kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                                    kCVPixelBufferMetalCompatibilityKey as String: true]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
        lock.lock()
        pool = p; outW = w; outH = h; sinkName = name(s); sinkFormat = fmtText; formatOK = ok
        queueCapacity = Int(CMSimpleQueueGetCapacity(qq))
        ring.removeAll(); lastSent = nil; lastSendAt = 0; feeding = true; startedAt = Self.now()
        received = 0; busyDrops = 0; poolDrops = 0; ringDrops = 0; queueFullDrops = 0; skipped = 0; sentTotal = 0; sentUnique = 0
        latencies.removeAll(); processing.removeAll(); arrivals.removeAll(); converts.removeAll(); lastFreshAt = 0; lastFreshPTS = 0; period = 1.0 / 30; fpsUnique = 0; fpsSend = 0; fpsAt = Self.now(); fpsU0 = 0; fpsS0 = 0
        lock.unlock()
        refreshHold()
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: sendQueue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(8_333_333), leeway: .microseconds(500))   // 120 Hz checks, 60 fps sends
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume(); timer = t
        NSLog("Webcam Recorder: VCAM feeding %@ (%@, queue %ld)", Self.obsName, fmtText, queueCapacity)
    }

    private func setProblem(_ s: String) {
        lock.lock(); problem = s; feeding = false; lock.unlock()
        NSLog("Webcam Recorder: VCAM: %@", s)
    }

    private func stopSink() {
        timer?.cancel(); timer = nil
        if sink != 0 { CMIODeviceStopStream(device, sink) }
        sink = 0; device = 0; queue = nil; format = nil
        lock.lock()
        feeding = false; conflict = false; stalledSince = nil; ring.removeAll(); lastSent = nil
        if let p = pool { CVPixelBufferPoolFlush(p, [.excessBuffers]) }
        pool = nil
        lock.unlock()
    }

    // MARK: frames in (capture queue: O(1), never waits)

    func submit(_ pb: CVPixelBuffer, pts: CMTime, slice: Bool) {
        lock.lock()
        guard feeding else { lock.unlock(); return }
        received += 1
        guard inFlight < 2 else { busyDrops += 1; lock.unlock(); return }
        inFlight += 1
        let stamp = stampOn
        let t = CMTimeGetSeconds(pts), arrived = Self.now()
        arrivals.append((arrived - t) * 1000); if arrivals.count > 120 { arrivals.removeFirst(arrivals.count - 120) }
        lock.unlock()
        convertQueue.async { self.convert(pb, t, arrived, slice, stamp) }
    }

    private var ringCapFrames: Int { Int(((capMs + 60) / 1000 * Self.cadence).rounded(.up)) + 3 }   // lock held

    /// the frame fitted into the sink's 1920x1080 (aspect kept, black bars, Lanczos), the slice = the same middle 9:16 strip
    /// as Slicer, pillarboxed; one resample from the camera's own pixels
    private func convert(_ src: CVPixelBuffer, _ t: Double, _ arrived: Double, _ slice: Bool, _ stamp: Bool) {
        defer { lock.lock(); inFlight -= 1; lock.unlock() }
        lock.lock(); let pool = self.pool; let W = outW, H = outH; let cap = ringCapFrames; lock.unlock()
        guard let pool else { return }
        var made: CVPixelBuffer?
        let aux = [kCVPixelBufferPoolAllocationThresholdKey as String: cap + 6] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, aux, &made) == kCVReturnSuccess, let out = made
        else { lock.lock(); poolDrops += 1; lock.unlock(); return }
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        var img = CIImage(cvPixelBuffer: src)
        var sw = w
        if slice {
            sw = Slicer.stripWidth(w: w, h: h)
            let x0 = CGFloat((w - sw) / 2)
            img = img.cropped(to: CGRect(x: x0, y: 0, width: CGFloat(sw), height: CGFloat(h)))
                .transformed(by: CGAffineTransform(translationX: -x0, y: 0))
        }
        var k = min(CGFloat(W) / CGFloat(max(1, sw)), CGFloat(H) / CGFloat(max(1, h)))
        while k < 0.5 { img = Slicer.lanczos(img, 0.5); k *= 2 }   // the Slicer's rule: no single jump over 2x
        if abs(k - 1) > 0.0001 { img = Slicer.lanczos(img, k) }
        let e = img.extent
        img = img.transformed(by: CGAffineTransform(translationX: -e.minX + ((CGFloat(W) - e.width) / 2).rounded(),
                                                    y: -e.minY + ((CGFloat(H) - e.height) / 2).rounded()))
        let frame = CGRect(x: 0, y: 0, width: W, height: H)
        var canvas = img.cropped(to: frame).composited(over: CIImage(color: CIColor.black).cropped(to: frame))
        if stamp { canvas = Self.stamp(t, over: canvas, height: H) }
        ci.render(canvas, to: out, bounds: frame, colorSpace: nil)
        Slicer.tagColour(out, like: src)
        let ready = Self.now()
        lock.lock()
        ring.append(Frame(pb: out, pts: t, ready: ready))
        processing.append((ready - t) * 1000); if processing.count > 120 { processing.removeFirst(processing.count - 120) }
        converts.append((ready - arrived) * 1000); if converts.count > 120 { converts.removeFirst(converts.count - 120) }
        while ring.count > cap { ring.removeFirst(); ringDrops += 1 }
        let immediate = holdMs <= 0
        lock.unlock()
        if immediate { sendQueue.async { self.tick() } }   // no hold: out at once, not at the next check
    }

    /// test only (POST /virtualcam {"stamp": true}): the capture time in µs (40 bits) as squares along the top-left edge,
    /// after a white and a black reference square, so a reader of "OBS Virtual Camera" can measure the whole path
    static func stamp(_ t: Double, over img: CIImage, height: Int) -> CIImage {
        let us = UInt64(max(0, t) * 1_000_000) & ((UInt64(1) << 40) - 1)
        var bits: [Bool] = [true, false]
        for i in stride(from: 39, through: 0, by: -1) { bits.append((us >> UInt64(i)) & 1 == 1) }
        var px = [UInt8](); px.reserveCapacity(bits.count * 4)
        for b in bits { let v: UInt8 = b ? 255 : 0; px += [v, v, v, 255] }   // BGRA
        let row = CIImage(bitmapData: Data(px), bytesPerRow: bits.count * 4, size: CGSize(width: bits.count, height: 1),
                          format: .BGRA8, colorSpace: nil)
        let s: CGFloat = 24
        let bar = row.samplingNearest().transformed(by: CGAffineTransform(scaleX: s, y: s))
            .transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(height) - s))
        return bar.composited(over: img)
    }

    // MARK: frames out (send queue)

    /// the hold of the composite delay, from the stored values (refreshed 4 times a second)
    private var holdAt = 0.0
    private func refreshHold() {
        let d = UserDefaults.standard
        lock.lock(); let id = camID; let extra = extraMs; lock.unlock()
        let video = id.map { Sync.videoDelayMs($0) } ?? 0
        let trim = d.object(forKey: Self.trimKey).flatMap { ($0 as? NSNumber)?.doubleValue } ?? 0
        let cap = Self.storedCap
        let req = video + trim + extra
        lock.lock()
        videoDelayMs = video; trimMs = trim; capMs = cap; requestedMs = req
        holdMs = min(max(0, req), cap)
        lock.unlock()
        holdAt = Self.now()
    }

    private func tick() {
        guard let q = queue else { return }
        let now = Self.now()
        if now - holdAt > 0.25 { refreshHold() }
        lock.lock()
        let hold = holdMs / 1000
        var pick: Int?
        for (i, f) in ring.enumerated() where f.pts + hold <= now { pick = i }
        var fresh: Frame?
        if let p = pick {
            let f = ring[p]; fresh = f; skipped += p; ring.removeFirst(p + 1); lastSent = f
            if lastFreshPTS > 0 { period = min(0.2, max(0.008, 0.9 * period + 0.1 * (f.pts - lastFreshPTS))) }
            lastFreshPTS = f.pts; lastFreshAt = now
        }
        // a repeat fills a gap of the input (30 fps in = 60 out); none when the next picture is due within 8 ms; a
        // stalled input keeps the 60 fps by repeats
        let sinceFresh = now - lastFreshAt
        let repeatDue = now - lastSendAt >= 0.016 && (now + 0.008 < lastFreshAt + period || sinceFresh > period * 1.5)
        let send = fresh ?? (repeatDue ? lastSent : nil)
        lock.unlock()
        guard let f = send else { return }
        if format == nil || !CMVideoFormatDescriptionMatchesImageBuffer(format!, imageBuffer: f.pb) {
            format = nil
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: f.pb, formatDescriptionOut: &format)
        }
        guard let fd = format else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(Self.cadence)),
                                        presentationTimeStamp: CMTime(seconds: now, preferredTimescale: 1_000_000_000),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: f.pb, formatDescription: fd, sampleTiming: &timing, sampleBufferOut: &sb)
        guard let s = sb else { return }
        // the sink's reader is behind: the oldest goes (VirtualCamera.swift). A queue that stays full for 0.5 s is not read
        // at all: OBS's own Start Virtual Camera (or another app) is the extension's last feeder now. We never fight it.
        let full = CMSimpleQueueGetCount(q) >= CMSimpleQueueGetCapacity(q)
        if full, let old = CMSimpleQueueDequeue(q) { Unmanaged<CMSampleBuffer>.fromOpaque(old).release() }
        CMSimpleQueueEnqueue(q, element: Unmanaged.passRetained(s).toOpaque())
        let after = Self.now()
        var changed = false
        lock.lock()
        lastSendAt = now
        sentTotal += 1
        if full { queueFullDrops += 1; if stalledSince == nil { stalledSince = now } } else { stalledSince = nil }
        let stalled = stalledSince.map { now - $0 > 0.5 } ?? false
        if stalled != conflict { conflict = stalled; changed = true }
        if fresh != nil {
            sentUnique += 1
            latencies.append((after - f.pts) * 1000); if latencies.count > 120 { latencies.removeFirst(latencies.count - 120) }
        }
        if now - fpsAt >= 1 {
            fpsUnique = Double(sentUnique - fpsU0) / (now - fpsAt); fpsSend = Double(sentTotal - fpsS0) / (now - fpsAt)
            fpsU0 = sentUnique; fpsS0 = sentTotal; fpsAt = now
        }
        lock.unlock()
        if changed {
            NSLog("Webcam Recorder: VCAM %@", stalled ? "another feeder owns OBS Virtual Camera" : "OBS Virtual Camera reads us again")
            DispatchQueue.main.async { self.onChange?() }
        }
    }

    // MARK: API

    /// POST /virtualcam {extraDelayMs, maxHoldMs, trimMs, stamp}; "on" is setOn
    func configure(_ b: [String: Any]) -> String? {
        if let v = (b["maxHoldMs"] as? NSNumber)?.doubleValue {
            guard v >= 0, v <= Self.hardCapMs else { return "maxHoldMs must be 0 … \(Int(Self.hardCapMs))" }
            UserDefaults.standard.set(v, forKey: Self.capKey)
        }
        if let v = (b["trimMs"] as? NSNumber)?.doubleValue {
            guard abs(v) <= 1000 else { return "trimMs must be -1000 … 1000" }
            UserDefaults.standard.set((v * 10).rounded() / 10, forKey: Self.trimKey)
        }
        lock.lock()
        if let v = (b["extraDelayMs"] as? NSNumber)?.doubleValue { extraMs = max(-1000, min(1000, v)) }
        if let s = b["stamp"] as? Bool { stampOn = s }
        lock.unlock()
        sendQueue.async { self.refreshHold() }
        return nil
    }

    private static func median(_ a: [Double]) -> Double? {
        guard !a.isEmpty else { return nil }
        let s = a.sorted(); return s[s.count / 2]
    }
    private static func r1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
    static func fourCC(_ c: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((c >> $0) & 0xFF) }, encoding: .ascii) ?? "\(c)"
    }

    /// GET /virtualcam/status
    func status(wanted: Bool) -> [String: Any] {
        // not feeding: look the sink up again (at most every 3 s), so sinkFound is true when it is there
        lock.lock(); let isFeeding = feeding; lock.unlock()
        let found: Bool = isFeeding || sendQueue.sync { () -> Bool in
            if self.probed.map({ Self.now() - $0.at > 3 }) ?? true {
                if let dev = self.findDevice() {
                    let s = self.findSink(dev)
                    self.probed = (s != nil, Self.now())
                    self.lock.lock(); if let s { self.sinkName = self.name(s) }; self.lock.unlock()
                } else { self.probed = (false, Self.now()) }
            }
            return self.probed?.found ?? false
        }
        lock.lock(); defer { lock.unlock() }
        let capped = requestedMs > capMs + 0.05
        var warnings: [String] = []
        if capped { warnings.append(String(format: "The picture delay asked is %.1f ms, over the VCAM limit of %.0f ms: held %.0f ms. Raise it with POST /virtualcam {\"maxHoldMs\"} (memory: about 8.3 MB per held frame).", requestedMs, capMs, holdMs)) }
        if requestedMs < -0.05 { warnings.append(String(format: "The picture delay asked is %.1f ms (negative): the picture cannot be earlier than the camera, held 0 ms.", requestedMs)) }
        let conflictText = conflict ? "Another program feeds OBS Virtual Camera now (OBS's own Start Virtual Camera?). VCAM does not fight it: stop that one, then press VCAM to feed it again." : nil
        let obs = Self.obsRunning
        let lat = Self.median(latencies)
        var out: [String: Any] = [
            "on": wanted, "feeding": feeding && !conflict, "sinkFound": found, "camera": Self.obsName,
            "sink": nn2(sinkName), "sinkFormat": nn2(sinkFormat), "formatOK": formatOK, "queueCapacity": queueCapacity,
            "ownerConflict": conflict, "conflictText": nn2(conflictText), "obsRunning": obs,
            "problem": nn2(problem), "note": nn2(note), "warnings": warnings,
            "framesReceived": received, "framesSent": sentTotal, "uniqueFramesSent": sentUnique,
            "fps": Self.r1(fpsUnique), "sendFps": Self.r1(fpsSend),
            "latencyMs": nn2(lat.map(Self.r1)), "latencyWithoutHoldMs": nn2(lat.map { Self.r1($0 - holdMs) }),
            "processingMs": nn2(Self.median(processing).map(Self.r1)),
            "arrivalMs": nn2(Self.median(arrivals).map(Self.r1)), "convertMs": nn2(Self.median(converts).map(Self.r1)),
            "inputPeriodMs": Self.r1(period * 1000),
            "delay": ["videoDelayMs": videoDelayMs, "trimMs": trimMs, "extraDelayMs": extraMs, "requestedMs": Self.r1(requestedMs),
                      "appliedMs": Self.r1(holdMs), "maxHoldMs": capMs, "capped": capped,
                      "formula": "sync.videoDelayMs.<video id> + virtualcam.trimMs + extraDelayMs (audio path, v33)"] as [String: Any],
            "delayApplied": Self.r1(holdMs),
            "droppedFrames": busyDrops + poolDrops + ringDrops,
            "drops": ["converterBusy": busyDrops, "poolLimit": poolDrops, "ringOverflow": ringDrops, "sinkQueueFull": queueFullDrops,
                      "skippedInRing": skipped] as [String: Any],
            "ringFrames": ring.count, "ringMB": Self.r1(Double(ring.count * outW * outH * 4) / 1_048_576),
            "stamp": stampOn,
            "extensionVersion": nn2(extensionInfo?.version), "extensionState": nn2(extensionInfo?.state),
            "recommendedCapture": "1920x1080 · yuvs · 60 (the UGREEN's cleanest mode, LESSONS 55; the sink is 1920x1080 at 60)",
            "zoom": "In Zoom: Video → Camera → OBS Virtual Camera",
        ]
        if feeding { out["secondsFeeding"] = Int(Self.now() - startedAt) }
        return out
    }

    /// one line for the key's tooltip and the red note
    var summary: (state: String, text: String?) {
        lock.lock(); defer { lock.unlock() }
        if conflict { return ("conflict", "VCAM: another program feeds OBS Virtual Camera now. VCAM does not fight it; press VCAM off and on to take it back.") }
        if let p = problem { return ("problem", "VCAM: " + p) }
        if feeding { return ("feeding", nil) }
        if let n = note { return ("waiting", "VCAM: " + n) }
        return ("off", nil)
    }
}

private func nn2(_ x: Any?) -> Any { x ?? NSNull() }
