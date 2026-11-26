import Accelerate
import Foundation
import ImageIO
import Vision

struct AlignmentResult {
    let correctionMs: Double
    let quality: Double
    let windows: Int
    let lagSamples: Int
    let method: String
    let spreadMs: Double
}

enum AlignmentError: LocalizedError {
    case noReferenceTrack
    case notEnoughSignal
    case lowConfidence
    case tool(String)

    var errorDescription: String? {
        switch self {
        case .noReferenceTrack:
            return "The take has no camera scratch track. Record with the camera microphone available so there is a reference."
        case .notEnoughSignal:
            return "The selected audio and camera scratch do not contain enough common signal to measure."
        case .lowConfidence:
            return "The measured windows disagree. No delay was changed."
        case .tool(let message):
            return message.isEmpty ? "The analysis tool failed." : message
        }
    }
}

enum SyncAnalyzer {
    static let sampleRate = 48_000

    static func alignAudio(url: URL) throws -> AlignmentResult {
        let duration = try mediaDuration(url)
        let trackCount = try audioTrackCount(url)
        guard trackCount >= 2 else { throw AlignmentError.noReferenceTrack }

        let length = min(4.0, max(0.5, duration))
        guard length >= 0.5 else { throw AlignmentError.notEnoughSignal }
        var starts = duration < 6 ? [0.0] : [1.0, max(1.0, duration * 0.5 - length / 2), max(1.0, duration - length - 1)]
        starts = Array(Set(starts.map { min(max(0, $0), max(0, duration - length)) })).sorted()

        var corrections: [Double] = []
        var qualities: [Double] = []
        for start in starts {
            let selected = try pcm(url: url, track: 0, start: start, length: length)
            let reference = try pcm(url: url, track: 1, start: start, length: length)
            guard !selected.isEmpty, !reference.isEmpty else { continue }
            let n = min(selected.count, reference.count)
            guard n >= sampleRate / 2 else { continue }
            let a = Array(selected.prefix(n))
            let b = Array(reference.prefix(n))
            let fit = correlation(source: a, reference: b, maxLag: sampleRate / 4)
            let side = max(rms(a), rms(b))
            guard side > 0.00001, fit.quality >= 5 else { continue }
            corrections.append(-Double(fit.samples) / Double(sampleRate) * 1000)
            qualities.append(fit.quality)
        }

        guard corrections.count >= 2 || (corrections.count == 1 && duration < 6) else {
            throw AlignmentError.notEnoughSignal
        }
        let correction = median(corrections)
        let spread = corrections.max()! - corrections.min()!
        let quality = min(100, median(qualities))
        guard spread <= 2.0, abs(correction) <= 1000, quality >= 5 else {
            throw AlignmentError.lowConfidence
        }
        return AlignmentResult(
            correctionMs: correction,
            quality: quality,
            windows: corrections.count,
            lagSamples: Int((-correction * Double(sampleRate) / 1000).rounded()),
            method: "selected audio against camera scratch (GCC-PHAT)",
            spreadMs: spread
        )
    }

