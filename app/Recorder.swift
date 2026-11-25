import AVFoundation
import CoreVideo
import Darwin
import VideoToolbox

enum RecordQuality: String, CaseIterable {
    case low, mid, high

    var title: String { rawValue.uppercased() }
    var baselineMbps: Double {
        switch self { case .low: return 10; case .mid: return 25; case .high: return 50 }
    }

    /// LOW / MID / HIGH are defined at 1920×1080 and 30 FPS, then scale by pixels and frame rate.
    func bitrate(width: Int, height: Int, fps: Int32) -> Int {
        let scale = (Double(width * height) / (1920 * 1080)) * (Double(fps) / 30)
        return max(1_000_000, Int((baselineMbps * 1_000_000 * scale).rounded()))
    }
}

/*
 * The crash-safe helper-process muxing design is adapted from OBS Studio's
 * plugins/obs-ffmpeg/ffmpeg-mux (local OBS source, commit 48b876374).
 *
 * Copyright (c) 2023 Lain Bailey <lain@obsproject.com>
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */
// The final MKV exists from the first frame. Like OBS's ffmpeg-mux helper, a separate process continuously drains
// encoded packets into Matroska. Clusters are flushed every second, with no post-stop remux.
final class Recorder {
    let url: URL
    let fps: Int32
    let quality: RecordQuality
    let width: Int
    let height: Int
    let bitrate: Int
    private let process: Process
    private let videoPipe = Pipe()
    private let errors = Pipe()
    // v30: the take's sound inputs: the chosen one (track 1) and the camera's own sound as a scratch track (track 2)
    private let audio: AudioTrack?
    private let scratch: AudioTrack?
    private var compressionSession: VTCompressionSession?
    private var wroteEncodedHeader = false
    private var finishing = false
    private var started = false
    private(set) var actualBitrate: Int?
    private(set) var startClock: Date?
    private(set) var startTimecode = ""
    private(set) var failed: String?
    private var firstVideoPTS: CMTime?          // the first frame given to the encoder = 0 in the file (capture queue)
    private var lastFLVDescription: CMFormatDescription?   // encoder thread
    private let createdAt = Date()
    var hasAudioTrack: Bool { audio != nil }
    private(set) var floatAudio = false          // v31: track 1 is 32-bit float PCM
    var hasScratchTrack: Bool { scratch != nil }
    var audioSecondsWritten: Double { audio?.secondsWritten ?? 0 }
    /// v30: what the sync did in this take (for /status and /sync): the shift applied, drift corrections, stamp jumps
    var syncInfo: [String: Any] {
        var d: [String: Any] = ["audioShiftMs": ((audio?.shift ?? 0) * 10000).rounded() / 10, "scratchTrack": scratch != nil]
        if let audio { d["corrections"] = audio.corrections; d["jumps"] = audio.jumps; d["driftMs"] = (audio.smoothedErrorMs * 100).rounded() / 100 }
        if let scratch { d["scratch"] = ["corrections": scratch.corrections, "jumps": scratch.jumps, "padded": scratch.padded,
                                         "seconds": (scratch.secondsWritten * 10).rounded() / 10] as [String: Any] }
        return d
    }
    /// v23 (silent-failure.md): a take whose sound does not arrive must say so on the bar within 2 s
    var soundWarning: String? {
        guard let audio else { return nil }
        if let p = audio.problem { return p }
        let since = audio.lastArrival ?? createdAt
        if Date().timeIntervalSince(since) > 2 { return audio.lastArrival == nil ? "NO SOUND is reaching the take" : "the sound STOPPED reaching the take" }
        // v26: buffers of exact digital zeros (a virtual or muted input, e.g. NDI Audio with no source) are no sound either;
        // a real microphone always has a noise floor, so a quiet room never triggers this
        if Date().timeIntervalSince(audio.lastAudible ?? createdAt) > 3 { return "the sound input sends only SILENCE (digital zero)" }
        return nil
    }

    func bitrateOnDisk(after elapsed: TimeInterval) -> Int? {
        guard elapsed > 0,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attributes[.size] as? NSNumber else { return nil }
        guard bytes.int64Value >= 65_536 else { return nil }
        return Int(Double(bytes.int64Value * 8) / elapsed)
    }

    /// v18: the folder of the takes is remembered (F key, right-click → Choose folder…); default ~/Movies
    static var folder: URL {
        if let p = UserDefaults.standard.string(forKey: "recordFolder") {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { return URL(fileURLWithPath: p) }
        }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
    }

