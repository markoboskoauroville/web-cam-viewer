import AppKit
import AVFoundation

private final class WaveformView: NSView {
    var samples: [Float] = [] { didSet { needsDisplay = true } }
    var progress = 0.0 { didSet { needsDisplay = true } }
    var label = ""
    var color: NSColor = .systemGreen
    var seek: ((Double) -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.55).setFill()
        dirtyRect.fill()
        guard !samples.isEmpty, bounds.width > 1 else { return }

        let xWidth = bounds.width
        let middle = bounds.midY
        let amplitude = max(4, bounds.height * 0.42)
        color.withAlphaComponent(0.88).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        let columns = min(samples.count, max(1, Int(xWidth)))
        for column in 0..<columns {
            let first = column * samples.count / columns
            let last = max(first + 1, (column + 1) * samples.count / columns)
            let peak = samples[first..<min(last, samples.count)].reduce(0) { max($0, abs($1)) }
            let x = CGFloat(column) / CGFloat(max(1, columns - 1)) * xWidth
            let h = min(amplitude, CGFloat(peak) * amplitude * 3)
            path.move(to: NSPoint(x: x, y: middle - h))
            path.line(to: NSPoint(x: x, y: middle + h))
        }
        path.stroke()

        if !label.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.8),
            ]
            (label as NSString).draw(at: NSPoint(x: 8, y: 4), withAttributes: attrs)
        }

        let x = bounds.width * progress
        NSColor.systemRed.setFill()
        NSRect(x: x - 1, y: 0, width: 2, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        seek?(min(1, max(0, point.x / bounds.width)))
    }

    override func mouseDragged(with event: NSEvent) { mouseDown(with: event) }
}

final class ReviewPlayer: NSView {
    var onClose: (() -> Void)?
    var onError: ((String) -> Void)?
    var onAutoAlign: (() -> Void)?
    var onLTCSync: (() -> Void)?

    private let videoHost = NSView()
    private let videoLayer = AVPlayerLayer()
    private let selectedWave = WaveformView()
    private let referenceWave = WaveformView()
    private let play = NSButton()
    private let close = NSButton()
    private let autoAlign = NSButton()
    private let phoneTC = NSButton()
    private let readout = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var source: URL?
    private var playable: URL?
    private var duration = 0.0
    private var fps = 30.0
    private var generation = UUID()
    private(set) var isReviewing = false
    var sourceURL: URL? { source }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("review-player")

        videoHost.wantsLayer = true
        videoHost.translatesAutoresizingMaskIntoConstraints = false
        videoHost.layer?.backgroundColor = NSColor.black.cgColor
        videoHost.layer?.addSublayer(videoLayer)
        videoLayer.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect
        addSubview(videoHost)

        for wave in [selectedWave, referenceWave] {
            wave.translatesAutoresizingMaskIntoConstraints = false
            wave.seek = { [weak self] in self?.seek(fraction: $0) }
            addSubview(wave)
        }
        selectedWave.label = "SELECTED AUDIO"
        selectedWave.color = NSColor.systemGreen
        referenceWave.label = "CAMERA REFERENCE"
        referenceWave.color = NSColor.systemBlue

