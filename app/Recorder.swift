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
    private let audioFIFO: String?
    private var audioHandle: FileHandle?
    private let audioLock = NSLock()
    private let audioWriterQueue = DispatchQueue(label: "webcamviewer.audioWriter", qos: .userInitiated)
    private var compressionSession: VTCompressionSession?
    private var wroteEncodedHeader = false
    private var finishing = false
    private var started = false
    private(set) var actualBitrate: Int?
    private(set) var startClock: Date?
    private(set) var startTimecode = ""
    private(set) var failed: String?
    // v23: the audio side, for alignment and the "no sound" warning (capture queue unless said otherwise)
    private var audioChannels = 0
    private var audioRate: Double = 48000
    private var audioBytesPerFrame = 4
    private var firstVideoPTS: CMTime?          // the first frame given to the encoder = 0 in the file
    private var audioAligned = false
    private var heldAudio: [(CMTime, Data)] = []   // sound that came before the first video frame
    private(set) var audioSamplesWritten: Int64 = 0
    private(set) var lastAudioArrival: Date?
    private(set) var lastAudibleArrival: Date?   // v26: the last buffer that was not all exact zeros
    private(set) var audioProblem: String?
    private var lastFLVDescription: CMFormatDescription?   // encoder thread
    private let createdAt = Date()
    var hasAudioTrack: Bool { audioFIFO != nil }
    var audioSecondsWritten: Double { Double(audioSamplesWritten) / audioRate }
    /// v23 (silent-failure.md): a take whose sound does not arrive must say so on the bar within 2 s
    var soundWarning: String? {
        guard hasAudioTrack else { return nil }
        if let audioProblem { return audioProblem }
        let since = lastAudioArrival ?? createdAt
        if Date().timeIntervalSince(since) > 2 { return lastAudioArrival == nil ? "NO SOUND is reaching the take" : "the sound STOPPED reaching the take" }
        // v26: buffers of exact digital zeros (a virtual or muted input, e.g. NDI Audio with no source) are no sound either;
        // a real microphone always has a noise floor, so a quiet room never triggers this
        if Date().timeIntervalSince(lastAudibleArrival ?? createdAt) > 3 { return "the sound input sends only SILENCE (digital zero)" }
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

    init(fps: Int32, width: Int, height: Int, quality: RecordQuality,
         vertical: Bool, title: String? = nil, audioFormat description: CMFormatDescription?) throws {
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

        var rawAudioFormat: String?
        var rawAudioRate: Int?
        var rawAudioChannels: Int?
        var fifo: String?
        if let description, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            let channels = max(1, min(2, Int(asbd.mChannelsPerFrame)))
            let bits = Int(asbd.mBitsPerChannel)
            let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            let format: String
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
            rawAudioFormat = format
            rawAudioRate = Int(asbd.mSampleRate)
            rawAudioChannels = channels
        }
        audioFIFO = fifo
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
        if let fifo, let rawAudioFormat, let rawAudioRate, let rawAudioChannels {
            args += [
                "-thread_queue_size", "1024",
                "-f", rawAudioFormat, "-ar", "\(rawAudioRate)", "-ac", "\(rawAudioChannels)", "-i", fifo,
            ]
        }
        args += [
            "-map", "0:v:0",
        ]
        if fifo != nil { args += ["-map", "1:a:0"] }
        args += [
            "-c:v", "copy",
        ]
        if fifo != nil { args += ["-c:a", "aac", "-b:a", "256k", "-disposition:a:0", "default"] }
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
        audioChannels = rawAudioChannels ?? 0
        audioRate = Double(rawAudioRate ?? 48000)
        audioBytesPerFrame = (rawAudioChannels ?? 1) * ((rawAudioFormat == "s16le") ? 2 : 4)
        if let fifo {
            // v23: the open waits on the writer queue itself, so every PCM write queued meanwhile follows it in order
            // (v22 opened it elsewhere and DROPPED the sound that came before ffmpeg had probed the video: 1 to 1.7 s)
            audioWriterQueue.async { [weak self] in
                let handle = FileHandle(forWritingAtPath: fifo)
                self?.audioLock.lock()
                self?.audioHandle = handle
                self?.audioLock.unlock()
            }
        }
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
        if firstVideoPTS == nil {
            firstVideoPTS = CMSampleBufferGetPresentationTimeStamp(sb)
            let held = heldAudio; heldAudio = []
            for (pts, pcm) in held { writeAligned(pcm, pts: pts) }
        }
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
        guard !finishing, audioFIFO != nil, CMSampleBufferDataIsReady(sb) else { return }
        // v23: a sound input that changes its format in the middle of a take cannot go on into the same track: say so
        if let d = CMSampleBufferGetFormatDescription(sb), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee,
           Int(asbd.mSampleRate) != Int(audioRate) || Int(asbd.mBitsPerChannel) / 8 * min(2, max(1, Int(asbd.mChannelsPerFrame))) != audioBytesPerFrame {
            if audioProblem == nil { audioProblem = "the sound input CHANGED FORMAT: no sound from here on" }
            return
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
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr else { return }
        let buffers = Array(UnsafeMutableAudioBufferListPointer(list))
        let frames = Int(CMSampleBufferGetNumSamples(sb))
        guard let first = buffers.first, first.mData != nil, frames > 0 else { return }
        let want = max(1, audioChannels)
        let sampleBytes = audioBytesPerFrame / want
        var pcm = Data(count: frames * audioBytesPerFrame)
        pcm.withUnsafeMutableBytes { dst in
            guard let out = dst.baseAddress else { return }
            if buffers.count == 1 {
                // interleaved: keep the first `want` channels of each frame (a 4-channel interface gives its first two)
                let have = max(1, Int(first.mNumberChannels))
                let src = first.mData!
                let usable = min(frames, Int(first.mDataByteSize) / (have * sampleBytes))
                if have == want {
                    memcpy(out, src, usable * audioBytesPerFrame)
                } else {
                    for f in 0..<usable {
                        for ch in 0..<want {
                            memcpy(out + (f * want + ch) * sampleBytes, src + (f * have + min(ch, have - 1)) * sampleBytes, sampleBytes)
                        }
                    }
                }
            } else {
                // one buffer per channel: interleave the first `want`
                for f in 0..<frames {
                    for ch in 0..<want {
                        let b = buffers[min(ch, buffers.count - 1)]
                        guard let src = b.mData, (f + 1) * sampleBytes <= Int(b.mDataByteSize) else { continue }
                        memcpy(out + (f * want + ch) * sampleBytes, src + f * sampleBytes, sampleBytes)
                    }
                }
            }
        }
        lastAudioArrival = Date()
        if pcm.contains(where: { $0 != 0 }) { lastAudibleArrival = lastAudioArrival }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if firstVideoPTS == nil {
            // the sound before the first picture waits for it (at most 5 s), then the part before the picture is cut
            heldAudio.append((pts, pcm))
            if heldAudio.count > 250 { heldAudio.removeFirst() }
            return
        }
        writeAligned(pcm, pts: pts)
    }

    /// v23: the first sound sample written is the one at the first video frame's time (cut before it, silence if later),
    /// so the file's audio 0 is the picture's 0. After that the sound runs on by its own sample count.
    private func writeAligned(_ input: Data, pts: CMTime) {
        var pcm = input
        if !audioAligned, let v0 = firstVideoPTS {
            let offset = CMTimeGetSeconds(CMTimeSubtract(pts, v0))
            let frames = Int((abs(offset) * audioRate).rounded())
            if offset < 0 {
                let cut = frames * audioBytesPerFrame
                if cut >= pcm.count { return }          // all of it before the picture
                pcm = pcm.subdata(in: cut..<pcm.count)
            } else if frames > 0 {
                pcm = Data(count: min(frames, Int(audioRate) * 5) * audioBytesPerFrame) + pcm
            }
            audioAligned = true
        }
        audioSamplesWritten += Int64(pcm.count / max(1, audioBytesPerFrame))
        audioWriterQueue.async { [weak self] in
            guard let self else { return }
            self.audioLock.lock()
            let handle = self.audioHandle
            self.audioLock.unlock()
            guard let handle else { return }
            do { try handle.write(contentsOf: pcm) }
            catch { if self.audioProblem == nil { self.audioProblem = "the sound could not be written: \(error.localizedDescription)" } }
        }
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
        audioWriterQueue.async { [weak self] in
            guard let self else { return }
            self.audioLock.lock()
            let audio = self.audioHandle
            self.audioHandle = nil
            self.audioLock.unlock()
            try? audio?.close()
        }
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
                if let fifo = self.audioFIFO {
                    // ffmpeg gone before it opened the sound pipe: open its read end once so the writer queue is released
                    self.audioLock.lock(); let opened = self.audioHandle != nil; self.audioLock.unlock()
                    if !opened { let fd = open(fifo, O_RDONLY | O_NONBLOCK); if fd >= 0 { usleep(100_000); close(fd) } }
                }
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

    deinit {
        if let audioFIFO { try? FileManager.default.removeItem(atPath: audioFIFO) }
    }
}
