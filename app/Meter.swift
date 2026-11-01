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

    /// linear RMS of each channel of a buffer of Float32, Int16 or Int32 PCM, interleaved or not: [left, right, …]
    static func rms(_ sb: CMSampleBuffer) -> [Float] {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { return [] }
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
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr else { return [] }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = Int(asbd.mBitsPerChannel)
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        var sums = [Double](repeating: 0, count: channels), counts = [Int](repeating: 0, count: channels)
        var channelBase = 0
        for buf in UnsafeMutableAudioBufferListPointer(list) {
            guard let d = buf.mData else { continue }
            let per = max(1, Int(buf.mNumberChannels))          // channels interleaved in this buffer
            let bytes = bits / 8
            guard bytes > 0 else { continue }
            let n = Int(buf.mDataByteSize) / bytes
            for k in 0..<n {
                let v: Double
                if isFloat && bits == 32 { v = Double(d.load(fromByteOffset: k * 4, as: Float.self)) }
                else if bits == 16 { v = Double(d.load(fromByteOffset: k * 2, as: Int16.self)) / 32768 }
                else if bits == 32 { v = Double(d.load(fromByteOffset: k * 4, as: Int32.self)) / 2147483648 }
                else { continue }
                let c = min(channels - 1, channelBase + k % per)
                sums[c] += v * v; counts[c] += 1
            }
            channelBase += per
        }
        return (0..<channels).map { counts[$0] > 0 ? Float((sums[$0] / Double(counts[$0])).squareRoot()) : 0 }
    }
}

// v3, Marko, 1.11.2026: "two hairlines ... for the left and right channels". Two meters side by side down the left edge,
// L on the outside, R beside it, a 2 pt gap; a mono input lights both alike.
final class StereoMeter: NSView {
    let left = Meter(), right = Meter()
    static let hairline: CGFloat = 3, gap: CGFloat = 2
    var dead = true { didSet { left.dead = dead; right.dead = dead } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        for m in [left, right] { m.translatesAutoresizingMaskIntoConstraints = false; addSubview(m) }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor), left.topAnchor.constraint(equalTo: topAnchor),
            left.bottomAnchor.constraint(equalTo: bottomAnchor), left.widthAnchor.constraint(equalToConstant: Self.hairline),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: Self.gap), right.topAnchor.constraint(equalTo: topAnchor),
            right.bottomAnchor.constraint(equalTo: bottomAnchor), right.widthAnchor.constraint(equalToConstant: Self.hairline),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
    static var width: CGFloat { hairline * 2 + gap }
    func setLevels(_ rms: [Float]) {
        guard let first = rms.first else { return }
        left.setLevel(first)
        right.setLevel(rms.count > 1 ? rms[1] : first)
    }
}

// The record key of Mantra Manual Camera: a plain circle, white idle, red recording, nothing inside it.
// v3, Marko, 1.11.2026: "hovering over the record button puts the red in the middle, but not full red. Just a little bit
// of transparent red, so I know if I press it, it will become full and start recording": idle under the mouse, the white
// ring is filled with the record red at 35 %.
final class RecordKey: NSButton {
    var recording = false { didSet { needsDisplay = true } }
    var hovering = false { didSet { needsDisplay = true } }   // settable for the --hover-rec test shot
    private static let red = NSColor(srgbRed: 1, green: 0.231, blue: 0.188, alpha: 1)
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    override func draw(_ r: NSRect) {
        let d: CGFloat = 20
        let c = NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        let p = NSBezierPath(ovalIn: c)
        if recording { Self.red.setFill(); p.fill(); return }
        if hovering { Self.red.withAlphaComponent(0.35).setFill(); p.fill() }
        NSColor.white.setStroke(); p.lineWidth = 2.5; p.stroke()
    }
}

// The full-screen key (Marko, 1.11.2026: "this rectangle, which looks like full screen with gaps between"): the four
// corners of a rectangle, the middle of each side left open. Grey like ✕.
final class FullKey: NSButton {
    override func draw(_ r: NSRect) {
        let w: CGFloat = 19, h: CGFloat = 15, arm: CGFloat = 4.5
        let f = NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
        let p = NSBezierPath()
        for (x, y, dx, dy) in [(f.minX, f.minY, 1.0, 1.0), (f.maxX, f.minY, -1.0, 1.0), (f.minX, f.maxY, 1.0, -1.0), (f.maxX, f.maxY, -1.0, -1.0)] {
            p.move(to: NSPoint(x: x + dx * arm, y: y)); p.line(to: NSPoint(x: x, y: y)); p.line(to: NSPoint(x: x, y: y + dy * arm))
        }
        p.lineWidth = 2; p.lineCapStyle = .round; p.lineJoinStyle = .round
        NSColor.secondaryLabelColor.setStroke(); p.stroke()
    }
}