    static func newURL(title: String? = nil) -> URL {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dir = folder
        var t = (title ?? "").unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
        t = String(t.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return dir.appendingPathComponent("mb_\(f.string(from: Date()))\(t.isEmpty ? "" : "_" + t).mkv")
    }

    /// v30: `audioShift` (seconds) moves the chosen sound against the picture (+ = later: the sync delay of that input minus
    /// the camera's picture delay); `scratchFormat` adds the camera's own sound as track 2 ("camera scratch", not default)
    init(fps: Int32, width: Int, height: Int, quality: RecordQuality,
         vertical: Bool, title: String? = nil, audioFormat description: CMFormatDescription?,
         audioShift: Double = 0, audioName: String? = nil,
         scratchFormat: CMFormatDescription? = nil, scratchShift: Double = 0,
         floatAudio: Bool = false, gainNote: String? = nil) throws {
        self.fps = fps
        self.quality = quality
        self.width = width
        self.height = height
        self.bitrate = quality.bitrate(width: width, height: height, fps: fps)
        url = Self.newURL(title: title)

        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        guard let ffmpeg else { throw NSError(domain: "Recorder", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "ffmpeg is not installed; cannot create a crash-safe MKV"]) }

        let stamp = Date()
        startClock = stamp
        startTimecode = Self.timecode(stamp, fps: fps).text

        let main = try description.map { try AudioTrack(description: $0, shift: audioShift, label: "audioWriter") }
        // the scratch track only beside a chosen sound; a scratch input in a format we cannot write is left out, never the take
        let extra = main == nil ? nil : scratchFormat.flatMap { try? AudioTrack(description: $0, shift: scratchShift, label: "scratchWriter") }
        // v31: the chosen input carries the GAIN (Gain.swift): the digital part on every buffer; an AAC take holds the samples
        // at full scale (a guard, never a compressor), a 32-bit float take keeps every sample, above 0 dBFS too
        main?.gainOn = true
        main?.guardFullScale = !floatAudio
        self.floatAudio = floatAudio && main != nil
        audio = main
        scratch = extra
        process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        // v23: the video comes as FLV tags carrying the capture time stamps. A raw H.264 elementary stream (v13 to v22) has
        // no time stamps, and ffmpeg 9's scheduler then starved the audio input until the video ended: all the sound sat
        // in one block behind the video at Stop (players reading in order lost it after 0.3 s; a crash lost it all).
        var args = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-thread_queue_size", "1024",
            "-f", "flv", "-i", "pipe:0",
        ]
        for t in [main, extra].compactMap({ $0 }) {
            args += [
                "-thread_queue_size", "1024",
                "-f", t.format, "-ar", "\(Int(t.rate))", "-ac", "\(t.channels)", "-i", t.fifo,
            ]
        }
        args += [
            "-map", "0:v:0",
        ]
        if main != nil { args += ["-map", "1:a:0"] }
        if extra != nil { args += ["-map", "2:a:0"] }
        args += [
            "-c:v", "copy",
        ]
        if main != nil {
            // v31: 32-bit float PCM (pcm_f32le, Matroska A_PCM/FLOAT/IEEE) when chosen, else AAC 256k as before
            args += floatAudio ? ["-c:a:0", "pcm_f32le"] : ["-c:a:0", "aac", "-b:a:0", "256k"]
            args += ["-disposition:a:0", "default"]
        }
        if let audioName, main != nil { args += ["-metadata:s:a:0", "title=\(audioName)"] }
        if let gainNote, main != nil { args += ["-metadata:s:a:0", "gain=\(gainNote)"] }
        if extra != nil { args += ["-c:a:1", "aac", "-b:a:1", "128k", "-disposition:a:1", "0", "-metadata:s:a:1", "title=camera scratch"] }
        args += [
            "-disposition:v:0", "default",
            "-metadata", "timecode=\(startTimecode)",
            "-f", "matroska", "-cluster_time_limit", "1000",
            "-flush_packets", "1",
            url.path,
        ]
        process.arguments = args
        process.standardInput = videoPipe
        process.standardError = errors
        try process.run()
        // v23: each FIFO is opened on its own writer queue first, so every PCM write queued meanwhile follows it in order
        // (v22 opened it elsewhere and DROPPED the sound that came before ffmpeg had probed the video: 1 to 1.7 s)
        main?.open()
        extra?.open()
        try writeFLVHeader()
        try createEncoder()
    }

    private func createEncoder() throws {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: Self.encodedFrame,
            refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &session)
        guard status == noErr, let session else {
            throw NSError(domain: "Recorder", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "cannot create the H.264 encoder"])
        }
        compressionSession = session
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as NSNumber)
        let bitrateStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ConstantBitRate,
                                                value: bitrate as NSNumber)
        guard bitrateStatus == noErr else {
            throw NSError(domain: "Recorder", code: Int(bitrateStatus),
                          userInfo: [NSLocalizedDescriptionKey: "H.264 constant bitrate is not supported"])
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: max(1, Int(fps) * 2) as NSNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        let ready = VTCompressionSessionPrepareToEncodeFrames(session)
        guard ready == noErr else {
            throw NSError(domain: "Recorder", code: Int(ready),
                          userInfo: [NSLocalizedDescriptionKey: "cannot prepare the H.264 encoder"])
        }
    }

    static func wallClock(of pts: CMTime) -> Date {
        let ago = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) - CMTimeGetSeconds(pts)
        return Date().addingTimeInterval(-ago)
    }

    static func timecode(_ d: Date, fps: Int32) -> (text: String, frames: Int32) {
        let c = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: d)
        let ff = min(Int(fps) - 1, Int(Double(c.nanosecond ?? 0) / 1e9 * Double(fps)))
        let total = ((c.hour! * 60 + c.minute!) * 60 + c.second!) * Int(fps) + ff
        return (String(format: "%02d:%02d:%02d:%02d", c.hour!, c.minute!, c.second!, ff), Int32(total))
    }

    func appendVideo(_ sb: CMSampleBuffer) {
        guard !finishing, let session = compressionSession,
              let image = CMSampleBufferGetImageBuffer(sb) else { return }
        started = true
        let vpts = CMSampleBufferGetPresentationTimeStamp(sb)
        if firstVideoPTS == nil {
            firstVideoPTS = vpts
            audio?.releaseHeld(v0: vpts)
            scratch?.releaseHeld(v0: vpts)
        }
        // v30: a scratch input that stops never holds the take up (ffmpeg would wait for it): silence keeps it 1 s behind
        if let scratch, let v0 = firstVideoPTS { scratch.pad(upTo: CMTimeGetSeconds(CMTimeSubtract(vpts, v0)) - 1.0) }
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: image, presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sb),
            duration: CMSampleBufferGetDuration(sb), frameProperties: nil, sourceFrameRefcon: nil,
            infoFlagsOut: nil)
        if status != noErr { failed = "H.264 encode failed (\(status))" }
    }

    private static let encodedFrame: VTCompressionOutputCallback = {
        refcon, _, status, _, sampleBuffer in
        guard let refcon, status == noErr, let sampleBuffer else { return }
        Unmanaged<Recorder>.fromOpaque(refcon).takeUnretainedValue().writeEncoded(sampleBuffer)
    }

    // MARK: v23, FLV on the pipe: each frame a tag with its own millisecond time stamp (from the capture clock)

    private static func be24(_ v: Int) -> [UInt8] { [UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    private static func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF)] + be24(v) }

    private func writeFLVHeader() throws {
        // "FLV", version 1, flags 1 = video only, header size 9, then PreviousTagSize0 = 0
        try videoPipe.fileHandleForWriting.write(contentsOf: Data([0x46, 0x4C, 0x56, 0x01, 0x01, 0, 0, 0, 9, 0, 0, 0, 0]))
    }

    /// one FLV video tag: type 9, size, time stamp (24 bits + 8 extended), stream 0, payload, then the tag's size
    private func flvTag(_ payload: Data, ms: Int) -> Data {
        var t = Data([9]); t.append(contentsOf: Self.be24(payload.count))
        t.append(contentsOf: Self.be24(ms & 0xFFFFFF)); t.append(UInt8((ms >> 24) & 0x7F)); t.append(contentsOf: [0, 0, 0])
        t.append(payload)
        t.append(contentsOf: Self.be32(11 + payload.count))
        return t
    }

    private func writeEncoded(_ sb: CMSampleBuffer) {
        guard let data = CMSampleBufferGetDataBuffer(sb), let description = CMSampleBufferGetFormatDescription(sb) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
            as? [[CFString: Any]]
        let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let origin = firstVideoPTS ?? pts
        let ms = max(0, Int((CMTimeGetSeconds(CMTimeSubtract(pts, origin)) * 1000).rounded()))
        var out = Data()
        // the AVC sequence header (the avcC record VideoToolbox made) first, and again whenever it changes
        if lastFLVDescription == nil || (keyframe && !CMFormatDescriptionEqual(description, otherFormatDescription: lastFLVDescription)) {
            let atoms = CMFormatDescriptionGetExtension(description,
                extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
            guard let avcC = atoms?["avcC"] as? Data else { failed = "H.264 encoder gave no avcC record"; return }
            var p = Data([0x17, 0, 0, 0, 0]); p.append(avcC)
            out.append(flvTag(p, ms: ms))
            lastFLVDescription = description
            wroteEncodedHeader = true
        }
        // the frame itself: VideoToolbox's samples are already length-prefixed NAL units (AVCC), as FLV wants them
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(data, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return }
        var frame = Data([keyframe ? 0x17 : 0x27, 1, 0, 0, 0])   // frame type + AVC, NALU, composition time 0 (no B-frames)
        if CMBlockBufferIsRangeContiguous(data, atOffset: 0, length: length) {
            frame.append(UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: length)
        } else {
            var copy = Data(count: length)
            copy.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            frame.append(copy)
        }
        out.append(flvTag(frame, ms: ms))
        do { try videoPipe.fileHandleForWriting.write(contentsOf: out) }
        catch { failed = error.localizedDescription }
    }

    func appendAudio(_ sb: CMSampleBuffer) {
        guard !finishing, let audio else { return }
        audio.append(sb, v0: firstVideoPTS)
    }

    /// v30: the camera's own sound (UGREEN 15389 (A)) beside the chosen input, written as track 2
    func appendScratch(_ sb: CMSampleBuffer) {
        guard !finishing, let scratch else { return }
        scratch.append(sb, v0: firstVideoPTS)
    }

    func finish(_ done: @escaping (Recorder) -> Void) {
        guard !finishing else { done(self); return }
        finishing = true
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
        do { try videoPipe.fileHandleForWriting.close() }
        catch { failed = error.localizedDescription }
        audio?.close()
        scratch?.close()
        let started = Date()
        func finishWhenMuxedOut() {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                if self.process.isRunning && Date().timeIntervalSince(started) < 8 {
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {
                        finishWhenMuxedOut()
                    }
                    return
                }
                // ffmpeg gone before it opened a sound pipe: open its read end once so that writer queue is released
                self.audio?.releaseIfNeverOpened()
                self.scratch?.releaseIfNeverOpened()
                if self.process.isRunning {
                    self.process.terminate()
                    self.failed = "MKV mux did not close within 8 seconds"
                } else if self.process.terminationStatus != 0, self.failed == nil {
                    self.failed = "ffmpeg stopped unexpectedly (\(self.process.terminationStatus))"
                }
                self.actualBitrate = self.probeBitrateOnDisk()
                done(self)
            }
        }
        finishWhenMuxedOut()
    }

    private func probeBitrateOnDisk() -> Int? {
        let paths = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=bit_rate",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path,
        ]
        let output = Pipe()
        process.standardOutput = output
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(text)
        } catch { return nil }
    }

}