    static func alignLTC(url: URL) throws -> AlignmentResult {
        let duration = try mediaDuration(url)
        let audioLength = min(6.0, duration)
        let trackCount = try audioTrackCount(url)
        let ltcTrack = trackCount >= 2 ? 1 : 0
        let samples = try pcm(url: url, track: ltcTrack, start: 0, length: audioLength)
        var visual: [(seconds: Double, milliseconds: Int)] = []
        let first = min(0.4, max(0, duration / 4))
        let end = min(duration - 0.1, max(first, 5.0))
        var time = first
        while time <= end {
            if let frame = try frameImage(url: url, at: time),
               let visualMs = recognizeTimecode(frame) {
                visual.append((time, visualMs))
            }
            time += 0.4
        }
        guard visual.count >= 3 else {
            throw AlignmentError.tool("The phone timecode was readable in fewer than three video frames.")
        }

        var corrections: [Double] = []
        var qualities: [Double] = []
        for frame in visual {
            let expected = ltcSamples(milliseconds: frame.milliseconds)
            if let match = matchLTC(expected, in: samples, around: frame.seconds, maxDistance: 0.25) {
                corrections.append(match.correctionMs)
                qualities.append(match.quality)
            }
        }
        guard corrections.count >= 3 else { throw AlignmentError.notEnoughSignal }
        let correction = median(corrections)
        let spread = corrections.max()! - corrections.min()!
        guard abs(correction) <= 1000 else { throw AlignmentError.lowConfidence }
        guard spread <= 50 else {
            throw AlignmentError.tool(String(format:
                "LTC/phone timecode matches disagree (median %.1f ms, spread %.1f ms); move the phone closer or raise its volume and try again.",
                correction, spread))
        }
        return AlignmentResult(
            correctionMs: correction,
            quality: median(qualities),
            windows: corrections.count,
            lagSamples: Int((correction * Double(sampleRate) / 1000).rounded()),
            method: "25 fps phone LTC against the filmed timecode",
            spreadMs: spread
        )
    }

    static func manualMarkerShiftMs(videoSeconds: Double, audioSeconds: Double) -> Double {
        ((videoSeconds - audioSeconds) * 1000 * 1_000).rounded() / 1_000
    }

    static func mathSelfTest() -> Bool {
        let n = 4096
        let delay = 137
        var state: UInt32 = 0x12345678
        let reference = (0..<n).map { _ -> Float in
            state = state &* 1664525 &+ 1013904223
            return Float(Int32(bitPattern: state)) / Float(Int32.max)
        }
        var source = [Float](repeating: 0, count: n)
        for i in delay..<n { source[i] = reference[i - delay] }
        let fit = correlation(source: source, reference: reference, maxLag: 300)
        print("sync math: expected \(delay) samples, measured \(fit.samples), quality \(fit.quality)")
        let fftOK = fit.samples == delay && fit.quality > 5
        let target = (((12 * 60 + 34) * 60 + 56) * 1000) + 17 * 40
        var ltc = [Float](repeating: 0, count: 123)
        ltc += ltcSamples(milliseconds: target)
        ltc += ltcSamples(milliseconds: target + 40)
        let decoded = decodeLTC(ltc)
        let ltcOK = decoded?.milliseconds == target && abs((decoded?.seconds ?? 0) - 123.0 / Double(sampleRate)) < 0.001
        print("LTC decode: \(ltcOK ? "PASS" : "FAIL")")
        let marks = manualMarkerShiftMs(videoSeconds: 2.0, audioSeconds: 2.333333333333)
        let marksOK = abs(marks + 333.333) < 0.001
        print("manual marker math: \(marksOK ? "PASS" : "FAIL") (\(marks) ms)")
        return fftOK && ltcOK && marksOK
    }

    private static func rms(_ values: [Float]) -> Float {
        var sum = Float(0)
        vDSP_svesq(values, 1, &sum, vDSP_Length(values.count))
        return sqrt(sum / Float(max(1, values.count)))
    }

    private static func correlation(source: [Float], reference: [Float], maxLag: Int) -> (samples: Int, quality: Double) {
        let count = min(source.count, reference.count)
        guard count > 0 else { return (0, 0) }
        var size = 1
        while size < count * 2 { size <<= 1 }
        let log2n = vDSP_Length(log2(Float(size)))

        var sourceReal = Array(source.prefix(count)) + [Float](repeating: 0, count: size - count)
        var sourceImag = [Float](repeating: 0, count: size)
        var referenceReal = Array(reference.prefix(count)) + [Float](repeating: 0, count: size - count)
        var referenceImag = [Float](repeating: 0, count: size)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return (0, 0) }
        defer { vDSP_destroy_fftsetup(setup) }

