import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo

// v5, Marko, 13.11.2026: "make the slice view the same as in my video Ninja in my classroom and on my website ... I want to
// have the horizontal camera as it is now and record it as vertical camera with a simple trick of slicing."
// The same cut as sliceOf() in the MPA classroom (website/site/portal/room.html): the middle 9:16 of the frame at full
// height (the α7 V's 3840×2160 → 1215×2160), scaled to 1080×1920. Core Image Lanczos does the scaling, and a source that
// is more than twice as large is halved first (the classroom's rule since 8.11.2026: one jump of 3.4x stair-stepped thin
// lines). The result is a new sample buffer with the original time stamps, so the recorder, its time code and its audio
// work exactly as before; the preview shows the same buffers.
final class Slicer {
    static let outW = 1080, outH = 1920
    private let ci = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private var pool: CVPixelBufferPool?
    private(set) var sourceSize = CGSize.zero      // of the last frame: the click on the picture needs it

    /// the middle 9:16 strip of a w×h frame: its width in source pixels (even)
    static func stripWidth(w: Int, h: Int) -> Int { min(w, Int((Double(h) * 9 / 16).rounded()) & ~1) }

    private func makePool() {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Self.outW, kCVPixelBufferHeightKey as String: Self.outH,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    }

    /// the vertical frame for one camera frame, same time stamps; nil when it cannot be made
    func slice(_ sb: CMSampleBuffer) -> CMSampleBuffer? {
        guard let src = CMSampleBufferGetImageBuffer(sb) else { return nil }
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        sourceSize = CGSize(width: w, height: h)
        if pool == nil { makePool() }
        var out: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }

        let sw = Self.stripWidth(w: w, h: h)
        // CIImage's origin is bottom left; the strip is centred and as tall as the frame
        var img = CIImage(cvPixelBuffer: src).cropped(to: CGRect(x: (w - sw) / 2, y: 0, width: sw, height: h))
        img = img.transformed(by: CGAffineTransform(translationX: -CGFloat((w - sw) / 2), y: 0))
        var cur = CGFloat(h)
        while cur / 2 > CGFloat(Self.outH) {                       // halves first, the last step under 2x
            img = Self.lanczos(img, 0.5); cur /= 2
        }
        let k = CGFloat(Self.outH) / cur
        img = Self.lanczos(img, k)
        // the exact output size (rounding of the width): fill 1080×1920, black beyond the strip
        let e = img.extent
        img = img.transformed(by: CGAffineTransform(translationX: -e.minX + (CGFloat(Self.outW) - e.width) / 2, y: -e.minY))
        ci.render(img, to: out, bounds: CGRect(x: 0, y: 0, width: Self.outW, height: Self.outH), colorSpace: nil)

        var fd: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: out, formatDescriptionOut: &fd)
        guard let fd else { return nil }
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sb),
                                        presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sb),
                                        decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sb))
        var made: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: out, formatDescription: fd,
                                                 sampleTiming: &timing, sampleBufferOut: &made)
        return made
    }

    private static func lanczos(_ img: CIImage, _ scale: CGFloat) -> CIImage {
        guard let f = CIFilter(name: "CILanczosScaleTransform") else { return img.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        f.setValue(img, forKey: kCIInputImageKey)
        f.setValue(scale, forKey: kCIInputScaleKey)
        f.setValue(1.0, forKey: kCIInputAspectRatioKey)
        return f.outputImage ?? img
    }
}