/// v30: one PCM input of a take (the chosen sound, or the camera scratch) on its own FIFO into ffmpeg. All state is used on
/// the capture queue except the file handle, which belongs to the writer queue.
/// Placement (v23, LESSONS 30): the first sample written is the one at the first video frame's time, now moved by `shift`
/// (the A/V sync delay, docs/AVSYNC_PLAN.md §2): sample position = (pts + shift - first video pts) x rate; cut before 0,
/// silence when later. After that the sound runs on by its sample count, and every buffer's own stamp is compared with
/// where the count has got to: a smoothed difference over 1 ms is corrected by dropping or repeating ONE sample per buffer
/// (checked every 2 s: drift of the input's clock against the host clock); two buffers in a row more than 70 ms off (OBS's
/// TS_SMOOTHING_THRESHOLD: lost buffers, a device restart) are placed again at once by silence or a cut (a "jump").
final class AudioTrack {
    let fifo: String
    let format: String
    let rate: Double
    let channels: Int
    let bytesPerFrame: Int
    let shift: Double
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var handle: FileHandle?
    private var aligned = false
    private var held: [(CMTime, Data)] = []      // sound that came before the first video frame
    private(set) var samplesWritten: Int64 = 0
    private(set) var lastArrival: Date?
    private(set) var lastAudible: Date?          // v26: the last buffer that was not all exact zeros
    private(set) var problem: String?
    private(set) var corrections = 0             // samples dropped or repeated for drift
    private(set) var jumps = 0                   // re-placements after a stamp jump
    private(set) var padded = 0                  // silence written because the input sent nothing (scratch only)
    private var smoothed = 0.0                   // samples: + = the stamps are ahead of the count (sound must go later)
    private var pending = 0                      // samples still to repeat (+) or drop (-)
    private var lastCheck = 0.0                  // seconds of sound written at the last drift check
    private var farInARow = 0
    var gainOn = false                           // v31: the chosen input: Gain.digitalLinear on every buffer
    var guardFullScale = true                    // v31: false in a 32-bit float take (nothing is held at 0 dBFS)
    var secondsWritten: Double { Double(samplesWritten) / rate }
    var smoothedErrorMs: Double { smoothed / rate * 1000 }

