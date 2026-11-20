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
    private(set) var startClock: Date?
    private(set) var startTimecode = ""
    private(set) var failed: String?

    static func newURL(title: String? = nil) -> URL {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
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
        var args = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-thread_queue_size", "1024",
            "-f", "h264", "-r", "\(fps)", "-i", "pipe:0",
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
        if fifo != nil { args += ["-c:a", "aac", "-b:a", "256k"] }
        args += [
            "-metadata", "timecode=\(startTimecode)",
            "-f", "matroska", "-cluster_time_limit", "1000",
            "-flush_packets", "1",
            url.path,
        ]
        process.arguments = args
        process.standardInput = videoPipe
        process.standardError = errors
        try process.run()
        if let fifo {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let handle = FileHandle(forWritingAtPath: fifo)
                self?.audioLock.lock()
                self?.audioHandle = handle
                self?.audioLock.unlock()
            }
        }
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

    private func writeEncoded(_ sb: CMSampleBuffer) {
        guard let data = CMSampleBufferGetDataBuffer(sb) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
            as? [[CFString: Any]]
        let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        var out = Data()
        if keyframe || !wroteEncodedHeader,
           let description = CMSampleBufferGetFormatDescription(sb) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var length = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &length,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                    let pointer else { continue }
                out.append(contentsOf: [0, 0, 0, 1])
                out.append(pointer, count: length)
            }
            wroteEncodedHeader = true
        }
        var pointer: UnsafeMutablePointer<Int8>?
        var length = 0
        guard CMBlockBufferGetDataPointer(data, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return }
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        var nalHeaderLength: Int32 = 4
        if let description = CMSampleBufferGetFormatDescription(sb) {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: &nalHeaderLength)
        }
        let headerLength = Int(nalHeaderLength)
        var offset = 0
        while offset + headerLength <= length {
            var size = 0
            for i in 0..<headerLength { size = size << 8 | Int(bytes[offset + i]) }
            offset += headerLength
            guard size > 0, offset + size <= length else { break }
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(bytes.advanced(by: offset), count: size)
            offset += size
        }
        do { try videoPipe.fileHandleForWriting.write(contentsOf: out) }
        catch { failed = error.localizedDescription }
    }

    func appendAudio(_ sb: CMSampleBuffer) {
        guard !finishing, audioFIFO != nil, CMSampleBufferDataIsReady(sb) else { return }
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
        guard let first = buffers.first, let data = first.mData else { return }
        let pcm: Data
        if buffers.count == 1 {
            pcm = Data(bytes: data, count: Int(first.mDataByteSize))
        } else {
            let bytesPerSample = max(1, Int(first.mDataByteSize) / max(1, Int(first.mNumberChannels) * Int(CMSampleBufferGetNumSamples(sb))))
            let frames = max(1, Int(first.mDataByteSize) / (bytesPerSample * max(1, Int(first.mNumberChannels))))
            var interleaved = Data()
            for frame in 0..<frames {
                for buffer in buffers {
                    if let base = buffer.mData {
                        interleaved.append(Data(bytes: base.advanced(by: frame * bytesPerSample), count: bytesPerSample))
                    }
                }
            }
            pcm = interleaved
        }
        audioWriterQueue.async { [weak self] in
            guard let self else { return }
            self.audioLock.lock()
            let handle = self.audioHandle
            self.audioLock.unlock()
            guard let handle else { return }
            do { try handle.write(contentsOf: pcm) }
            catch { self.failed = error.localizedDescription }
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
                if self.process.isRunning {
                    self.process.terminate()
                    self.failed = "MKV mux did not close within 8 seconds"
                } else if self.process.terminationStatus != 0, self.failed == nil {
                    self.failed = "ffmpeg stopped unexpectedly (\(self.process.terminationStatus))"
                }
                done(self)
            }
        }
        finishWhenMuxedOut()
    }

    deinit {
        if let audioFIFO { try? FileManager.default.removeItem(atPath: audioFIFO) }
    }
}
