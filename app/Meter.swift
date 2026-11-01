import AppKit
import AVFoundation

// The VU hairline down the left edge of the picture, the meter of Mantra Manual Camera (MANTRA_NDI VuMeterView.kt),
// its arithmetic unchanged: dB scale from −54, fast attack, slow release, a white peak that holds and falls back slowly,
// −6 and −18 marked, green → amber above 80 % → red above 93 %. Dead (no audio input): only the dark strip and marks.
final class Meter: NSView {
    static let minDB: Float = -54
    private var level: Float = 0, peak: Float = 0, hold = 0
    var dead = true { didSet { if dead != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { false }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }   // the picture under it still drags the window

    /// rms: linear 0…1, called on the main thread
    func setLevel(_ rms: Float) {
        let db = rms <= 1e-7 ? Self.minDB : max(Self.minDB, 20 * log10(rms))
        let n = min(1, max(0, (db - Self.minDB) / -Self.minDB))
        level = n > level ? n : level * 0.82 + n * 0.18
        if n >= peak { peak = n; hold = 45 } else if hold > 0 { hold -= 1 } else { peak = max(level, peak - 0.012) }
        needsDisplay = true
    }

    override func draw(_ r: NSRect) {
        let w = bounds.width, h = bounds.height
        NSColor(white: 0, alpha: 0.33).setFill(); bounds.fill()
        NSColor(white: 1, alpha: 0.24).setFill()
        for db: Float in [-6, -18] {
            let y = h * CGFloat((db - Self.minDB) / -Self.minDB)
            NSRect(x: 0, y: y, width: w, height: 1).fill()
        }
        if dead { return }
        (level > 0.93 ? NSColor(srgbRed: 1, green: 0.231, blue: 0.188, alpha: 1)
         : level > 0.80 ? NSColor(srgbRed: 1, green: 0.702, blue: 0, alpha: 1)
         : NSColor(srgbRed: 0, green: 0.878, blue: 0.627, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: w, height: h * CGFloat(level)).fill()
        if peak > 0.01 { NSColor.white.setFill(); NSRect(x: 0, y: h * CGFloat(peak) - 2, width: w, height: 2).fill() }
    }

    /// linear RMS of a buffer of Float32 or Int16 PCM, all channels together
    static func rms(_ sb: CMSampleBuffer) -> Float {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { return 0 }
        var abl = AudioBufferList(), block: CMBlockBuffer?
        var size = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &size, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: max(size, MemoryLayout<AudioBufferList>.size), alignment: 16)
        defer { raw.deallocate() }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: list,
            bufferListSize: max(size, MemoryLayout<AudioBufferList>.size), blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &block) == noErr else { return 0 }
        _ = abl
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        var sum: Double = 0, n = 0
        for buf in UnsafeMutableAudioBufferListPointer(list) {
            guard let d = buf.mData else { continue }
            if isFloat && asbd.mBitsPerChannel == 32 {
                let c = Int(buf.mDataByteSize) / 4, p = d.assumingMemoryBound(to: Float.self)
                for i in 0..<c { sum += Double(p[i] * p[i]) }; n += c
            } else if asbd.mBitsPerChannel == 16 {
                let c = Int(buf.mDataByteSize) / 2, p = d.assumingMemoryBound(to: Int16.self)
                for i in 0..<c { let v = Double(p[i]) / 32768; sum += v * v }; n += c
            } else if asbd.mBitsPerChannel == 32 {
                let c = Int(buf.mDataByteSize) / 4, p = d.assumingMemoryBound(to: Int32.self)
                for i in 0..<c { let v = Double(p[i]) / 2147483648; sum += v * v }; n += c
            }
        }
        return n > 0 ? Float((sum / Double(n)).squareRoot()) : 0
    }
}

// The record key of Mantra Manual Camera: a plain circle, white idle, red recording, nothing inside it.
final class RecordKey: NSButton {
    var recording = false { didSet { needsDisplay = true } }
    override func draw(_ r: NSRect) {
        let d: CGFloat = 20
        let c = NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        let p = NSBezierPath(ovalIn: c)
        if recording { NSColor(srgbRed: 1, green: 0.231, blue: 0.188, alpha: 1).setFill(); p.fill() }
        else { NSColor.white.setStroke(); p.lineWidth = 2.5; p.stroke() }
    }
}

// The full-screen key (Marko, 1.11.2026: "this rectangle, which looks like full screen with gaps between"): the four
// corners of a rectangle, the middle of each side left open. Grey like ✕.
final class FullKey: NSButton {
    override func draw(_ r: NSRect) {
        let w: CGFloat = 18, h: CGFloat = 13, arm: CGFloat = 5.5
        let f = NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
        let p = NSBezierPath()
        for (x, y, dx, dy) in [(f.minX, f.minY, 1.0, 1.0), (f.maxX, f.minY, -1.0, 1.0), (f.minX, f.maxY, 1.0, -1.0), (f.maxX, f.maxY, -1.0, -1.0)] {
            p.move(to: NSPoint(x: x + dx * arm, y: y)); p.line(to: NSPoint(x: x, y: y)); p.line(to: NSPoint(x: x, y: y + dy * arm))
        }
        p.lineWidth = 2; p.lineCapStyle = .round; p.lineJoinStyle = .round
        NSColor.secondaryLabelColor.setStroke(); p.stroke()
    }
}