    init(description: CMFormatDescription, shift: Double, label: String) throws {
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            throw NSError(domain: "Recorder", code: 3, userInfo: [NSLocalizedDescriptionKey: "the sound input has no format"])
        }
        let ch = max(1, min(2, Int(asbd.mChannelsPerFrame)))
        let bits = Int(asbd.mBitsPerChannel)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        if isFloat, bits == 32 { format = "f32le" }
        else if !isFloat, bits == 16 { format = "s16le" }
        else if !isFloat, bits == 32 { format = "s32le" }
        else { throw NSError(domain: "Recorder", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "unsupported microphone sample format"]) }
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("webcam-recorder-\(UUID().uuidString).audio").path
        guard mkfifo(path, S_IRUSR | S_IWUSR) == 0 else {
            throw NSError(domain: "Recorder", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "cannot create the audio input pipe"])
        }
        fifo = path
        rate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000
        channels = ch
        bytesPerFrame = ch * (bits / 8)
        self.shift = shift
        queue = DispatchQueue(label: "webcamviewer.\(label)", qos: .userInitiated)
    }

    deinit { try? FileManager.default.removeItem(atPath: fifo) }

    /// the first block on the writer queue (LESSONS 30): it waits until ffmpeg opens the read end
    func open() {
        queue.async { [weak self] in
            guard let self else { return }
            let h = FileHandle(forWritingAtPath: self.fifo)
            self.lock.lock(); self.handle = h; self.lock.unlock()
        }
    }

    func close() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let h = self.handle; self.handle = nil; self.lock.unlock()
            try? h?.close()
        }
    }

    func releaseIfNeverOpened() {
        lock.lock(); let opened = handle != nil; lock.unlock()
        if !opened { let fd = Darwin.open(fifo, O_RDONLY | O_NONBLOCK); if fd >= 0 { usleep(100_000); Darwin.close(fd) } }
    }

    /// capture queue: one buffer of this input
    func append(_ sb: CMSampleBuffer, v0: CMTime?) {
        guard CMSampleBufferDataIsReady(sb), var pcm = pcm(sb) else { return }
        if gainOn { Gain.apply(&pcm, format: format, g: Gain.digitalLinear, guardFullScale: guardFullScale) }
        lastArrival = Date()
        if pcm.contains(where: { $0 != 0 }) { lastAudible = lastArrival }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard let v0 else {
            // the sound before the first picture waits for it (at most 250 buffers), then the part before the picture is cut
            held.append((pts, pcm))
            if held.count > 250 { held.removeFirst() }
            return
        }
        place(pcm, pts: pts, v0: v0)
    }

    func releaseHeld(v0: CMTime) {
        let h = held; held = []
        for (pts, pcm) in h { place(pcm, pts: pts, v0: v0) }
    }

    /// scratch only: an input that sent nothing is filled with silence up to `seconds` of the file, so ffmpeg never waits
    func pad(upTo seconds: Double) {
        let target = Int64(seconds * rate)
        guard seconds > 0, target > samplesWritten else { return }
        let n = Int(min(target - samplesWritten, Int64(rate * 5)))
        aligned = true
        padded += n
        write(Data(count: n * bytesPerFrame))
    }

    private func place(_ input: Data, pts: CMTime, v0: CMTime) {
        var pcm = input
        let frames = pcm.count / bytesPerFrame
        guard frames > 0 else { return }
        let position = (CMTimeGetSeconds(CMTimeSubtract(pts, v0)) + shift) * rate   // where this buffer's first sample belongs
        guard position.isFinite else { return }
        if !aligned {
            let f = Int(position.rounded())
            if f < 0 {
                let cut = -f * bytesPerFrame
                if cut >= pcm.count { return }          // all of it before the picture
                pcm = pcm.subdata(in: cut..<pcm.count)
            } else if f > 0 {
                pcm = Data(count: min(f, Int(rate) * 5) * bytesPerFrame) + pcm
            }
            aligned = true
            lastCheck = 0
        } else {
            let error = position - Double(samplesWritten)
            if abs(error) > 0.070 * rate {
                farInARow += 1
                if farInARow >= 2 {
                    // a stamp jump, seen on two buffers in a row: placed again by its stamp
                    jumps += 1; farInARow = 0; smoothed = 0; pending = 0
                    let n = Int(error.rounded())
                    NSLog("Webcam Recorder: sound stamp jump of %.1f ms, placed again", Double(n) / rate * 1000)
                    if n > 0 { pcm = Data(count: min(n, Int(rate) * 5) * bytesPerFrame) + pcm }
                    else {
                        let cut = min(-n, frames) * bytesPerFrame
                        if cut >= pcm.count { return }
                        pcm = pcm.subdata(in: cut..<pcm.count)
                    }
                }
            } else {
                farInARow = 0
                smoothed += (error - smoothed) * 0.05     // about 20 buffers
                let now = secondsWritten
                if now - lastCheck >= 2 {
                    lastCheck = now
                    pending = abs(smoothed) > 0.001 * rate ? Int(smoothed.rounded()) : 0
                }
                if pending != 0, frames > 1 {
                    if pending > 0 { pcm.append(pcm.subdata(in: (pcm.count - bytesPerFrame)..<pcm.count)); pending -= 1 }
                    else { pcm.removeLast(bytesPerFrame); pending += 1 }
                    corrections += 1
                }
            }
        }
        write(pcm)
    }

    private func write(_ pcm: Data) {
        samplesWritten += Int64(pcm.count / max(1, bytesPerFrame))
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let h = self.handle; self.lock.unlock()
            guard let h else { return }
            do { try h.write(contentsOf: pcm) }
            catch { if self.problem == nil { self.problem = "the sound could not be written: \(error.localizedDescription)" } }
        }
    }

    /// the buffer as interleaved PCM of `channels` channels (a 4-channel interface gives its first two); nil on a format change
    private func pcm(_ sb: CMSampleBuffer) -> Data? {
        // v23: a sound input that changes its format in the middle of a take cannot go on into the same track: say so
        if let d = CMSampleBufferGetFormatDescription(sb), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee,
           Int(asbd.mSampleRate) != Int(rate) || Int(asbd.mBitsPerChannel) / 8 * min(2, max(1, Int(asbd.mChannelsPerFrame))) != bytesPerFrame {
            if problem == nil { problem = "the sound input CHANGED FORMAT: no sound from here on" }
            return nil
        }
        var size = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &size, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let capacity = max(size, MemoryLayout<AudioBufferList>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: list,
            bufferListSize: capacity, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr else { return nil }
        let buffers = Array(UnsafeMutableAudioBufferListPointer(list))
        let frames = Int(CMSampleBufferGetNumSamples(sb))
        guard let first = buffers.first, first.mData != nil, frames > 0 else { return nil }
        let want = channels
        let sampleBytes = bytesPerFrame / want
        var out = Data(count: frames * bytesPerFrame)
        out.withUnsafeMutableBytes { dst in
            guard let o = dst.baseAddress else { return }
            if buffers.count == 1 {
                // interleaved: keep the first `want` channels of each frame
                let have = max(1, Int(first.mNumberChannels))
                let src = first.mData!
                let usable = min(frames, Int(first.mDataByteSize) / (have * sampleBytes))
                if have == want {
                    memcpy(o, src, usable * bytesPerFrame)
                } else {
                    for f in 0..<usable {
                        for ch in 0..<want {
                            memcpy(o + (f * want + ch) * sampleBytes, src + (f * have + min(ch, have - 1)) * sampleBytes, sampleBytes)
                        }
                    }
                }
            } else {
                // one buffer per channel: interleave the first `want`
                for f in 0..<frames {
                    for ch in 0..<want {
                        let b = buffers[min(ch, buffers.count - 1)]
                        guard let src = b.mData, (f + 1) * sampleBytes <= Int(b.mDataByteSize) else { continue }
                        memcpy(o + (f * want + ch) * sampleBytes, src + f * sampleBytes, sampleBytes)
                    }
                }
            }
        }
        return out
    }
}
