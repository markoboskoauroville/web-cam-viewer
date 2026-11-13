import AVFoundation
import VideoToolbox

// A take: ~/Movies/mb_<date>_<time>.mov, H.265 1920×1080 at 10 Mb/s, AAC, and a QuickTime time code track whose start
// is the real-time clock of the first frame (Marko, 1.11.2026: "Time code must be there, which is exactly the real-time
// clock"; MANTRA_MANIFEST modules/timecode.md). QuickTime .mov because it carries a tmcd track that Resolve reads.
// Written in one-second fragments, so a crash loses a second, not the take (recorder.md §2).
final class Recorder {
    let url: URL
    let fps: Int32
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let tc: AVAssetWriterInput
    private var started = false
    private(set) var startClock: Date?
    private(set) var startTimecode = ""
    private(set) var failed: String?

    /// ~/Movies/mb_<date>_<time>[_<title>].mov (v6: the API's take title, letters digits - _ only)
    static func newURL(title: String? = nil) -> URL {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        var t = (title ?? "").unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
        t = String(t.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return dir.appendingPathComponent("mb_\(f.string(from: Date()))\(t.isEmpty ? "" : "_" + t).mov")
    }

    init(fps: Int32, vertical: Bool = false, title: String? = nil, audioFormat: CMFormatDescription?) throws {
        self.fps = fps
        url = Self.newURL(title: title)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)

        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: vertical ? Slicer.outW : 1920, AVVideoHeightKey: vertical ? Slicer.outH : 1080,   // v5: 1080×1920 for a vertical slice
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)

        if let af = audioFormat, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(af)?.pointee {
            let ch = min(2, max(1, Int(asbd.mChannelsPerFrame)))
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: ch,
                AVEncoderBitRateKey: ch == 2 ? 256_000 : 160_000,
            ], sourceFormatHint: af)
            a.expectsMediaDataInRealTime = true
            writer.add(a); audio = a
        } else { audio = nil }

        var tcf: CMTimeCodeFormatDescription?
        CMTimeCodeFormatDescriptionCreate(allocator: nil, timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
            frameDuration: CMTime(value: 1, timescale: fps), frameQuanta: UInt32(fps),
            flags: kCMTimeCodeFlag_24HourMax, extensions: nil, formatDescriptionOut: &tcf)
        tc = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: tcf)
        tc.expectsMediaDataInRealTime = true
        writer.add(tc)
        video.addTrackAssociation(withTrackOf: tc, type: AVAssetTrack.AssociationType.timecode.rawValue)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "Recorder", code: 1) }
    }

    /// the wall clock of a capture time stamp (the host clock): now − (host now − pts)
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

    // called on the capture queue
    func appendVideo(_ sb: CMSampleBuffer) {
        guard writer.status == .writing else { note(); return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if !started {
            started = true
            writer.startSession(atSourceTime: pts)
            let when = Self.wallClock(of: pts)
            startClock = when
            let t = Self.timecode(when, fps: fps)
            startTimecode = t.text
            appendTimecode(frames: t.frames, at: pts)
        }
        if video.isReadyForMoreMediaData { video.append(sb) }
    }

    func appendAudio(_ sb: CMSampleBuffer) {
        guard started, writer.status == .writing, let a = audio, a.isReadyForMoreMediaData else { return }
        if CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sb), .zero) > 0 { a.append(sb) }
    }

    private func appendTimecode(frames: Int32, at pts: CMTime) {
        var be = frames.bigEndian
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: 4, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: 4, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block else { return }
        CMBlockBufferReplaceDataBytes(with: &be, blockBuffer: block, offsetIntoDestination: 0, dataLength: 4)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: fps), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = 4
        var sb: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: tc.sourceFormatHint, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb)
        if let sb, tc.isReadyForMoreMediaData { tc.append(sb) }
        tc.markAsFinished()
    }

    private func note() { if writer.status == .failed, failed == nil { failed = writer.error?.localizedDescription ?? "failed" } }

    func finish(_ done: @escaping (Recorder) -> Void) {
        guard writer.status == .writing else { note(); done(self); return }
        video.markAsFinished(); audio?.markAsFinished()
        writer.finishWriting { self.note(); done(self) }
    }
}
