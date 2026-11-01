import AppKit
import AVFoundation

enum Cameras {
    // every kind of camera macOS hands to an app: built-in, USB/UVC webcams and capture cards, the iPhone, Desk View
    static func all() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified).devices
            .sorted { a, b in   // a fixed order: the Mac's own camera first, then by name
                let ai = a.deviceType == .builtInWideAngleCamera, bi = b.deviceType == .builtInWideAngleCamera
                return ai != bi ? ai : a.localizedName.localizedStandardCompare(b.localizedName) == .orderedAscending
            }
    }
}

final class Viewer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "webcamviewer.session")
    private var window: NSWindow!
    private let picture = NSView()
    private let preview: AVCaptureVideoPreviewLayer
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let closeButton = NSButton()
    private let permissions = NSButton()
    private let message = NSTextField(labelWithString: "")
    private var devices: [AVCaptureDevice] = []
    private var current: AVCaptureDevice?
    private let test: Bool
    static let barHeight: CGFloat = 38

    init(test: Bool) {
        self.test = test
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init()
        buildWindow()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(devicesChanged), name: AVCaptureDevice.wasConnectedNotification, object: nil)
        nc.addObserver(self, selector: #selector(devicesChanged), name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
        nc.addObserver(self, selector: #selector(appActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        askCamera()
    }

    // MARK: the window

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 450),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = NAME
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(b)?.isHidden = true }
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.minSize = NSSize(width: 320, height: 180)
        window.isReleasedWhenClosed = false

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = content

        // the bar: the camera menu on the left, PERMISSIONS and ✕ on the right
        // v1, Marko, 1.11.2026: "make the semi-transparent choosing the inputs be overlaid over the picture, and the
        // button should be in the top middle of the screen. But don't sacrifice the viewing area."
        // So the picture fills the whole window and the bar lies over its top edge, half see-through.
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false

        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.target = self; popup.action = #selector(picked)
        popup.controlSize = .regular
        popup.setAccessibilityIdentifier("camera")
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.addSubview(popup)

        permissions.translatesAutoresizingMaskIntoConstraints = false
        permissions.isBordered = false
        permissions.attributedTitle = NSAttributedString(string: "PERMISSIONS", attributes: [
            .foregroundColor: NSColor.systemOrange, .font: NSFont.systemFont(ofSize: 12, weight: .bold)])
        permissions.target = self; permissions.action = #selector(openPrivacy)
        permissions.setAccessibilityIdentifier("permissions")
        permissions.toolTip = "The camera is not allowed: opens Privacy & Security → Camera"
        permissions.isHidden = true
        bar.addSubview(permissions)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.imagePosition = .imageOnly
        closeButton.target = self; closeButton.action = #selector(closeTapped)
        closeButton.setAccessibilityIdentifier("off")
        closeButton.toolTip = "Close"
        bar.addSubview(closeButton)

        picture.translatesAutoresizingMaskIntoConstraints = false
        picture.wantsLayer = true
        picture.layer?.backgroundColor = NSColor.black.cgColor
        preview.videoGravity = .resizeAspect           // the whole picture, never cropped
        preview.backgroundColor = NSColor.black.cgColor
        picture.layer?.addSublayer(preview)
        content.addSubview(picture)

        message.translatesAutoresizingMaskIntoConstraints = false
        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: 15, weight: .medium)
        message.alignment = .center
        message.lineBreakMode = .byWordWrapping
        message.maximumNumberOfLines = 0
        content.addSubview(message)
        content.addSubview(bar)   // last: over the picture

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.barHeight),

            popup.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            popup.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            popup.leadingAnchor.constraint(greaterThanOrEqualTo: bar.leadingAnchor, constant: 10),
            popup.trailingAnchor.constraint(lessThanOrEqualTo: permissions.leadingAnchor, constant: -10),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            closeButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 30),
            closeButton.heightAnchor.constraint(equalToConstant: 30),

            permissions.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            permissions.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            picture.topAnchor.constraint(equalTo: content.topAnchor),
            picture.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            picture.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            message.centerXAnchor.constraint(equalTo: picture.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: picture.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: picture.widthAnchor, constant: -32),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(layoutPreview), name: NSView.frameDidChangeNotification, object: picture)
        picture.postsFrameChangedNotifications = true

        if !window.setFrameUsingName("WebCamViewer") || test { place() }
        window.setFrameAutosaveName("WebCamViewer")
    }

    // first start (and tests): on the MacBook Pro's own screen, never the BenQ
    private func place() {
        let screen = NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains("built") } ?? NSScreen.main
        guard let f = screen?.visibleFrame else { window.center(); return }
        let s = window.frame.size
        window.setFrameOrigin(NSPoint(x: f.midX - s.width / 2, y: f.midY - s.height / 2))
    }

    @objc private func layoutPreview() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        preview.frame = picture.bounds
        CATransaction.commit()
    }

    func show() {
        if test { window.orderFrontRegardless() }     // a test never takes Marko's focus
        else { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        layoutPreview()
    }

    @objc private func closeTapped() { NSApp.terminate(nil) }

    func stop() { queue.sync { if session.isRunning { session.stopRunning() } } }

    // MARK: permission

    private var allowed: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    private func askCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: refresh()
        case .notDetermined:
            say("Waiting for the camera permission…")
            AVCaptureDevice.requestAccess(for: .video) { _ in DispatchQueue.main.async { self.refresh() } }
        default: refresh()
        }
    }

    @objc private func appActive() {
        // back from System Settings: PERMISSIONS goes by itself once the switch is on
        if allowed != permissions.isHidden { refresh() }
    }

    @objc private func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }

    // MARK: cameras

    @objc private func devicesChanged() { DispatchQueue.main.async { self.refresh() } }

    private func refresh() {
        permissions.isHidden = allowed
        devices = Cameras.all()
        popup.removeAllItems()
        if devices.isEmpty {
            popup.addItem(withTitle: "No camera")
            popup.isEnabled = false
            select(nil)
            return
        }
        popup.isEnabled = true
        // the same name twice (two identical webcams) gets a number
        var seen: [String: Int] = [:]
        for d in devices {
            seen[d.localizedName, default: 0] += 1
            let n = seen[d.localizedName]!
            popup.addItem(withTitle: n > 1 ? "\(d.localizedName) (\(n))" : d.localizedName)
        }
        let remembered = current?.uniqueID ?? UserDefaults.standard.string(forKey: "camera")
        let index = devices.firstIndex { $0.uniqueID == remembered } ?? 0
        popup.selectItem(at: index)
        if current?.uniqueID != devices[index].uniqueID || !session.isRunning { select(devices[index]) }
    }

    @objc private func picked() {
        let i = popup.indexOfSelectedItem
        guard i >= 0, i < devices.count else { return }
        UserDefaults.standard.set(devices[i].uniqueID, forKey: "camera")
        select(devices[i])
    }

    private func select(_ device: AVCaptureDevice?) {
        current = device
        guard let device else {
            queue.async { self.session.stopRunning() }
            say("No camera is connected.")
            return
        }
        guard allowed else { say("The camera is not allowed.\nPERMISSIONS, top right, opens the switch."); return }
        say("")
        queue.async {
            self.session.beginConfiguration()
            for i in self.session.inputs { self.session.removeInput(i) }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) { self.session.addInput(input) }
                self.session.sessionPreset = self.session.canSetSessionPreset(.high) ? .high : .medium
            } catch {
                DispatchQueue.main.async { self.say("\(device.localizedName) cannot be opened:\n\(error.localizedDescription)") }
            }
            self.session.commitConfiguration()
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    private func say(_ s: String) { message.stringValue = s; message.isHidden = s.isEmpty }

    // MARK: selftest (the app checks itself: frames arrive and the picture moves)

    private var frames = 0
    private var lumas: [Double] = []
    private var prev: [Double] = []
    private let output = AVCaptureVideoDataOutput()

    func runSelftest(to path: String) {
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "webcamviewer.frames"))
        queue.async { if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) } }
        // the permission prompt is Marko's to answer: wait up to two minutes for it
        var waited = 0.0
        func go() {
            if self.allowed || waited >= 120 || AVCaptureDevice.authorizationStatus(for: .video) == .denied {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh(); self.testNext(0, report: [], to: path) }
            } else { waited += 1; DispatchQueue.main.asyncAfter(deadline: .now() + 1) { go() } }
        }
        go()
    }

    private func testNext(_ i: Int, report: [String], to path: String) {
        var report = report
        if report.isEmpty {
            report.append("\(NAME) v\(VERSION) selftest \(Date())")
            report.append("camera permission: \(allowed ? "allowed" : "NOT allowed")")
            report.append("cameras seen: \(devices.count)")
        }
        guard allowed, i < devices.count else {
            try? report.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
            NSApp.terminate(nil); return
        }
        popup.selectItem(at: i); select(devices[i])   // a test never changes the remembered camera
        frames = 0; lumas = []; prev = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            let diff = self.lumas.isEmpty ? 0 : self.lumas.reduce(0, +) / Double(self.lumas.count)
            report.append(String(format: "%@ | %@ | %d frames in 3 s | mean frame difference %.2f (%@)",
                                 self.devices[i].localizedName, self.devices[i].deviceType.rawValue, self.frames,
                                 diff, diff > 0.3 ? "moving" : "STILL OR FROZEN"))
            self.testNext(i + 1, report: report, to: path)
        }
    }

    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        frames += 1
        guard frames % 5 == 0, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var sample: [Double] = []
        for y in stride(from: 0, to: h, by: 16) { for x in stride(from: 0, to: w, by: 16) {
            let o = y * row + x * 4
            sample.append(0.114 * Double(p[o]) + 0.587 * Double(p[o + 1]) + 0.299 * Double(p[o + 2]))
        } }
        // the frame difference: mean absolute change against the previous sampled frame (video-feed-never-frozen)
        var l = 0.0
        if prev.count == sample.count, !sample.isEmpty { l = zip(sample, prev).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(sample.count) }
        let first = prev.isEmpty
        prev = sample
        if first { return }
        DispatchQueue.main.async { self.lumas.append(l) }
    }
}