        Self.button(play, "▶  PLAY", self, #selector(togglePlayback))
        play.setAccessibilityTitle("PLAY")
        play.setAccessibilityIdentifier("review-play")
        Self.button(close, "CLOSE", self, #selector(closeTapped))
        close.setAccessibilityIdentifier("review-close")
        Self.button(autoAlign, "AUTO ALIGN", self, #selector(autoAlignTapped))
        autoAlign.setAccessibilityIdentifier("auto-align")
        Self.button(phoneTC, "PHONE TC / LTC", self, #selector(phoneTCTapped))
        phoneTC.setAccessibilityIdentifier("phone-tc-ltc")
        for b in [play, close, autoAlign, phoneTC] {
            b.translatesAutoresizingMaskIntoConstraints = false
            addSubview(b)
        }

        readout.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        readout.textColor = .white
        readout.alignment = .center
        readout.translatesAutoresizingMaskIntoConstraints = false
        readout.setAccessibilityIdentifier("review-time")
        addSubview(readout)

        status.font = .systemFont(ofSize: 12)
        status.textColor = NSColor.white.withAlphaComponent(0.75)
        status.lineBreakMode = .byTruncatingMiddle
        status.translatesAutoresizingMaskIntoConstraints = false
        status.setAccessibilityIdentifier("review-status")
        addSubview(status)

        NSLayoutConstraint.activate([
            videoHost.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            videoHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            videoHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            videoHost.bottomAnchor.constraint(equalTo: selectedWave.topAnchor, constant: -8),

            selectedWave.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            selectedWave.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            selectedWave.heightAnchor.constraint(equalToConstant: 46),
            selectedWave.bottomAnchor.constraint(equalTo: referenceWave.topAnchor, constant: -2),
            referenceWave.leadingAnchor.constraint(equalTo: selectedWave.leadingAnchor),
            referenceWave.trailingAnchor.constraint(equalTo: selectedWave.trailingAnchor),
            referenceWave.heightAnchor.constraint(equalTo: selectedWave.heightAnchor),
            referenceWave.bottomAnchor.constraint(equalTo: play.topAnchor, constant: -8),

            play.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            play.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6),
            autoAlign.leadingAnchor.constraint(equalTo: play.trailingAnchor, constant: 8),
            autoAlign.centerYAnchor.constraint(equalTo: play.centerYAnchor),
            phoneTC.leadingAnchor.constraint(equalTo: autoAlign.trailingAnchor, constant: 8),
            phoneTC.centerYAnchor.constraint(equalTo: play.centerYAnchor),
            readout.centerXAnchor.constraint(equalTo: centerXAnchor),
            readout.centerYAnchor.constraint(equalTo: play.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: play.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        updateReadout()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        videoLayer.frame = videoHost.bounds
    }

    private static func button(_ b: NSButton, _ title: String, _ target: AnyObject, _ action: Selector) {
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 7
        b.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        b.target = target
        b.action = action
        b.heightAnchor.constraint(equalToConstant: 28).isActive = true
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true
    }

    func open(url: URL, fps: Double) {
        closePlayback()
        generation = UUID()
        source = url
        self.fps = max(1, fps)
        duration = 0
        selectedWave.samples = []
        referenceWave.samples = []
        status.stringValue = "Loading \(url.lastPathComponent)…"
        status.textColor = NSColor.white.withAlphaComponent(0.75)
        autoAlign.isEnabled = false
        phoneTC.isEnabled = false
        isHidden = false
        isReviewing = true
        updateReadout()

        let token = generation
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let prepared = try ReviewMedia.playableCopy(of: url)
                let wave0 = ReviewMedia.waveform(of: url, audioTrack: 0)
                let wave1 = ReviewMedia.waveform(of: url, audioTrack: 1)
                guard token == self.generation else { return }
                DispatchQueue.main.async {
                    guard token == self.generation else { return }
                    self.playable = prepared
                    let item = AVPlayerItem(url: prepared)
                    let p = AVPlayer(playerItem: item)
                    self.player = p
                    self.videoLayer.player = p
                    self.duration = CMTimeGetSeconds(item.duration)
                    self.timeObserver = p.addPeriodicTimeObserver(
                        forInterval: CMTime(value: 1, timescale: 30), queue: .main
                    ) { [weak self] _ in self?.updateReadout() }
                    self.selectedWave.samples = wave0
                    self.referenceWave.samples = wave1
                    self.autoAlign.isEnabled = !wave1.isEmpty
                    self.phoneTC.isEnabled = true
                    self.status.stringValue = wave1.isEmpty
                        ? "No camera scratch track: AUTO ALIGN needs two recorded audio tracks."
                        : "←/→ one frame · Shift ←/→ ten frames · Space play/pause · click either waveform to seek"
                    self.status.textColor = NSColor.white.withAlphaComponent(0.75)
                    self.updateReadout()
                    self.needsLayout = true
                }
            } catch {
                DispatchQueue.main.async {
                    guard token == self.generation else { return }
                    let text = "Cannot open \(url.lastPathComponent): \(error.localizedDescription)"
                    self.status.stringValue = text
                    self.status.textColor = NSColor.systemRed
                    self.onError?(text)
                }
            }
        }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard isReviewing else { return false }
        if event.keyCode == 49 && event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            togglePlayback()
            return true
        }
        if event.keyCode == 123 || event.keyCode == 124 {
            step(frames: (event.keyCode == 123 ? -1 : 1) * (event.modifierFlags.contains(.shift) ? 10 : 1))
            return true
        }
        return false
    }

    func setAutoAlignStatus(_ text: String, error: Bool = false) {
        status.stringValue = text
        status.textColor = error ? .systemRed : .systemGreen
        autoAlign.isEnabled = !text.hasPrefix("Measuring")
        phoneTC.isEnabled = !text.hasPrefix("Measuring")
    }

    func closeReview() {
        closeTapped()
    }

    @objc private func togglePlayback() {
        guard let player else { return }
        if player.rate == 0 {
            if duration > 0 && CMTimeGetSeconds(player.currentTime()) >= duration - 0.02 {
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            player.play()
        } else {
            player.pause()
        }
        updatePlayButton()
    }

    private func step(frames: Int) {
        guard let player else { return }
        player.pause()
        let now = CMTimeGetSeconds(player.currentTime())
        let next = min(duration, max(0, now + Double(frames) / fps))
        player.seek(to: CMTime(seconds: next, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
        updatePlayButton()
    }

    private func seek(fraction: Double) {
        guard let player, duration > 0 else { return }
        player.pause()
        player.seek(to: CMTime(seconds: duration * fraction, preferredTimescale: 60000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        updateReadout()
    }

    @objc private func closeTapped() {
        closePlayback()
        isHidden = true
        isReviewing = false
        onClose?()
    }

    @objc private func autoAlignTapped() {
        guard source != nil else { return }
        player?.pause()
        onAutoAlign?()
    }

    @objc private func phoneTCTapped() {
        guard source != nil else { return }
        player?.pause()
        onLTCSync?()
    }

    private func closePlayback() {
        generation = UUID()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        videoLayer.player = nil
    }

    private func updatePlayButton() {
        let playing = (player?.rate ?? 0) != 0
        play.attributedTitle = NSAttributedString(string: playing ? "Ⅱ  PAUSE" : "▶  PLAY", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        play.setAccessibilityValue(playing ? "playing" : "paused")
    }

    private func updateReadout() {
        if let item = player?.currentItem {
            let loaded = CMTimeGetSeconds(item.duration)
            if loaded.isFinite, loaded > 0 { duration = loaded }
        }
        let seconds = player.map { CMTimeGetSeconds($0.currentTime()) } ?? 0
        let safe = seconds.isFinite ? max(0, seconds) : 0
        let frame = Int((safe * fps).rounded(.down)) % max(1, Int(fps.rounded()))
        let all = Int(safe)
        readout.stringValue = String(format: "%02d:%02d:%02d:%02d", all / 3600, (all / 60) % 60, all % 60, frame)
        let progress = duration > 0 ? min(1, safe / duration) : 0
        selectedWave.progress = progress
        referenceWave.progress = progress
        updatePlayButton()
    }
}

private enum ReviewMedia {
    static func ffmpeg() throws -> URL {
        let path = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let path else {
            throw NSError(domain: "ReviewPlayer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "ffmpeg is not installed",
            ])
        }
        return URL(fileURLWithPath: path)
    }

    static func playableCopy(of source: URL) throws -> URL {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = ((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0).rounded()
        let key = "\(source.lastPathComponent)-\(size)-\(Int(modified))"
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("community.auroville.webcamviewer/review", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let output = cache.appendingPathComponent(String(safe) + ".mp4")
        if FileManager.default.fileExists(atPath: output.path) { return output }

        let process = Process()
        process.executableURL = try ffmpeg()
        process.arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-i", source.path,
            "-map", "0:v:0", "-map", "0:a:0?", "-map", "0:a:1?",
            "-c:v", "copy", "-c:a", "aac", "-b:a", "256k",
            "-movflags", "+faststart", output.path,
        ]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let bytes = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) else {
            try? FileManager.default.removeItem(at: output)
            throw NSError(domain: "ReviewPlayer", code: 2, userInfo: [
                NSLocalizedDescriptionKey: String(decoding: bytes, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
            ])
        }
        return output
    }

    static func waveform(of source: URL, audioTrack: Int) -> [Float] {
        guard let ffmpeg = try? ffmpeg() else { return [] }
        let process = Process()
        let output = Pipe()
        process.executableURL = ffmpeg
        process.arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-i", source.path, "-map", "0:a:\(audioTrack)", "-vn",
            "-ac", "1", "-ar", "1000", "-f", "f32le", "-",
        ]
        process.standardOutput = output
        do { try process.run() } catch { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return data.withUnsafeBytes { bytes in
            let values = bytes.bindMemory(to: Float.self)
            return Array(values)
        }
    }
}
