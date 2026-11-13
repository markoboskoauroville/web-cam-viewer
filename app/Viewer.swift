import AppKit
import AVFoundation

enum Cameras {
    // every kind of camera macOS hands to an app: built-in, USB/UVC webcams and capture cards, the iPhone, Desk View
    static func all() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified).devices
            .sorted { a, b in   // a fixed order: the Sony first (as in the classroom, v5), the Mac's own camera, then by name
                let asn = KeepStreaming.isSony(a), bsn = KeepStreaming.isSony(b)
                if asn != bsn { return asn }
                let ai = a.deviceType == .builtInWideAngleCamera, bi = b.deviceType == .builtInWideAngleCamera
                return ai != bi ? ai : a.localizedName.localizedStandardCompare(b.localizedName) == .orderedAscending
            }
    }
    // every sound input: the Mac's microphone, USB interfaces, BlackHole, the iPhone
    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
            .sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
    }
}

final class Viewer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "webcamviewer.session")
    private let captureQueue = DispatchQueue(label: "webcamviewer.capture")
    private var window: NSWindow!
    private let picture = NSView()
    private let preview: AVCaptureVideoPreviewLayer
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let micPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let recKey = RecordKey()
    let sonyBar = SonyBar()
    let sony = SonyCamera()
    private let keepStreaming = KeepStreaming()
    private let closeButton = NSButton()
    private let fullKey = FullKey()
    private var overlays: [NSView] = []
    private var meterTop: NSLayoutConstraint!
    private let permissions = NSButton()
    private let message = NSTextField(labelWithString: "")
    private let meter = StereoMeter()
    private let timecode = NSTextField(labelWithString: "")
    private var devices: [AVCaptureDevice] = []
    // v5: every camera is followed by its "· vertical slice" entry; an entry is (camera index, slice?)
    private var entries: [(device: Int, slice: Bool)] = []
    private let slicer = Slicer()
    private var api: ApiServer?
    // v7: the chosen camera is kept by its unique id (and model name) even while it is unplugged: no falling over to another one
    private var wantedID: String? = UserDefaults.standard.string(forKey: "camera")
    private var wantedName: String? = UserDefaults.standard.string(forKey: "cameraName")
    private var waiting = false                 // the chosen camera is not there
    private var micWaiting = false              // the chosen sound input is not there
    private var interrupted = false             // the last take ended because the camera or the sound went away
    private let overlay = ChoiceOverlay()
    private var recStart: Date?
    private var lastTake: String?
    private var currentTake: String?
    private var lastLevels: [Float] = []
    private let sliceLayer = AVSampleBufferDisplayLayer()
    private var sliceOn = false                        // capture queue
    private var horizontalSize: NSSize?                // the window's size before a slice, to go back to
    static let sliceSuffix = " · vertical slice"
    static func sliceKey(_ d: AVCaptureDevice) -> String { "slice.\(d.uniqueID)" }
    private var mics: [AVCaptureDevice] = []
    private var current: AVCaptureDevice?
    private var currentMic: AVCaptureDevice?
    private var videoIn: AVCaptureDeviceInput?
    private var audioIn: AVCaptureDeviceInput?
    private let videoOut = AVCaptureVideoDataOutput()
    private let audioOut = AVCaptureAudioDataOutput()
    private var fps: Int32 = 30
    private var lastAudioFormat: CMFormatDescription?   // capture queue
    private var recorder: Recorder?                     // capture queue
    private var tcTimer: Timer?
    private var liveFrames = 0          // capture queue: frames of the chosen camera
    private var watchdog: Timer?
    private var lastSeen = 0
    private var silentTicks = 0
    private let test: Bool
    static let barHeight: CGFloat = 38

    init(test: Bool) {
        self.test = test
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init()
        buildWindow()
        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        videoOut.alwaysDiscardsLateVideoFrames = false
        videoOut.setSampleBufferDelegate(self, queue: captureQueue)
        audioOut.setSampleBufferDelegate(self, queue: captureQueue)
        queue.async {
            self.session.beginConfiguration()
            if self.session.canAddOutput(self.videoOut) { self.session.addOutput(self.videoOut) }
            if self.session.canAddOutput(self.audioOut) { self.session.addOutput(self.audioOut) }
            self.session.commitConfiguration()
        }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(devicesChanged), name: AVCaptureDevice.wasConnectedNotification, object: nil)
        nc.addObserver(self, selector: #selector(devicesChanged), name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
        nc.addObserver(self, selector: #selector(devicesChanged), name: AVCaptureSession.wasInterruptedNotification, object: nil)
        nc.addObserver(self, selector: #selector(devicesChanged), name: AVCaptureSession.interruptionEndedNotification, object: nil)
        nc.addObserver(self, selector: #selector(appActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        askAccess()
        startSony()
        api = ApiServer(viewer: self); api?.start()
        // no frame from the chosen camera for 3 s while it should run: open it again (another app or the keeper may
        // have held it when it was chosen)
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkFrames() }
    }

    // MARK: the Sony (v4): the group in the bar while it is connected, a click on the picture a touch on its screen

    private func startSony() {
        sonyBar.rec.target = self; sonyBar.rec.action = #selector(sonyRec)
        sonyBar.focus.target = self; sonyBar.focus.action = #selector(sonyFocus)
        sony.log = { NSLog("Sony: %@", $0) }
        sony.onConnected = { [weak self] on in self?.updateSonyBar() }
        sony.onChange = { [weak self] st in
            guard let self else { return }
            self.sonyBar.setRecording(st.recording)
            self.sonyBar.setFocused(st.focused)
            self.sonyBar.setBattery(st.battery)
            self.sonyBar.aperture.stringValue = SonyCamera.fText(st.fnumber)
            self.sonyBar.shutter.stringValue = SonyCamera.shutterText(st.shutter)
            self.sonyBar.iso.stringValue = SonyCamera.isoText(st.iso)
            self.sonyBar.name.stringValue = st.model
        }
        sony.start()
        let click = NSClickGestureRecognizer(target: self, action: #selector(pictureClicked(_:)))
        picture.addGestureRecognizer(click)
    }

    /// the group shows while a Sony is reachable: green-able over PTP (Remote Shoot), all grey while the chosen picture is
    /// the Sony itself streaming over USB (nothing can be controlled then)
    /// the Sony kept on Streaming:Output while it is not the chosen camera (the chosen one is open anyway)
    private func holdSony() {
        guard cameraAllowed else { return }
        let sony = devices.first { KeepStreaming.isSony($0) && $0.uniqueID != current?.uniqueID }
        keepStreaming.hold(sony)
    }

    func updateSonyBar() {
        let streamingSony = current.map { $0.localizedName.uppercased().hasPrefix("ILCE") || $0.manufacturer.uppercased().contains("SONY") } ?? false
        if sony.ready {
            sonyBar.isHidden = false
            sonyBar.setControllable(true, name: sony.state.model)
            sony.onChange?(sony.state)
        } else if streamingSony, let c = current {
            sonyBar.isHidden = false
            sonyBar.setControllable(false, name: c.localizedName)
        } else {
            sonyBar.isHidden = true
        }
    }

    private func checkFrames() {
        guard let cur = current, cameraAllowed else { silentTicks = 0; return }
        var n = 0
        captureQueue.sync { n = liveFrames }
        if n != lastSeen { lastSeen = n; silentTicks = 0; if message.stringValue.hasPrefix("No picture") { say("") }; return }
        silentTicks += 1
        if silentTicks == 3 {
            NSLog("Webcam Recorder: no frames from %@, opening it again", cur.localizedName)
            select(cur)
        } else if silentTicks == 8 {
            say("No picture from \(cur.localizedName).\nAnother app may hold it, or the camera sends nothing.")
        }
    }

    @objc private func sonyRec() { sony.toggleRecord() }
    @objc private func sonyFocus() { sony.focus() }

    @objc private func pictureClicked(_ g: NSClickGestureRecognizer) {
        // v7: a click opens the camera and sound choice; Option-click is the touch focus on the Sony (v4)
        if !NSEvent.modifierFlags.contains(.option) || !sony.ready { showChoice(); return }
        let p = g.location(in: picture)
        if !sliceLayer.isHidden {    // v5: a point on the vertical picture is a point inside the middle strip of the frame
            let r = AVMakeRect(aspectRatio: CGSize(width: Slicer.outW, height: Slicer.outH), insideRect: picture.bounds)
            let nx = (p.x - r.minX) / r.width, ny = 1 - (p.y - r.minY) / r.height
            let src = slicer.sourceSize
            guard (0...1).contains(nx), (0...1).contains(ny), src.width > 0 else { return }
            let fw = CGFloat(Slicer.stripWidth(w: Int(src.width), h: Int(src.height))) / src.width
            sony.touch(nx: (1 - fw) / 2 + nx * fw, ny: ny)
            return
        }
        // the view's point in the preview layer's own coordinates, then the picture's 0…1, top-left origin
        // (the letterbox bands fall outside 0…1 and do nothing)
        let lp = picture.layer.map { $0.convert(p, to: preview) } ?? p
        let d = preview.captureDevicePointConverted(fromLayerPoint: lp)
        guard (0...1).contains(d.x), (0...1).contains(d.y) else { return }
        sony.touch(nx: d.x, ny: d.y)
    }

    // MARK: v7, the choice on a click

    private func showChoice() {
        guard overlay.isHidden else { overlay.close(); return }
        var cams: [ChoiceOverlay.Row] = []
        for (i, d) in devices.enumerated() {
            for slice in [false, true] {
                let cur = d.uniqueID == wantedID && savedSlice(d) == slice
                cams.append(ChoiceOverlay.Row(title: d.localizedName + (slice ? Self.sliceSuffix : ""), current: cur,
                                  action: { [weak self] in self?.chooseCamera(i, slice: slice) }))
            }
        }
        if cams.isEmpty { cams.append(ChoiceOverlay.Row(title: "No camera", current: false, action: {})) }
        let sid = UserDefaults.standard.bool(forKey: "nosound") ? nil : UserDefaults.standard.string(forKey: "sound")
        var snd: [ChoiceOverlay.Row] = []
        for (i, m) in mics.enumerated() {
            snd.append(ChoiceOverlay.Row(title: m.localizedName, current: m.uniqueID == sid, action: { [weak self] in self?.chooseMic(i) }))
        }
        snd.append(ChoiceOverlay.Row(title: "No sound", current: sid == nil, action: { [weak self] in self?.chooseMic(nil) }))
        overlay.show(cameras: cams, sounds: snd)
    }

    /// the one way a camera is chosen (menu, overlay, API): remembered by id and name, slice remembered per camera
    private func chooseCamera(_ i: Int, slice: Bool) {
        guard i >= 0, i < devices.count else { return }
        let d = devices[i]
        wantedID = d.uniqueID; wantedName = d.localizedName
        UserDefaults.standard.set(d.uniqueID, forKey: "camera")
        UserDefaults.standard.set(d.localizedName, forKey: "cameraName")
        UserDefaults.standard.set(slice, forKey: Self.sliceKey(d))
        popup.selectItem(at: entryIndex(i, slice: slice))
        if current?.uniqueID == d.uniqueID && !waiting {   // the same camera: only the picture changes, the camera stays open
            if isRecording { stopRecording() }
            applyMode(slice)
        } else { select(d) }
    }

    private func chooseMic(_ i: Int?) {
        if let i, i >= 0, i < mics.count {
            UserDefaults.standard.set(false, forKey: "nosound")
            micPopup.selectItem(at: i)
            selectMic(mics[i])
        } else {
            UserDefaults.standard.set(true, forKey: "nosound")
            micPopup.selectItem(at: mics.count)
            selectMic(nil)
        }
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
        window.minSize = NSSize(width: 420, height: 200)
        window.isReleasedWhenClosed = false

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = content

        // v1, Marko, 1.11.2026: "make the semi-transparent choosing the inputs be overlaid over the picture, and the
        // button should be in the top middle of the screen. But don't sacrifice the viewing area."
        // v2: "next to the cam input, you also need to bring in audio input ... I also need a record button"
        // So the picture fills the whole window; over its top edge a half see-through bar: camera · sound · ● centred.
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false

        for (p, id, tip) in [(popup, "camera", "The camera"), (micPopup, "sound", "The sound input")] {
            p.cell = ShortPopUpCell(textCell: "", pullsDown: false)   // eight characters of the name (v4)
            p.target = self
            p.controlSize = .regular
            p.setAccessibilityIdentifier(id)
            p.toolTip = tip
            p.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            p.widthAnchor.constraint(equalToConstant: 104).isActive = true
        }
        popup.action = #selector(picked)
        micPopup.action = #selector(pickedMic)

        recKey.isBordered = false
        recKey.title = ""
        recKey.target = self; recKey.action = #selector(toggleRecord)
        recKey.setAccessibilityIdentifier("rec")
        recKey.setAccessibilityLabel("Record")
        recKey.toolTip = "Record: ~/Movies/mb_<date>_<time>.mov, H.265 1080p 10 Mb/s with time code"
        recKey.widthAnchor.constraint(equalToConstant: 30).isActive = true
        recKey.heightAnchor.constraint(equalToConstant: 30).isActive = true

        sonyBar.isHidden = true   // only while a Sony is connected
        let group = NSStackView(views: [popup, micPopup, recKey, sonyBar])
        group.detachesHiddenViews = true
        group.orientation = .horizontal
        group.spacing = 10
        group.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(group)

        permissions.translatesAutoresizingMaskIntoConstraints = false
        permissions.isBordered = false
        permissions.attributedTitle = NSAttributedString(string: "PERMISSIONS", attributes: [
            .foregroundColor: NSColor.systemOrange, .font: NSFont.systemFont(ofSize: 12, weight: .bold)])
        permissions.target = self; permissions.action = #selector(openPrivacy)
        permissions.setAccessibilityIdentifier("permissions")
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

        // full screen: only the picture; ⌘F in, Escape out (Marko, 1.11.2026)
        fullKey.translatesAutoresizingMaskIntoConstraints = false
        fullKey.isBordered = false; fullKey.title = ""
        fullKey.target = self; fullKey.action = #selector(toggleFull)
        fullKey.setAccessibilityIdentifier("full")
        fullKey.setAccessibilityLabel("Full screen")
        fullKey.toolTip = "Full screen (⌘F), Escape goes back"
        bar.addSubview(fullKey)

        picture.translatesAutoresizingMaskIntoConstraints = false
        picture.wantsLayer = true
        picture.layer?.backgroundColor = NSColor.black.cgColor
        preview.videoGravity = .resizeAspect           // the whole picture, never cropped
        preview.backgroundColor = NSColor.black.cgColor
        picture.layer?.addSublayer(preview)
        sliceLayer.videoGravity = .resizeAspect          // the whole vertical picture, never cropped
        sliceLayer.backgroundColor = NSColor.black.cgColor
        sliceLayer.isHidden = true
        picture.layer?.addSublayer(sliceLayer)
        content.addSubview(picture)

        message.translatesAutoresizingMaskIntoConstraints = false
        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: 15, weight: .medium)
        message.alignment = .center
        message.lineBreakMode = .byWordWrapping
        message.maximumNumberOfLines = 0
        content.addSubview(message)

        // the meters: two hairlines (L, R) down the left edge, under the bar
        meter.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(meter)

        // REC  HH:MM:SS:FF bottom middle while recording: REC red, the time code white, a black shadow, no box
        timecode.translatesAutoresizingMaskIntoConstraints = false
        timecode.isHidden = true
        let sh = NSShadow(); sh.shadowColor = .black; sh.shadowBlurRadius = 3; sh.shadowOffset = .zero
        timecode.shadow = sh
        timecode.setAccessibilityIdentifier("timecode")
        content.addSubview(timecode)

        content.addSubview(bar)   // last: over the picture
        overlay.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(overlay, positioned: .below, relativeTo: bar)   // the bar stays usable over it
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: content.topAnchor), overlay.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: content.leadingAnchor), overlay.trailingAnchor.constraint(equalTo: content.trailingAnchor)])
        overlays = [bar]   // v4: full screen keeps the meters and the REC time code (Marko, 1.11.2026)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(enteredFull), name: NSWindow.willEnterFullScreenNotification, object: window)
        nc.addObserver(self, selector: #selector(leftFull), name: NSWindow.didExitFullScreenNotification, object: window)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.window else { return e }
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            if mods == .command, e.charactersIgnoringModifiers?.lowercased() == "f" { self.toggleFull(); return nil }
            if e.keyCode == 53, !self.overlay.isHidden { self.overlay.close(); return nil }   // Escape closes the choice
            if e.keyCode == 53, self.isFull { self.toggleFull(); return nil }   // Escape
            return e
        }

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.barHeight),

            // v4: the menus to the left, the Sony after them (Marko: "push camera choice and microphone choice to the left side")
            group.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            group.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            group.trailingAnchor.constraint(lessThanOrEqualTo: permissions.leadingAnchor, constant: -10),

            closeButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 30),
            closeButton.heightAnchor.constraint(equalToConstant: 30),

            fullKey.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            fullKey.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            fullKey.widthAnchor.constraint(equalToConstant: 30),
            fullKey.heightAnchor.constraint(equalToConstant: 30),

            permissions.trailingAnchor.constraint(equalTo: fullKey.leadingAnchor, constant: -8),
            permissions.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            picture.topAnchor.constraint(equalTo: content.topAnchor),
            picture.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            picture.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            meter.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            meter.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            meter.widthAnchor.constraint(equalToConstant: StereoMeter.width),

            timecode.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            timecode.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),

            message.centerXAnchor.constraint(equalTo: picture.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: picture.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: picture.widthAnchor, constant: -32),
        ])
        meterTop = meter.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.barHeight)
        meterTop.isActive = true
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
        sliceLayer.frame = picture.bounds
        CATransaction.commit()
    }

    func show() {
        if test { window.orderFrontRegardless() }     // a test never takes Marko's focus
        if CommandLine.arguments.contains("--hover-rec") { recKey.hovering = true }   // the hover drawn without his mouse
        else { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        layoutPreview()
    }

    @objc private func closeTapped() { NSApp.terminate(nil) }

    // MARK: full screen: the picture and nothing else

    private var isFull: Bool { window.styleMask.contains(.fullScreen) }
    @objc private func toggleFull() { window.toggleFullScreen(nil) }
    @objc private func enteredFull() {
        overlays.forEach { $0.isHidden = true }
        meterTop.constant = 0   // the meters the whole height
        NSCursor.setHiddenUntilMouseMoves(true)
    }
    @objc private func leftFull() {
        overlays.forEach { $0.isHidden = false }
        meterTop.constant = Self.barHeight
    }

    /// stops a running take cleanly (the file is closed), then the session
    func stop(_ done: (() -> Void)? = nil) {
        api?.stop()
        keepStreaming.stop()
        var r: Recorder?
        captureQueue.sync { r = recorder; recorder = nil }
        let end = { self.queue.async { if self.session.isRunning { self.session.stopRunning() }; DispatchQueue.main.async { done?() } } }
        if let r { r.finish { _ in end() } } else { end() }
    }

    // MARK: permissions

    private var cameraAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }
    private var micAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    private func askAccess() {
        let ask = { (t: AVMediaType, next: @escaping () -> Void) in
            if AVCaptureDevice.authorizationStatus(for: t) == .notDetermined {
                AVCaptureDevice.requestAccess(for: t) { _ in DispatchQueue.main.async { next() } }
            } else { next() }
        }
        if !cameraAllowed { say("Waiting for the camera permission…") }
        ask(.video) { ask(.audio) { self.refresh() } }
    }

    @objc private func appActive() {
        // back from System Settings: PERMISSIONS goes by itself once the switches are on
        if (cameraAllowed && micAllowed) != permissions.isHidden { refresh() }
    }

    @objc private func openPrivacy() {
        let pane = cameraAllowed ? "Privacy_Microphone" : "Privacy_Camera"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    // MARK: cameras and sound inputs

    @objc private func devicesChanged() { DispatchQueue.main.async { self.refresh() } }

    private func fill(_ p: NSPopUpButton, _ list: [AVCaptureDevice]) {
        p.removeAllItems()
        var seen: [String: Int] = [:]
        for d in list {
            seen[d.localizedName, default: 0] += 1
            let n = seen[d.localizedName]!
            p.addItem(withTitle: n > 1 ? "\(d.localizedName) (\(n))" : d.localizedName)
        }
    }

    /// v5: the camera menu: each camera, then "<camera> · vertical slice"
    private func fillCameras() {
        popup.removeAllItems()
        entries = []
        var seen: [String: Int] = [:]
        for (i, d) in devices.enumerated() {
            seen[d.localizedName, default: 0] += 1
            let n = seen[d.localizedName]!
            let name = n > 1 ? "\(d.localizedName) (\(n))" : d.localizedName
            popup.addItem(withTitle: name); entries.append((i, false))
            popup.addItem(withTitle: name + Self.sliceSuffix); entries.append((i, true))
        }
    }
    private func entryIndex(_ device: Int, slice: Bool) -> Int { entries.firstIndex { $0.device == device && $0.slice == slice } ?? 0 }
    private func savedSlice(_ d: AVCaptureDevice) -> Bool { UserDefaults.standard.bool(forKey: Self.sliceKey(d)) }

    private func refresh() {
        permissions.isHidden = cameraAllowed && micAllowed
        permissions.toolTip = !cameraAllowed ? "The camera is not allowed: opens Privacy & Security → Camera"
            : "The microphone is not allowed: opens Privacy & Security → Microphone"

        devices = Cameras.all()
        // v7: the chosen camera went away while a take runs: the take is stopped and saved, and says so
        if let c = current, isRecording, !devices.contains(where: { $0.uniqueID == c.uniqueID }) { stopRecording(); interrupted = true }
        if devices.isEmpty { popup.removeAllItems(); popup.addItem(withTitle: "No camera") } else { fillCameras() }
        var found: Int?
        if let id = wantedID {
            found = devices.firstIndex { $0.uniqueID == id }
            if found == nil, let n = wantedName, let f = devices.firstIndex(where: { $0.localizedName == n }) {
                // the same model under a new id: it is the same camera; its slice choice moves with it
                found = f
                UserDefaults.standard.set(UserDefaults.standard.bool(forKey: "slice." + id), forKey: Self.sliceKey(devices[f]))
                wantedID = devices[f].uniqueID
                UserDefaults.standard.set(wantedID, forKey: "camera")
            }
        } else if !devices.isEmpty {                       // the very first start: the first camera in the list
            found = 0; wantedID = devices[0].uniqueID
            UserDefaults.standard.set(wantedID, forKey: "camera")
        }
        if let f = found {
            waiting = false
            popup.isEnabled = true
            wantedName = devices[f].localizedName
            UserDefaults.standard.set(wantedName, forKey: "cameraName")
            popup.selectItem(at: entryIndex(f, slice: savedSlice(devices[f])))
            if current?.uniqueID != devices[f].uniqueID || !session.isRunning { select(devices[f]) }
        } else if wantedID != nil {
            enterWaiting()
        } else {
            popup.isEnabled = false
            select(nil)
        }

        // the sound: every input, then "No sound"; the first time the Mac's own default input
        mics = Cameras.microphones()
        fill(micPopup, mics)
        micPopup.addItem(withTitle: "No sound")
        let noSound = UserDefaults.standard.bool(forKey: "nosound")
        let ud = UserDefaults.standard
        let savedMic = ud.string(forKey: "sound")
        if noSound || (mics.isEmpty && savedMic == nil) {
            micWaiting = false
            micPopup.selectItem(at: mics.count)
            if currentMic != nil || audioIn != nil { selectMic(nil) }
        } else {
            // v7: the chosen input by id, else the same model name; if it is not there the sound waits for it (no other input)
            var mi: Int?
            if let id = savedMic ?? currentMic?.uniqueID {
                mi = mics.firstIndex { $0.uniqueID == id }
                if mi == nil, let n = ud.string(forKey: "soundName") { mi = mics.firstIndex { $0.localizedName == n } }
            } else if let d = AVCaptureDevice.default(for: .audio) { mi = mics.firstIndex { $0.uniqueID == d.uniqueID } }
            if let mi {
                micWaiting = false
                micPopup.selectItem(at: mi)
                if currentMic?.uniqueID != mics[mi].uniqueID || audioIn == nil { selectMic(mics[mi]) }
            } else if savedMic != nil {
                micWaiting = true
                micPopup.selectItem(at: -1)
                if isRecording, currentMic != nil { interrupted = true }
                if currentMic != nil || audioIn != nil { selectMic(nil) }
            } else {
                micPopup.selectItem(at: mics.count)
            }
        }
    }

    /// v7: the chosen camera is not connected: keep its id, show a dark frame with the message, never another camera
    private func enterWaiting() {
        waiting = true
        current = nil
        queue.async { if let v = self.videoIn { self.session.beginConfiguration(); self.session.removeInput(v); self.videoIn = nil; self.session.commitConfiguration() } }
        preview.isHidden = true; sliceLayer.isHidden = true; sliceLayer.flushAndRemoveImage()
        popup.isEnabled = !devices.isEmpty
        popup.selectItem(at: -1)
        say("Waiting for \(wantedName ?? "the camera")…")
        updateSonyBar()
        holdSony()
    }

    @objc private func picked() {
        let e = popup.indexOfSelectedItem
        guard e >= 0, e < entries.count else { return }
        chooseCamera(entries[e].device, slice: entries[e].slice)
    }

    @objc private func pickedMic() {
        let i = micPopup.indexOfSelectedItem
        chooseMic(i >= 0 && i < mics.count ? i : nil)
    }

    private func select(_ device: AVCaptureDevice?) {
        if isRecording { stopRecording() }   // a take never changes camera halfway
        current = device
        waiting = false
        applyMode(device.map { savedSlice($0) } ?? false)
        updateSonyBar()
        holdSony()
        guard let device else {
            queue.async { if let v = self.videoIn { self.session.removeInput(v); self.videoIn = nil } }
            say("No camera is connected.")
            return
        }
        guard cameraAllowed else { say("The camera is not allowed.\nPERMISSIONS, top right, opens the switch."); return }
        say("")
        // the keeper lets go of this Sony before the picture opens it (both at once left the picture black)
        if KeepStreaming.isSony(device) { keepStreaming.releaseNow() }
        queue.async {
            self.session.beginConfiguration()
            if let v = self.videoIn { self.session.removeInput(v); self.videoIn = nil }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) { self.session.addInput(input); self.videoIn = input }
                self.session.sessionPreset = self.session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080
                    : self.session.canSetSessionPreset(.high) ? .high : .medium
            } catch {
                DispatchQueue.main.async { self.say("\(device.localizedName) cannot be opened:\n\(error.localizedDescription)") }
            }
            self.session.commitConfiguration()
            self.fps = Self.wholeFrameRate(device)
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    /// v5: horizontal (the camera's own preview) or vertical slice (the sliced frames); the window fits the picture
    private func applyMode(_ slice: Bool) {
        captureQueue.async { self.sliceOn = slice }
        preview.isHidden = slice
        sliceLayer.isHidden = !slice
        if !slice { sliceLayer.flushAndRemoveImage() }
        guard !isFull, let cv = window.contentView else { return }
        let cs = cv.frame.size
        if slice, cs.width > cs.height * 0.6 {
            horizontalSize = cs
            let room = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
            let h = min(max(cs.height, 720), room - 60), w = (h * 9 / 16).rounded()
            window.setContentSize(NSSize(width: w, height: h))
        } else if !slice, cs.height > cs.width {
            window.setContentSize(horizontalSize ?? NSSize(width: 800, height: 450))
        } else { return }
        if let s = window.screen { window.setFrame(window.constrainFrameRect(window.frame, to: s), display: true) }
    }

    // the time code counts whole frames: the camera is set to a whole rate (30, else 25, 24, 60, 50) where it can be,
    // so the frames and the clock agree; the rate it ends up on, rounded, is the time code's
    private static func wholeFrameRate(_ d: AVCaptureDevice) -> Int32 {
        let ranges = d.activeFormat.videoSupportedFrameRateRanges
        for r in [30.0, 25, 24, 60, 50] where ranges.contains(where: { $0.minFrameRate <= r && r <= $0.maxFrameRate }) {
            if (try? d.lockForConfiguration()) != nil {
                d.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(r))
                d.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(r))
                d.unlockForConfiguration()
            }
            return Int32(r)
        }
        let dur = CMTimeGetSeconds(d.activeVideoMinFrameDuration)
        return dur > 0 ? Int32(max(1, min(120, (1 / dur).rounded()))) : 30
    }

    private func selectMic(_ device: AVCaptureDevice?) {
        if isRecording { stopRecording() }
        currentMic = device
        if let device { UserDefaults.standard.set(device.uniqueID, forKey: "sound"); UserDefaults.standard.set(device.localizedName, forKey: "soundName") }
        meter.dead = device == nil || !micAllowed
        queue.async {
            self.session.beginConfiguration()
            if let a = self.audioIn { self.session.removeInput(a); self.audioIn = nil }
            if let device, self.micAllowed, let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) {
                self.session.addInput(input); self.audioIn = input
            }
            self.session.commitConfiguration()
            self.captureQueue.async { self.lastAudioFormat = nil }
        }
    }

    private func say(_ s: String) { message.stringValue = s; message.isHidden = s.isEmpty }

    // MARK: recording

    var isRecording: Bool { recKey.recording }

    @objc func toggleRecord() { isRecording ? stopRecording() : startRecording() }

    func startRecording(title: String? = nil, _ started: ((URL?) -> Void)? = nil) {
        guard current != nil, cameraAllowed else { say("No camera to record."); started?(nil); return }
        let fps = self.fps
        captureQueue.async {
            do {
                let r = try Recorder(fps: fps, vertical: self.sliceOn, title: title, audioFormat: self.audioIn == nil ? nil : self.lastAudioFormat)
                self.recorder = r
                DispatchQueue.main.async { self.interrupted = false; self.currentTake = r.url.path; self.recStart = Date(); self.recordingStarted(fps: fps); started?(r.url) }
            } catch {
                DispatchQueue.main.async { self.say("Cannot record:\n\(error.localizedDescription)"); started?(nil) }
            }
        }
    }

    private func recordingStarted(fps: Int32) {
        recKey.recording = true
        recKey.toolTip = "Stop recording"
        timecode.isHidden = false
        showTimecode(fps)
        tcTimer = Timer.scheduledTimer(withTimeInterval: 1 / Double(fps) / 2, repeats: true) { _ in self.showTimecode(fps) }
    }

    // the real-time clock, the same clock the file's time code starts from
    private func showTimecode(_ fps: Int32) {
        let t = Recorder.timecode(Date(), fps: fps).text
        let s = NSMutableAttributedString(string: "REC  ", attributes: [
            .foregroundColor: NSColor(srgbRed: 1, green: 0.231, blue: 0.188, alpha: 1),
            .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .bold)])
        s.append(NSAttributedString(string: t, attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .bold)]))
        timecode.attributedStringValue = s
    }

    func stopRecording(_ done: ((Recorder?) -> Void)? = nil) {
        tcTimer?.invalidate(); tcTimer = nil
        recKey.recording = false
        recKey.toolTip = "Record"
        timecode.isHidden = true
        var r: Recorder?
        captureQueue.sync { r = recorder; recorder = nil }
        guard let r else { done?(nil); return }
        r.finish { r in DispatchQueue.main.async {
            self.lastTake = r.url.path; self.currentTake = nil
            if let f = r.failed { self.say("The take failed:\n\(f)") }
            done?(r)
        } }
    }

    // MARK: samples (capture queue)

    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        if o === audioOut {
            lastAudioFormat = CMSampleBufferGetFormatDescription(sb)
            recorder?.appendAudio(sb)
            let rms = Meter.rms(sb)
            DispatchQueue.main.async { self.lastLevels = rms; self.meter.setLevels(rms) }
        } else {
            liveFrames &+= 1
            if sliceOn, let v = slicer.slice(sb) {
                // v5: the vertical frame is what is shown and what is recorded; ASAP display, the recorder keeps the stamps
                if let a = CMSampleBufferGetSampleAttachmentsArray(v, createIfNecessary: true) as? [NSMutableDictionary] {
                    a.first?.setValue(true, forKey: kCMSampleAttachmentKey_DisplayImmediately as String)
                }
                sliceLayer.enqueue(v)
                recorder?.appendVideo(v)
            } else if !sliceOn { recorder?.appendVideo(sb) }
            if selftesting { selftestFrame(sb) }
        }
    }

    // MARK: selftest (the app checks itself: frames arrive and the picture moves)

    private var selftesting = false
    private var frames = 0
    private var lumas: [Double] = []
    private var prev: [Double] = []

    func runSelftest(to path: String) {
        selftesting = true
        // the permission prompts are Marko's to answer: wait up to two minutes for them
        var waited = 0.0
        func go() {
            let decided = AVCaptureDevice.authorizationStatus(for: .video) != .notDetermined
                && AVCaptureDevice.authorizationStatus(for: .audio) != .notDetermined
            if decided || waited >= 120 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh(); self.testNext(0, report: [], to: path) }
            } else { waited += 1; DispatchQueue.main.asyncAfter(deadline: .now() + 1) { go() } }
        }
        go()
    }

    private func testNext(_ i: Int, report: [String], to path: String) {
        var report = report
        if report.isEmpty {
            report.append("\(NAME) v\(VERSION) selftest \(Date())")
            report.append("camera permission: \(cameraAllowed ? "allowed" : "NOT allowed"), microphone: \(micAllowed ? "allowed" : "NOT allowed")")
            report.append("cameras seen: \(devices.count), sound inputs: \(mics.count) (\(mics.map(\.localizedName).joined(separator: ", ")))")
            report.append("sound input in use: \(currentMic?.localizedName ?? "none")")
        }
        guard cameraAllowed, i < devices.count else { finishSelftest(report, to: path); return }
        popup.selectItem(at: entryIndex(i, slice: false)); select(devices[i])   // a test never changes the remembered camera
        captureQueue.async { self.frames = 0; self.prev = [] }
        lumas = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            let diff = self.lumas.isEmpty ? 0 : self.lumas.reduce(0, +) / Double(self.lumas.count)
            report.append(String(format: "%@ | %d fps | %d frames in 3 s | mean frame difference %.2f (%@)",
                                 self.devices[i].localizedName, self.fps, self.frames, diff, diff > 0.3 ? "moving" : "STILL OR FROZEN"))
            self.testNext(i + 1, report: report, to: path)
        }
    }

    // then a 6-second take on the remembered camera: the file is checked from outside with ffprobe
    private func finishSelftest(_ report: [String], to path: String) {
        var report = report
        guard cameraAllowed, !devices.isEmpty else {
            try? report.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
            NSApp.terminate(nil); return
        }
        let remembered = UserDefaults.standard.string(forKey: "camera")
        let i = devices.firstIndex { $0.uniqueID == remembered } ?? 0
        popup.selectItem(at: entryIndex(i, slice: false)); select(devices[i])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.startRecording { url in
                report.append("take started: \(url?.path ?? "FAILED")")
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    self.stopRecording { r in
                        report.append("take: \(r?.url.path ?? "-") | camera \(self.devices[i].localizedName) | \(r?.fps ?? 0) fps | time code starts \(r?.startTimecode ?? "-") (wall clock \(r?.startClock.map { "\($0)" } ?? "-")) | \(r?.failed ?? "closed")")
                        try? report.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    private func selftestFrame(_ sb: CMSampleBuffer) {
        frames += 1
        guard frames % 5 == 0, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        // the luma plane of 420v
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0), row = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var sample: [Double] = []
        for y in stride(from: 0, to: h, by: 16) { for x in stride(from: 0, to: w, by: 16) { sample.append(Double(p[y * row + x])) } }
        var l = 0.0
        if prev.count == sample.count, !sample.isEmpty { l = zip(sample, prev).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(sample.count) }
        let first = prev.isEmpty
        prev = sample
        if first { return }
        DispatchQueue.main.async { self.lumas.append(l) }
    }
}

// MARK: v6, the local API (ApiServer.swift): the same functions as the window and the record key
private func nn(_ x: Any?) -> Any { x ?? NSNull() }

extension Viewer {
    func apiStatus() -> [String: Any] {
        let rec = isRecording
        let vertical = wantedID.map { UserDefaults.standard.bool(forKey: "slice." + $0) } ?? false
        return ["camera": nn(current?.localizedName ?? wantedName), "id": nn(current?.uniqueID ?? wantedID), "waiting": waiting, "soundWaiting": micWaiting, "interrupted": interrupted, "slice": vertical,
                "recording": rec, "elapsed": rec ? Date().timeIntervalSince(recStart ?? Date()) : 0,
                "lastTake": nn(lastTake), "currentTake": rec ? nn(currentTake) : nn(nil),
                "fps": Int(fps), "size": vertical ? "\(Slicer.outW)x\(Slicer.outH)" : "1920x1080",
                "levels": lastLevels.map { Double($0) }]
    }
    func apiCameras() -> [[String: Any]] {
        devices.map { ["name": $0.localizedName, "id": $0.uniqueID, "slice": savedSlice($0),
                       "current": $0.uniqueID == current?.uniqueID, "sony": KeepStreaming.isSony($0)] }
    }
    /// the menu's own action: camera by id or name (exact, then containing, case-insensitive), slice or not (else as remembered)
    func apiSetCamera(name: String?, id: String?, slice: Bool?) -> (ok: Bool, error: String) {
        refreshIfNeeded()
        var i: Int?
        if let id { i = devices.firstIndex { $0.uniqueID == id } }
        else if let name, !name.isEmpty {
            let n = name.lowercased()
            i = devices.firstIndex { $0.localizedName.lowercased() == n } ?? devices.firstIndex { $0.localizedName.lowercased().contains(n) }
        } else { i = current.flatMap { c in devices.firstIndex { $0.uniqueID == c.uniqueID } } }
        guard let i else { return (false, "no such camera") }
        chooseCamera(i, slice: slice ?? savedSlice(devices[i]))
        return (true, "")
    }
    private func refreshIfNeeded() { if devices.isEmpty { devicesChanged() } }
    /// the record key's own start; `title` goes after the mb_ time stamp in the file name
    func apiStart(title: String?, _ done: @escaping (URL?, String) -> Void) {
        if isRecording { done(nil, "already recording"); return }
        startRecording(title: title) { url in done(url, url == nil ? "cannot record (no camera, or no permission)" : "") }
    }
    func apiStop(_ done: @escaping (String?, Double, String) -> Void) {
        guard isRecording else { done(nil, 0, "not recording"); return }
        let dur = Date().timeIntervalSince(recStart ?? Date())
        stopRecording { r in
            if let r, r.failed == nil { done(r.url.path, dur, "") } else { done(nil, 0, r?.failed ?? "the take failed") }
        }
    }
    /// v8: the picture full screen on the display with the menu bar (the BenQ), or back to the window
    func apiFullscreen(_ on: Bool) -> Bool {
        let isFull = window.styleMask.contains(.fullScreen)
        if on {
            if !isFull {
                if let scr = NSScreen.screens.first { window.setFrame(scr.frame.insetBy(dx: 200, dy: 100), display: true) }
                window.makeKeyAndOrderFront(nil)
                window.toggleFullScreen(nil)
            }
        } else if isFull { window.toggleFullScreen(nil) }
        return true
    }
    func apiFront() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
}