        sourceReal.withUnsafeMutableBufferPointer { sr in
            sourceImag.withUnsafeMutableBufferPointer { si in
                var sourceSplit = DSPSplitComplex(realp: sr.baseAddress!, imagp: si.baseAddress!)
                vDSP_fft_zip(setup, &sourceSplit, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
        referenceReal.withUnsafeMutableBufferPointer { rr in
            referenceImag.withUnsafeMutableBufferPointer { ri in
                var referenceSplit = DSPSplitComplex(realp: rr.baseAddress!, imagp: ri.baseAddress!)
                vDSP_fft_zip(setup, &referenceSplit, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }

        var resultReal = [Float](repeating: 0, count: size)
        var resultImag = [Float](repeating: 0, count: size)
        for i in 0..<size {
            let real = sourceReal[i] * referenceReal[i] + sourceImag[i] * referenceImag[i]
            let imag = sourceImag[i] * referenceReal[i] - sourceReal[i] * referenceImag[i]
            let scale = sqrt(referenceReal[i] * referenceReal[i] + referenceImag[i] * referenceImag[i])
                * sqrt(sourceReal[i] * sourceReal[i] + sourceImag[i] * sourceImag[i])
            if scale > 1e-8 {
                resultReal[i] = real / scale
                resultImag[i] = imag / scale
            }
        }
        resultReal.withUnsafeMutableBufferPointer { rr in
            resultImag.withUnsafeMutableBufferPointer { ri in
                var result = DSPSplitComplex(realp: rr.baseAddress!, imagp: ri.baseAddress!)
                vDSP_fft_zip(setup, &result, 1, log2n, FFTDirection(kFFTDirection_Inverse))
            }
        }

        let limit = min(maxLag, count - 1)
        var bestLag = 0
        var best = Float(0)
        var values: [Float] = []
        for lag in -limit...limit {
            let index = lag >= 0 ? lag : size + lag
            let magnitude = abs(resultReal[index])
            values.append(magnitude)
            if magnitude > best {
                best = magnitude
                bestLag = lag
            }
        }
        let sorted = values.sorted()
        let baseline = Double(sorted[sorted.count / 2]) + 1e-8
        return (bestLag, Double(best) / baseline)
    }

    private static func median<T: FloatingPoint>(_ values: [T]) -> T {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / T(2)
        }
        return sorted[middle]
    }

    private static func mediaDuration(_ url: URL) throws -> Double {
        let output = try run(tool: "ffprobe", [
            "-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", url.path,
        ])
        guard let duration = Double(output.trimmingCharacters(in: .whitespacesAndNewlines)), duration.isFinite else {
            throw AlignmentError.tool("ffprobe could not read the recording duration")
        }
        return duration
    }

    private static func frameImage(url: URL, at seconds: Double) throws -> CGImage? {
            let data = try runData(tool: "ffmpeg", [
                "-nostdin", "-hide_banner", "-loglevel", "error",
                "-ss", String(format: "%.6f", seconds), "-i", url.path,
                "-frames:v", "1", "-f", "image2pipe", "-vcodec", "png", "-",
            ])
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func recognizeTimecode(_ image: CGImage) -> Int? {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.02
            guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else {
                return nil
            }
            let expression = try? NSRegularExpression(
                pattern: #"(?:^|[^0-9])([0-2]\d|[0-9])\s*[:;]\s*([0-5]\d)\s*[:;]\s*([0-5]\d)\s*[:;]\s*([0-9]\d)(?:[^0-9]|$)"#
            )
            for observation in request.results ?? [] {
                guard let text = observation.topCandidates(1).first?.string,
                      let match = expression?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      match.numberOfRanges == 5 else { continue }
                func part(_ index: Int) -> Int? {
                    guard let range = Range(match.range(at: index), in: text) else { return nil }
                    return Int(text[range])
                }
                guard let hour = part(1), let minute = part(2), let second = part(3), let frame = part(4),
                      hour < 24, minute < 60, second < 60, frame < 25 else { continue }
                return (((hour * 60 + minute) * 60 + second) * 1000) + frame * 40
            }
            return nil
    }

    private struct LTCFrame { let seconds: Double; let milliseconds: Int }

    private static func decodeLTC(_ samples: [Float]) -> LTCFrame? {
            let frameSamples = sampleRate / 25
            guard samples.count >= frameSamples * 2 else { return nil }
            let sync = [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1]

            var best: (score: Int, offset: Int, first: Int, second: Int)?
            for offset in 0..<frameSamples {
                guard offset + frameSamples * 2 <= samples.count else { break }
                let decoded = ltcBits(samples, offset: offset)
                var score = 0
                for i in 0..<16 where decoded[64 + i] == sync[i] { score += 1 }
                let secondBits = ltcBits(samples, offset: offset + frameSamples)
                guard score >= 14, let first = ltcMilliseconds(decoded),
                      let second = ltcMilliseconds(secondBits) else { continue }
                let next = (second - first + 86_400_000) % 86_400_000
                guard next == 40 else { continue }
                if best == nil || score > best!.score { best = (score, offset, first, second) }
            }
            guard let best else { return nil }
            return LTCFrame(seconds: Double(best.offset) / Double(sampleRate), milliseconds: best.first)
    }

    private static func ltcBits(_ samples: [Float], offset: Int) -> [Int] {
            let bitSamples = sampleRate / (80 * 25)
            var bits = [Int](repeating: 0, count: 80)
            for bit in 0..<80 {
                let base = offset + bit * bitSamples
                let left = samples[min(samples.count - 1, base + bitSamples / 4)]
                let right = samples[min(samples.count - 1, base + bitSamples * 3 / 4)]
                bits[bit] = (left >= 0) == (right >= 0) ? 0 : 1
            }
            return bits
    }

    private static func ltcMilliseconds(_ bits: [Int]) -> Int? {
            func value(_ at: Int, _ count: Int) -> Int {
                (0..<count).reduce(0) { $0 | (bits[at + $1] << $1) }
            }
            let frame = value(0, 4) + 10 * value(8, 2)
            let second = value(16, 4) + 10 * value(24, 3)
            let minute = value(32, 4) + 10 * value(40, 3)
            let hour = value(48, 4) + 10 * value(56, 2)
            guard hour < 24, minute < 60, second < 60, frame < 25 else { return nil }
            return (((hour * 60 + minute) * 60 + second) * 1000) + frame * 40
    }

    private static func ltcSamples(milliseconds ms: Int) -> [Float] {
            let hour = ms / 3_600_000
            let minute = ms / 60_000 % 60
            let second = ms / 1000 % 60
            let frame = ms % 1000 * 25 / 1000
            var bits = [Int](repeating: 0, count: 80)
            func put(_ at: Int, _ count: Int, _ value: Int) {
                for i in 0..<count { bits[at + i] = (value >> i) & 1 }
            }
            put(0, 4, frame % 10); put(8, 2, frame / 10)
            put(16, 4, second % 10); put(24, 3, second / 10)
            put(32, 4, minute % 10); put(40, 3, minute / 10)
            put(48, 4, hour % 10); put(56, 2, hour / 10)
            let sync = [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1]
            for i in 0..<16 { bits[64 + i] = sync[i] }
            if bits.filter({ $0 == 0 }).count % 2 == 1 { bits[59] = 1 }
            var level: Float = 0.6
            let perBit = sampleRate / (80 * 25)
            var output = [Float]()
            output.reserveCapacity(sampleRate / 25)
            for bit in bits {
                level = -level
                for i in 0..<perBit {
                    if bit == 1 && i == perBit / 2 { level = -level }
                    output.append(level)
                }
            }
            return output
    }

    private struct LTCMatch { let correctionMs: Double; let quality: Double }

    private static func matchLTC(_ template: [Float], in audio: [Float], around seconds: Double,
                                     maxDistance: Double) -> LTCMatch? {
            let stride = 4
            let downTemplate = Swift.stride(from: 0, to: template.count, by: stride).map { template[$0] }
            let center = Int((seconds * Double(sampleRate) / Double(stride)).rounded())
            let radius = Int(maxDistance * Double(sampleRate) / Double(stride))
            let start = max(0, center - radius)
            let end = min((audio.count / stride) - downTemplate.count, center + radius)
            guard end > start else { return nil }

            var templateEnergy = Float(0)
            vDSP_svesq(downTemplate, 1, &templateEnergy, vDSP_Length(downTemplate.count))
            guard templateEnergy > 1e-8 else { return nil }
            var bestStart = start
            var bestScore = 0.0
            for candidate in Swift.stride(from: start, through: end, by: 1) {
                var dot = Float(0), energy = Float(0)
                audio.withUnsafeBufferPointer { buffer in
                    downTemplate.withUnsafeBufferPointer { t in
                        var segment = [Float](repeating: 0, count: t.count)
                        for i in 0..<t.count { segment[i] = buffer[(candidate + i) * stride] }
                        vDSP_dotpr(t.baseAddress!, 1, segment, 1, &dot, vDSP_Length(segment.count))
                        vDSP_svesq(segment, 1, &energy, vDSP_Length(segment.count))
                    }
                }
                let score = energy > 1e-8 ? abs(Double(dot) / sqrt(Double(energy * templateEnergy))) : 0
                if score > bestScore { bestScore = score; bestStart = candidate }
            }
            guard bestScore >= 0.2 else { return nil }

            let coarseSample = bestStart * stride
            var refinedSample = coarseSample
            var refinedScore = bestScore
            let lo = max(0, coarseSample - stride * 2)
            let hi = min(audio.count - template.count, coarseSample + stride * 2)
            if hi >= lo {
                template.withUnsafeBufferPointer { t in
                    audio.withUnsafeBufferPointer { buffer in
                        var dot = Float(0), energy = Float(0)
                        for candidate in lo...hi {
                            vDSP_dotpr(t.baseAddress!, 1, buffer.baseAddress! + candidate, 1, &dot, vDSP_Length(t.count))
                            vDSP_svesq(buffer.baseAddress! + candidate, 1, &energy, vDSP_Length(t.count))
                            let score = energy > 1e-8 ? abs(Double(dot) / sqrt(Double(energy * Float(templateEnergy)))) : 0
                            if score > refinedScore {
                                refinedScore = score
                                refinedSample = candidate
                            }
                            dot = 0; energy = 0
                        }
                    }
                }
            }
            let audioTime = Double(refinedSample) / Double(sampleRate)
            return LTCMatch(correctionMs: (seconds - audioTime) * 1000, quality: refinedScore)
    }

    private static func audioTrackCount(_ url: URL) throws -> Int {
        let output = try run(tool: "ffprobe", [
            "-v", "error", "-select_streams", "a",
            "-show_entries", "stream=index", "-of", "csv=p=0", url.path,
        ])
        return output.split(whereSeparator: \.isNewline).count
    }

    private static func pcm(url: URL, track: Int, start: Double, length: Double) throws -> [Float] {
        let output = try runData(tool: "ffmpeg", [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-ss", String(format: "%.6f", start), "-i", url.path,
            "-t", String(format: "%.6f", length), "-map", "0:a:\(track)", "-vn",
            "-ac", "1", "-ar", "\(sampleRate)", "-f", "f32le", "-",
        ])
        return output.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Float.self))
        }
    }

    private static func executable(_ name: String) throws -> URL {
        let paths = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AlignmentError.tool("\(name) is not installed")
        }
        return URL(fileURLWithPath: path)
    }

    private static func run(tool: String, _ arguments: [String]) throws -> String {
        String(decoding: try runData(tool: tool, arguments), as: UTF8.self)
    }

    private static func runData(tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        let standardOutput = Pipe()
        let errors = Pipe()
        process.executableURL = try executable(tool)
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = errors
        try process.run()
        let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AlignmentError.tool(String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }
}
