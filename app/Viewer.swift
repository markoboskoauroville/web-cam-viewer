import AppKit
import AVFoundation

enum Cameras {
    static func isSony(_ device: AVCaptureDevice) -> Bool {
        device.localizedName.uppercased().hasPrefix("ILCE") || device.manufacturer.uppercased().contains("SONY")
    }

    // every kind of camera macOS hands to an app: built-in, USB/UVC webcams and capture cards, the iPhone, Desk View
    static func all() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified).devices
            .sorted { a, b in   // a fixed order: the Sony first (as in the classroom, v5), the Mac's own camera, then by name
                let asn = isSony(a), bsn = isSony(b)
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
    private let qualityKey = NSButton()
    private let snapKey = NSButton()
    private let folderKey = NSButton()
    // v21: the SONY key and its overlay (our own PTP control of the α7 V over Wi-Fi)
    private let sonyKey = NSButton()
    private let sonyLink = SonyLink()
    private lazy var sonyPanel = SonyPanel(link: sonyLink)
    private var sonyTop: NSLayoutConstraint!
    private var snapper: SnapRemote!
    private let closeButton = NSButton()
    private let fullKey = FullKey()
    private var overlays: [NSView] = []
    private var meterTop: NSLayoutConstraint!
    private let permissions = NSButton()
    private let message = NSTextField(labelWithString: "")
    // v24: the take's sound warning under the bar, red, wrapping with the width: the bar's statistics key is clipped in a
    // narrow window (seen at 883 pt in the slice: it showed only "2"), so the warning has its own line that is never cut
    private let soundBanner = NSTextField(wrappingLabelWithString: "")
    private let meter = StereoMeter()
    private let timecode = NSTextField(labelWithString: "")
    private let feedStats = NSButton()
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
    private var lastActualBitrate: Int? = UserDefaults.standard.object(forKey: "lastActualBitrate").flatMap { ($0 as? NSNumber)?.intValue }
    private var lastActualQuality: RecordQuality? = UserDefaults.standard.string(forKey: "lastActualQuality")
        .flatMap(RecordQuality.init(rawValue:))
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
    private var recordQuality = RecordQuality(rawValue: UserDefaults.standard.string(forKey: "recordQuality") ?? "mid") ?? .mid
    private var measuredFPS = 0.0
    private var measuredDrops = 0
    private var feedWidth = 0
    private var feedHeight = 0
    private var feedPixelFormat = "—"
    private var lastAudioFormat: CMFormatDescription?   // capture queue
    private var recorder: Recorder?                     // capture queue
    private var liveRecorder: Recorder?                 // v23: the same take, seen from the main thread (sound warning)
    private var liveWithoutSound = false
    private var lastWarnDraw: TimeInterval = 0                // v23: a sound input was chosen but the take has no sound track
    private var tcTimer: Timer?
    private var statsTimer: Timer?
    private var liveFrames = 0          // capture queue: frames of the chosen camera
    private var droppedFrames = 0       // capture queue: dropped frames since the camera was selected
    private var pendingDroppedFrames = 0
    private var lastVideoPTS = CMTime.invalid
    private var capturedWidth = 0
    private var capturedHeight = 0
    private var capturedPixelFormat = "—"
    private var statsLastFrames = 0
    private var statsLastUpdate = ProcessInfo.processInfo.systemUptime
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
        api = ApiServer(viewer: self); api?.start()
        // no frame from the chosen camera for 3 s while it should run: open it again (another app or the keeper may
        // have held it when it was chosen)
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkFrames() }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateFeedStats() }
    }

    // MARK: the picture

    private func startPictureClick() {
        let click = NSClickGestureRecognizer(target: self, action: #selector(pictureClicked(_:)))
        picture.addGestureRecognizer(click)
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

    @objc private func pictureClicked(_ g: NSClickGestureRecognizer) {
        showChoice()
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
        recKey.toolTip = "Record: mb_<date>_<time>.mkv in the recordings folder, H.264 at the live feed resolution and frame rate"
        recKey.widthAnchor.constraint(equalToConstant: 30).isActive = true
        recKey.heightAnchor.constraint(equalToConstant: 30).isActive = true

        startPictureClick()
        qualityKey.translatesAutoresizingMaskIntoConstraints = false
        qualityKey.isBordered = false
        qualityKey.target = self
        qualityKey.action = #selector(toggleQuality)
        qualityKey.setAccessibilityIdentifier("quality")
        qualityKey.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        qualityKey.setContentHuggingPriority(.required, for: .horizontal)
        updateQualityKey()

        // v15: SNAP REMOTE joins this window and Sony's Imaging Edge Remote into one piece (opens the remote if it is closed)
        snapKey.translatesAutoresizingMaskIntoConstraints = false
        snapKey.isBordered = false
        snapKey.target = self
        snapKey.action = #selector(snapTapped)
        snapKey.setAccessibilityIdentifier("snap")
        snapKey.imagePosition = .imageOnly
        snapper = SnapRemote(window: window, say: { [weak self] in self?.say($0) },
                             unsay: { [weak self] t in if self?.message.stringValue == t { self?.say("") } }, changed: { [weak self] in self?.updateSnapKey() })
        updateSnapKey()
        // v17: F opens the folder the takes are written to (~/Movies), beside S
        folderKey.translatesAutoresizingMaskIntoConstraints = false
        folderKey.isBordered = false
        folderKey.imagePosition = .imageTrailing
        folderKey.lineBreakMode = .byTruncatingMiddle
        folderKey.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Recordings folder")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        folderKey.contentTintColor = .secondaryLabelColor
        folderKey.target = self; folderKey.action = #selector(openFolder)
        folderKey.setAccessibilityIdentifier("folder")
        folderKey.toolTip = "Recordings folder: click to choose another folder (remembered) or show this one"
        let fm = NSMenu()
        fm.addItem(withTitle: "Choose folder…", action: #selector(chooseFolder), keyEquivalent: "").target = self
        fm.addItem(withTitle: "Show the folder in Finder", action: #selector(openFolderMenu), keyEquivalent: "").target = self
        folderKey.menu = fm
        updateFolderKey()

        // v21, Marko 21.11.2026: "I need to have button Sony control, and all its icons and pop up menus you overlay over my
        // image ... and I can change all the settings inside my own window". SONY toggles the overlay (remembered);
        // Option-click opens it with the demo camera.
        sonyKey.translatesAutoresizingMaskIntoConstraints = false
        sonyKey.isBordered = false
        sonyKey.target = self; sonyKey.action = #selector(sonyTapped)
        sonyKey.setAccessibilityIdentifier("sony")
        sonyKey.setContentHuggingPriority(.required, for: .horizontal)
        sonyLink.onChange = { [weak self] in self?.sonyPanel.update(); self?.updateSonyKey() }
        sonyLink.startWatching()     // v28: a verdict that no longer applies is measured again and replaced by itself
        sonyPanel.onClose = { [weak self] in self?.setSony(false) }
        updateSonyKey()

        let group = NSStackView(views: [popup, micPopup, recKey, qualityKey, feedStats])
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
        bar.addSubview(snapKey)
        bar.addSubview(folderKey)
        bar.addSubview(sonyKey)

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

        soundBanner.translatesAutoresizingMaskIntoConstraints = false
        soundBanner.isHidden = true
        soundBanner.textColor = .white
        soundBanner.font = .systemFont(ofSize: 13, weight: .bold)
        soundBanner.alignment = .center
        soundBanner.drawsBackground = true
        soundBanner.backgroundColor = NSColor(srgbRed: 0.85, green: 0.12, blue: 0.10, alpha: 0.92)
        soundBanner.setAccessibilityIdentifier("sound-warning")

        // the meters: two hairlines (L, R) down the left edge, under the bar
        meter.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(meter)

        // REC  HH:MM:SS:FF bottom middle while recording: REC red, the time code white, a black shadow, no box
        timecode.translatesAutoresizingMaskIntoConstraints = false
        timecode.isHidden = true
        let sh = NSShadow(); sh.shadowColor = .black; sh.shadowBlurRadius = 3; sh.shadowOffset = .zero
        timecode.shadow = sh
        timecode.setAccessibilityIdentifier("timecode")
        timecode.alignment = .center; timecode.maximumNumberOfLines = 2   // v23: the sound warning goes under REC
        content.addSubview(timecode)

        // Live input facts beside the record key, in the dark input bar.
        feedStats.translatesAutoresizingMaskIntoConstraints = false
        feedStats.isHidden = true
        feedStats.isBordered = false
        feedStats.title = ""
        feedStats.target = self
        feedStats.action = #selector(openCapturePreferences)
        feedStats.lineBreakMode = .byClipping
        feedStats.toolTip = "Capture device preferences"
        feedStats.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        feedStats.setAccessibilityIdentifier("video-stats")
        feedStats.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        content.addSubview(bar)   // last: over the picture
        overlay.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(overlay, positioned: .below, relativeTo: bar)   // the bar stays usable over it
        sonyPanel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sonyPanel, positioned: .below, relativeTo: bar)  // under the bar, never over it
        sonyTop = sonyPanel.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.barHeight)
        NSLayoutConstraint.activate([sonyTop, sonyPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sonyPanel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: StereoMeter.width),
            sonyPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor)])
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
            if e.keyCode == 53, !self.sonyPanel.isHidden { self.setSony(false); return nil }   // Escape hides the Sony controls
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

            snapKey.trailingAnchor.constraint(equalTo: fullKey.leadingAnchor, constant: -4),
            snapKey.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            snapKey.widthAnchor.constraint(equalToConstant: 30), snapKey.heightAnchor.constraint(equalToConstant: 30),
            folderKey.trailingAnchor.constraint(equalTo: snapKey.leadingAnchor, constant: -4),
            folderKey.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            folderKey.widthAnchor.constraint(greaterThanOrEqualToConstant: 30), folderKey.widthAnchor.constraint(lessThanOrEqualToConstant: 170), folderKey.heightAnchor.constraint(equalToConstant: 30),
            sonyKey.trailingAnchor.constraint(equalTo: folderKey.leadingAnchor, constant: -4),
            sonyKey.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            sonyKey.heightAnchor.constraint(equalToConstant: 30), sonyKey.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            permissions.trailingAnchor.constraint(equalTo: sonyKey.leadingAnchor, constant: -8),
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
        content.addSubview(soundBanner)   // after the Sony overlay, so it stays visible over it
        NSLayoutConstraint.activate([
            soundBanner.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.barHeight + 6),
            soundBanner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            soundBanner.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -32)])
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
        snapper.restore()
        if CommandLine.arguments.contains("--sony-demo") { setSony(true, connect: false, remember: false); sonyLink.startDemo() }
        else if UserDefaults.standard.bool(forKey: "sony.overlay") { setSony(true) }   // remembered open: find the last camera again
    }

    // MARK: v21, the SONY key and overlay
    @objc private func sonyTapped() {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            setSony(true, connect: false)
            if !sonyLink.connected { sonyLink.startDemo() }
            return
        }
        setSony(sonyPanel.isHidden)
    }

    private func setSony(_ open: Bool, connect: Bool = true, remember: Bool = true) {
        sonyPanel.isHidden = !open
        if remember && !test { UserDefaults.standard.set(open, forKey: "sony.overlay") }
        if open {
            if !overlay.isHidden { overlay.close() }
            sonyPanel.update()
            if connect, !sonyLink.connected, [SonyLink.Phase.idle, .notFound, .failed, .usbBusy].contains(sonyLink.phase) { sonyLink.findAndConnect() }
        }
        updateSonyKey()
    }

    private func updateSonyKey() {
        let open = !sonyPanel.isHidden, on = sonyLink.connected
        let color: NSColor = on ? .systemGreen : open ? .white : .secondaryLabelColor
        sonyKey.attributedTitle = NSAttributedString(string: on ? "SONY ●" : "SONY", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: color])
        sonyKey.setAccessibilityLabel(open ? "Hide the Sony camera controls" : "Show the Sony camera controls")
        sonyKey.toolTip = (open ? "Hide the Sony controls (Escape)" : "Sony camera controls over the picture: Picture Profile, white balance, focus, REC …")
            + (on ? " · connected to \(sonyLink.found?.model ?? "the Sony")" : "") + " · Option-click: demo camera"
    }

    @objc private func snapTapped() {
        // v23: one program holds the camera's USB at a time. While SONY controls it over USB, opening Imaging Edge Remote
        // would only meet a busy camera: say so; DISCONNECT in SONY gives the cable back, then S opens and snaps Remote.
        if !snapper.isSnapped, sonyLink.connected, sonyLink.transport == "USB", NSRunningApplication.runningApplications(withBundleIdentifier: "com.sony.Remote").isEmpty {
            let text = "The Sony is controlled from this window over USB.\nSONY → DISCONNECT first, then S opens Imaging Edge Remote."
            say(text)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in if self?.message.stringValue == text { self?.say("") } }
            return
        }
        snapper.toggle()
    }

    private func updateSnapKey() {
        let on = snapper.isSnapped
        snapKey.image = NSImage(systemSymbolName: on ? "rectangle.split.2x1.fill" : "rectangle.split.2x1", accessibilityDescription: "Snap remote")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        snapKey.contentTintColor = on ? .systemGreen : .secondaryLabelColor
        snapKey.toolTip = on ? "Snapped to Sony Imaging Edge Remote: they move and resize as one. Click to unsnap."
            : "Snap Sony Imaging Edge Remote beside this window (opens it if closed); they then move and resize as one"
        snapKey.setAccessibilityLabel(on ? "Unsnap the Sony remote" : "Snap the Sony remote")
    }

    /// v19: the name of the last folder (not the path) stands beside the folder icon
    private func updateFolderKey() {
        folderKey.attributedTitle = NSAttributedString(string: Recorder.folder.lastPathComponent + " ", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
        folderKey.toolTip = "Recordings go to \(Recorder.folder.path). Click: choose another folder (remembered) or show this one"
    }
    @objc private func openFolderMenu() { revealFolder() }
    @objc private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Record here"; p.directoryURL = Recorder.folder
        if p.runModal() == .OK, let u = p.url { UserDefaults.standard.set(u.path, forKey: "recordFolder"); updateQualityKey(); updateFolderKey() }
    }
    /// v20 (Marko: "I need to pick the folder"): a click on F opens a small menu under it: Choose folder… first, then Open
    @objc private func openFolder() {
        guard let menu = folderKey.menu else { chooseFolder(); return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: folderKey.bounds.height + 2), in: folderKey)
    }
    private func revealFolder() {
        let movies = Recorder.folder
        if let take = lastTake, URL(fileURLWithPath: take).deletingLastPathComponent().path == movies.path, FileManager.default.fileExists(atPath: take) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: take)])   // the newest take, selected
        } else { NSWorkspace.shared.open(movies) }
    }

    @objc private func closeTapped() { NSApp.terminate(nil) }

    // MARK: full screen: the picture and nothing else

    private var isFull: Bool { window.styleMask.contains(.fullScreen) }
    @objc private func toggleFull() { window.toggleFullScreen(nil) }
    @objc private func enteredFull() {
        overlays.forEach { $0.isHidden = true }
        sonyTop.constant = 0
        meterTop.constant = 0   // the meters the whole height
        NSCursor.setHiddenUntilMouseMoves(true)
    }
    @objc private func leftFull() {
        overlays.forEach { $0.isHidden = false }
        sonyTop.constant = Self.barHeight
        meterTop.constant = Self.barHeight
    }

    /// stops a running take cleanly (the file is closed), then the session
    func stop(_ done: (() -> Void)? = nil) {
        api?.stop()
        sonyLink.shutdown()
        statsTimer?.invalidate(); statsTimer = nil
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
        updateFeedStatsVisibility()
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
        resetFeedStats()
        updateFeedStatsVisibility()
        applyMode(device.map { savedSlice($0) } ?? false)
        guard let device else {
            queue.async { if let v = self.videoIn { self.session.removeInput(v); self.videoIn = nil } }
            say("No camera is connected.")
            return
        }
        guard cameraAllowed else { say("The camera is not allowed.\nPERMISSIONS, top right, opens the switch."); return }
        say("")
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
            do {
                try device.lockForConfiguration()
                let defaults = UserDefaults.standard
                if let wanted = defaults.string(forKey: Self.captureFormatPreference(device)),
                   let format = device.formats.first(where: { Self.captureFormatKey($0) == wanted }) {
                    device.activeFormat = format
                }
                let savedRate = defaults.double(forKey: Self.captureRatePreference(device))
                let rate = savedRate > 0 ? Self.supportedCaptureRate(savedRate, for: device.activeFormat)
                    : Self.currentWholeFrameRate(device)
                let duration = Self.captureDuration(rate, for: device.activeFormat)
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
                self.fps = Int32(rate.rounded())
            } catch {
                DispatchQueue.main.async { self.say("Cannot configure \(device.localizedName):\n\(error.localizedDescription)") }
            }
            if !self.session.isRunning { self.session.startRunning() }
            self.reapplySavedCapture()
        }
    }

    /// v24/v25 (session queue): startRunning and every later commitConfiguration (e.g. adding the sound input) apply the
    /// session preset (hd1920x1080) over the saved format, so a remembered 2560x1440 came back as 1920x1080 at every launch.
    /// After each of them the saved format and rate of the camera are put back when they differ.
    private func reapplySavedCapture() {
        guard let device = videoIn?.device,
              let wanted = UserDefaults.standard.string(forKey: Self.captureFormatPreference(device)),
              let format = device.formats.first(where: { Self.captureFormatKey($0) == wanted }) else { return }
        let savedRate = UserDefaults.standard.double(forKey: Self.captureRatePreference(device))
        let rate = savedRate > 0 ? Self.supportedCaptureRate(savedRate, for: format) : Self.currentWholeFrameRate(device)
        let duration = Self.captureDuration(rate, for: format)
        if Self.captureFormatKey(device.activeFormat) == wanted && device.activeVideoMinFrameDuration == duration { return }
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.activeFormat = format
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
        fps = Int32(rate.rounded())
        NSLog("Webcam Recorder: capture format put back to %@ at %.0f FPS", wanted, rate)
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

    // The capture device's negotiated duration is the default; a supported whole rate can then be chosen from the menu.
    private static func currentWholeFrameRate(_ d: AVCaptureDevice) -> Double {
        let dur = CMTimeGetSeconds(d.activeVideoMinFrameDuration)
        return dur > 0 ? max(1, min(120, (1 / dur).rounded())) : 30
    }

    private func selectMic(_ device: AVCaptureDevice?) {
        if isRecording { stopRecording() }
        currentMic = device
        updateFeedStatsVisibility()
        if let device { UserDefaults.standard.set(device.uniqueID, forKey: "sound"); UserDefaults.standard.set(device.localizedName, forKey: "soundName") }
        meter.dead = device == nil || !micAllowed
        queue.async {
            self.session.beginConfiguration()
            if let a = self.audioIn { self.session.removeInput(a); self.audioIn = nil }
            if let device, self.micAllowed, let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) {
                self.session.addInput(input); self.audioIn = input
            }
            self.session.commitConfiguration()
            self.reapplySavedCapture()   // v25: this commit re-applied the preset too (the sound input comes after the camera)
            self.captureQueue.async { self.lastAudioFormat = nil }
        }
    }

    private func updateFeedStatsVisibility() {
        feedStats.isHidden = current == nil || currentMic == nil || waiting || micWaiting || !cameraAllowed || !micAllowed
        if !feedStats.isHidden { updateFeedStats() }
    }

    private func resetFeedStats() {
        captureQueue.async {
            self.liveFrames = 0
            self.droppedFrames = 0
            self.pendingDroppedFrames = 0
            self.lastVideoPTS = .invalid
            self.capturedWidth = 0
            self.capturedHeight = 0
            self.capturedPixelFormat = "—"
        }
        statsLastFrames = 0
        statsLastUpdate = ProcessInfo.processInfo.systemUptime
        measuredFPS = 0
        measuredDrops = 0
        feedWidth = 0
        feedHeight = 0
        feedPixelFormat = "—"
    }

    private func updateFeedStats() {
        guard current != nil else { return }
        var frames = 0, drops = 0, width = 0, height = 0, format = "—"
        captureQueue.sync {
            frames = self.liveFrames
            drops = self.droppedFrames
            width = self.capturedWidth
            height = self.capturedHeight
            format = self.capturedPixelFormat
        }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - statsLastUpdate
        if elapsed > 0 {
            measuredFPS = frames >= statsLastFrames ? Double(frames - statsLastFrames) / elapsed : 0
            statsLastFrames = frames
            statsLastUpdate = now
        }
        measuredDrops = drops
        feedWidth = width
        feedHeight = height
        feedPixelFormat = format
        updateQualityKey()
        guard !feedStats.isHidden else { return }
        if let w = soundWarningNow {
            // v23: on the bar, in red, in place of the statistics, for as long as the take's sound is missing
            feedStats.attributedTitle = NSAttributedString(string: "⚠ " + w, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor(srgbRed: 1, green: 0.231, blue: 0.188, alpha: 1)])
            feedStats.setAccessibilityValue(w)
            return
        }
        feedStats.setAccessibilityValue(nil)
        let degraded = drops > 0 || (measuredFPS > 0 && measuredFPS + 0.9 < Double(fps))
        var text = ""
        if width > 0, height > 0 { text += "\(width)×\(height) · " }
        text += "\(fps) FPS"
        if degraded { text += String(format: " / %.1f LIVE", measuredFPS) }
        text += " · \(format)"
        if drops > 0 { text += " · \(drops) DROP\(drops == 1 ? "" : "S")" }
        feedStats.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)])
    }

    @objc private func openCapturePreferences() {
        guard let device = current else { return }
        let menu = NSMenu(title: "\(device.localizedName) capture settings")
        let title = NSMenuItem(title: device.localizedName, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(Self.captureMenuHeading("FORMAT"))

        let formats = device.formats.sorted {
            let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            if Int(a.width) != Int(b.width) { return a.width > b.width }
            if Int(a.height) != Int(b.height) { return a.height > b.height }
            return Self.maximumFrameRate($0) > Self.maximumFrameRate($1)
        }
        var seen: Set<String> = []
        for format in formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let codec = Self.pixelFormatName(CMFormatDescriptionGetMediaSubType(format.formatDescription))
            let maxRate = Self.maximumFrameRate(format)
            let key = "\(dimensions.width)x\(dimensions.height):\(codec):\(maxRate)"
            guard seen.insert(key).inserted else { continue }
            let item = NSMenuItem(title: "\(dimensions.width)×\(dimensions.height) · \(codec) · up to \(Self.rateText(maxRate)) FPS",
                                 action: #selector(pickCaptureFormat(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = format
            item.state = format === device.activeFormat ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(Self.captureMenuHeading("FRAME RATE"))
        for rate in Self.captureRates(for: device.activeFormat) {
            let item = NSMenuItem(title: "\(Self.rateText(rate)) FPS", action: #selector(pickCaptureRate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: rate)
            item.state = abs(Double(fps) - rate) < 0.6 ? .on : .off
            menu.addItem(item)
        }

        var controlCount = 0
        controlCount += addCaptureModeMenu(to: menu, title: "FOCUS", current: Self.focusName(device.focusMode),
                                           choices: [
                                            ("Locked", "focus:locked", device.isFocusModeSupported(.locked)),
                                            ("Auto", "focus:auto", device.isFocusModeSupported(.autoFocus)),
                                            ("Continuous Auto", "focus:continuous", device.isFocusModeSupported(.continuousAutoFocus)),
                                           ])
        controlCount += addCaptureModeMenu(to: menu, title: "EXPOSURE", current: Self.exposureName(device.exposureMode),
                                           choices: [
                                            ("Locked", "exposure:locked", device.isExposureModeSupported(.locked)),
                                            ("Auto", "exposure:auto", device.isExposureModeSupported(.autoExpose)),
                                            ("Continuous Auto", "exposure:continuous", device.isExposureModeSupported(.continuousAutoExposure)),
                                           ])
        controlCount += addCaptureModeMenu(to: menu, title: "WHITE BALANCE", current: Self.whiteBalanceName(device.whiteBalanceMode),
                                           choices: [
                                            ("Locked", "whiteBalance:locked", device.isWhiteBalanceModeSupported(.locked)),
                                            ("Auto", "whiteBalance:auto", device.isWhiteBalanceModeSupported(.autoWhiteBalance)),
                                            ("Continuous Auto", "whiteBalance:continuous", device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance)),
                                           ])
        if controlCount == 0 {
            menu.addItem(.separator())
            let none = NSMenuItem(title: "No additional device controls exposed by macOS", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: feedStats.bounds.height), in: feedStats)
    }

    private static func captureMenuHeading(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func addCaptureModeMenu(to menu: NSMenu, title: String, current: String,
                                    choices: [(String, String, Bool)]) -> Int {
        let available = choices.filter { $0.2 }
        guard !available.isEmpty else { return 0 }
        if menu.items.last?.isSeparatorItem != true { menu.addItem(.separator()) }
        let parent = NSMenuItem(title: "\(title) · \(current)", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for choice in available {
            let item = NSMenuItem(title: choice.0, action: #selector(pickCaptureMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.1
            submenu.addItem(item)
        }
        parent.submenu = submenu
        menu.addItem(parent)
        return 1
    }

    @objc private func pickCaptureFormat(_ item: NSMenuItem) {
        guard let format = item.representedObject as? AVCaptureDevice.Format else { return }
        setCaptureFormat(format)
    }

    @objc private func pickCaptureRate(_ item: NSMenuItem) {
        guard let rate = (item.representedObject as? NSNumber)?.doubleValue, let device = current else { return }
        setCaptureRate(rate, on: device)
    }

    @objc private func pickCaptureMode(_ item: NSMenuItem) {
        guard let payload = item.representedObject as? String, let device = current else { return }
        do {
            try device.lockForConfiguration()
            switch payload {
            case "focus:locked": device.focusMode = .locked
            case "focus:auto": device.focusMode = .autoFocus
            case "focus:continuous": device.focusMode = .continuousAutoFocus
            case "exposure:locked": device.exposureMode = .locked
            case "exposure:auto": device.exposureMode = .autoExpose
            case "exposure:continuous": device.exposureMode = .continuousAutoExposure
            case "whiteBalance:locked": device.whiteBalanceMode = .locked
            case "whiteBalance:auto": device.whiteBalanceMode = .autoWhiteBalance
            case "whiteBalance:continuous": device.whiteBalanceMode = .continuousAutoWhiteBalance
            default: break
            }
            device.unlockForConfiguration()
        } catch {
            say("Cannot change \(device.localizedName):\n\(error.localizedDescription)")
        }
    }

    private func setCaptureFormat(_ format: AVCaptureDevice.Format) {
        guard let device = current else { return }
        if isRecording { stopRecording() }
        queue.async {
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                let saved = self.fps > 0 ? Double(self.fps) : Self.maximumFrameRate(format)
                let rate = Self.supportedCaptureRate(saved, for: format)
                let duration = Self.captureDuration(rate, for: format)
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.fps = Int32(rate.rounded())
                    UserDefaults.standard.set(Self.captureFormatKey(format), forKey: Self.captureFormatPreference(device))
                    UserDefaults.standard.set(rate, forKey: Self.captureRatePreference(device))
                    self.resetFeedStats()
                    self.updateFeedStatsVisibility()
                }
            } catch {
                DispatchQueue.main.async { self.say("Cannot change \(device.localizedName):\n\(error.localizedDescription)") }
            }
        }
    }

    private func setCaptureRate(_ rate: Double, on device: AVCaptureDevice) {
        if isRecording { stopRecording() }
        queue.async {
            do {
                try device.lockForConfiguration()
                let supported = Self.supportedCaptureRate(rate, for: device.activeFormat)
                let duration = Self.captureDuration(supported, for: device.activeFormat)
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.fps = Int32(supported.rounded())
                    UserDefaults.standard.set(supported, forKey: Self.captureRatePreference(device))
                    self.resetFeedStats()
                    self.updateFeedStatsVisibility()
                }
            } catch {
                DispatchQueue.main.async { self.say("Cannot change \(device.localizedName) frame rate:\n\(error.localizedDescription)") }
            }
        }
    }

    private static func captureRates(for format: AVCaptureDevice.Format) -> [Double] {
        var rates: [Double] = []
        for range in format.videoSupportedFrameRateRanges {
            let continuous = range.maxFrameRate - range.minFrameRate > 0.2
            if continuous {
                rates.append(range.minFrameRate)
                rates.append(range.maxFrameRate)
                let whole = stride(from: ceil(range.minFrameRate), through: floor(range.maxFrameRate), by: 5).map { Double($0) }
                rates.append(contentsOf: whole)
            } else {
                rates.append(range.maxFrameRate)
            }
        }
        return rates.sorted().reduce(into: []) { result, rate in
            let normalized = abs(rate - rate.rounded()) < 0.05 ? rate.rounded() : rate
            if !result.contains(where: { abs($0 - normalized) < 0.01 }) { result.append(normalized) }
        }
    }

    private static func supportedCaptureRate(_ rate: Double, for format: AVCaptureDevice.Format) -> Double {
        captureRates(for: format).first { abs($0 - rate) < 0.6 } ?? captureRates(for: format).last ?? rate
    }

    private static func captureDuration(_ rate: Double, for format: AVCaptureDevice.Format) -> CMTime {
        guard let range = format.videoSupportedFrameRateRanges.min(by: { a, b in
            let distance: (AVFrameRateRange) -> Double = { r in
                rate < r.minFrameRate ? r.minFrameRate - rate : rate > r.maxFrameRate ? rate - r.maxFrameRate : 0
            }
            return distance(a) < distance(b)
        }) else {
            return CMTime(seconds: 1 / rate, preferredTimescale: 1_000_000)
        }
        if rate >= range.maxFrameRate - 0.05 { return range.minFrameDuration }
        if rate <= range.minFrameRate + 0.05 { return range.maxFrameDuration }
        return CMTime(seconds: 1 / rate, preferredTimescale: 1_000_000)
    }

    private static func maximumFrameRate(_ format: AVCaptureDevice.Format) -> Double {
        format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
    }

    private static func rateText(_ rate: Double) -> String {
        let normalized = abs(rate - rate.rounded()) < 0.05 ? rate.rounded() : rate
        return normalized.rounded() == normalized ? "\(Int(normalized))" : String(format: "%.2f", normalized)
    }

    private static func captureFormatPreference(_ device: AVCaptureDevice) -> String {
        "capture.format.\(device.uniqueID)"
    }

    private static func captureRatePreference(_ device: AVCaptureDevice) -> String {
        "capture.rate.\(device.uniqueID)"
    }

    private static func captureFormatKey(_ format: AVCaptureDevice.Format) -> String {
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let rates = captureRates(for: format).map(rateText).joined(separator: ",")
        return "\(size.width)x\(size.height):\(CMFormatDescriptionGetMediaSubType(format.formatDescription)):\(rates)"
    }

    private static func focusName(_ mode: AVCaptureDevice.FocusMode) -> String {
        switch mode { case .locked: return "Locked"; case .autoFocus: return "Auto"; case .continuousAutoFocus: return "Continuous Auto"; @unknown default: return "Other" }
    }

    private static func exposureName(_ mode: AVCaptureDevice.ExposureMode) -> String {
        switch mode { case .locked: return "Locked"; case .autoExpose: return "Auto"; case .continuousAutoExposure: return "Continuous Auto"; case .custom: return "Custom"; @unknown default: return "Other" }
    }

    private static func whiteBalanceName(_ mode: AVCaptureDevice.WhiteBalanceMode) -> String {
        switch mode { case .locked: return "Locked"; case .autoWhiteBalance: return "Auto"; case .continuousAutoWhiteBalance: return "Continuous Auto"; @unknown default: return "Other" }
    }

    private func recordMissingFrames(at pts: CMTime) {
        guard pts.isNumeric, lastVideoPTS.isNumeric else { lastVideoPTS = pts; return }
        let gap = CMTimeGetSeconds(pts - lastVideoPTS)
        let expected = 1 / max(1, Double(fps))
        if gap > expected * 1.5 {
            let inferred = max(0, Int((gap / expected).rounded()) - 1)
            droppedFrames += max(0, inferred - pendingDroppedFrames)
        }
        pendingDroppedFrames = 0
        lastVideoPTS = pts
    }

    private static func pixelFormatName(_ type: OSType) -> String {
        switch type {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return "420v"
        case kCVPixelFormatType_422YpCbCr8: return "422v"
        case kCVPixelFormatType_32BGRA: return "BGRA"
        case kCVPixelFormatType_32ARGB: return "ARGB"
        case kCVPixelFormatType_24RGB: return "RGB"
        case kCVPixelFormatType_OneComponent8: return "Y8"
        default:
            var n = type.bigEndian
            return String(bytes: Data(bytes: &n, count: MemoryLayout<OSType>.size), encoding: .ascii)?
                .trimmingCharacters(in: .controlCharacters) ?? "0x\(String(type, radix: 16))"
        }
    }

    private func say(_ s: String) { message.stringValue = s; message.isHidden = s.isEmpty }

    // MARK: recording

    var isRecording: Bool { recKey.recording }

    @objc func toggleRecord() { isRecording ? stopRecording() : startRecording() }

    @objc private func toggleQuality() {
        guard !isRecording else { return }
        let all = RecordQuality.allCases
        guard let index = all.firstIndex(of: recordQuality) else { return }
        recordQuality = all[(index + 1) % all.count]
        UserDefaults.standard.set(recordQuality.rawValue, forKey: "recordQuality")
        updateQualityKey()
    }

    private func updateQualityKey() {
        let width = sliceOn ? Slicer.outW : (feedWidth > 0 ? feedWidth : 1920)
        let height = sliceOn ? Slicer.outH : (feedHeight > 0 ? feedHeight : 1080)
        let bitrate = recordQuality.bitrate(width: width, height: height, fps: recordingFPS)
        let remaining = Self.compactDuration(Self.recordingSecondsRemaining(at: bitrate))
        let actual = currentActualBitrate()
        let actualText = actual.map { String(format: "%.2f Mb/s", Double($0) / 1_000_000) } ?? "— Mb/s"
        qualityKey.attributedTitle = NSAttributedString(
            string: "\(recordQuality.title) \(actualText) (\(remaining))", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        qualityKey.toolTip = "\(recordQuality.title): target \(String(format: "%.1f", Double(bitrate) / 1_000_000)) Mb/s, actual \(actualText), \(recordingFPS) live FPS · H.264 MKV · \(remaining) available"
        qualityKey.setAccessibilityLabel("\(recordQuality.title), actual \(actualText), \(remaining) available")
        recKey.toolTip = "Record: \(qualityKey.title), \(String(format: "%.1f", Double(bitrate) / 1_000_000)) Mb/s H.264 MKV"
    }

    private func currentActualBitrate() -> Int? {
        if isRecording, let started = recStart, let path = currentTake {
            return Self.fileBitrate(path, elapsed: Date().timeIntervalSince(started))
        }
        return lastActualQuality == recordQuality ? lastActualBitrate : nil
    }

    private static func fileBitrate(_ path: String, elapsed: TimeInterval) -> Int? {
        guard elapsed > 0,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let bytes = attributes[.size] as? NSNumber else { return nil }
        guard bytes.int64Value >= 65_536 else { return nil }
        return Int(Double(bytes.int64Value * 8) / elapsed)
    }

    static func compactDuration(_ seconds: Int64) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let secs = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 { parts.append("\(minutes)m") }
        if secs > 0 || parts.isEmpty { parts.append("\(secs)s") }
        return parts.joined(separator: " ")
    }

    private static func recordingSecondsRemaining(at videoBitrate: Int) -> Int64 {
        let movies = Recorder.folder
        let values = try? movies.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values?.volumeAvailableCapacityForImportantUsage ?? 0
        // Stereo AAC is 256 kb/s.
        let bytesPerSecond = Double(videoBitrate + 256_000) / 8
        return max(0, Int64(Double(available) / bytesPerSecond))
    }

    func startRecording(title: String? = nil, _ started: ((URL?) -> Void)? = nil) {
        guard current != nil, cameraAllowed else { say("No camera to record."); started?(nil); return }
        let fps = recordingFPS
        let width = self.sliceOn ? Slicer.outW : (self.capturedWidth > 0 ? self.capturedWidth : 1920)
        let height = self.sliceOn ? Slicer.outH : (self.capturedHeight > 0 ? self.capturedHeight : 1080)
        let quality = self.recordQuality
        // v23: a sound input is chosen but its first buffer has not come yet (just launched, just switched): wait for it
        // up to 1.5 s, never start a take that silently has no sound track (v22 did, when lastAudioFormat was still nil)
        func begin(_ tries: Int) {
            if self.audioIn != nil && self.lastAudioFormat == nil && tries > 0 {
                self.captureQueue.asyncAfter(deadline: .now() + 0.1) { begin(tries - 1) }
                return
            }
            do {
                let r = try Recorder(fps: fps, width: width, height: height, quality: quality,
                                     vertical: self.sliceOn, title: title,
                                     audioFormat: self.audioIn == nil ? nil : self.lastAudioFormat)
                self.recorder = r
                let noTrack = self.audioIn != nil && !r.hasAudioTrack
                DispatchQueue.main.async { self.liveRecorder = r; self.liveWithoutSound = noTrack; self.interrupted = false; self.currentTake = r.url.path; self.recStart = Date(); self.recordingStarted(fps: fps); started?(r.url) }
            } catch {
                DispatchQueue.main.async { self.say("Cannot record:\n\(error.localizedDescription)"); started?(nil) }
            }
        }
        captureQueue.async { begin(15) }
    }

    private func recordingStarted(fps: Int32) {
        recKey.recording = true
        recKey.toolTip = "Stop recording"
        qualityKey.isEnabled = false
        timecode.isHidden = false
        showTimecode(fps)
        tcTimer = Timer.scheduledTimer(withTimeInterval: 1 / Double(fps) / 2, repeats: true) { _ in self.showTimecode(fps) }
    }

    /// v27: the banner never covers the Sony overlay: while it shows, the overlay starts under it (v26 covered CONNECT's row)
    private func setSoundBanner(visible: Bool) {
        soundBanner.isHidden = !visible
        soundBanner.preferredMaxLayoutWidth = max(100, (window.contentView?.bounds.width ?? 420) - 32)   // its wrapped height
        let top = Self.barHeight + (visible ? ceil(soundBanner.fittingSize.height) + 12 : 0)
        if sonyTop.constant != top { sonyTop.constant = top }
    }

    /// v23 (silent-failure.md): what is wrong with the take's sound now, nil while the sound is arriving
    var soundWarningNow: String? {
        guard liveRecorder != nil else { return nil }
        if liveWithoutSound { return "NO SOUND: the sound input gave nothing, this take has no sound track" }
        return liveRecorder?.soundWarning
    }

    // the real-time clock, the same clock the file's time code starts from
    private func showTimecode(_ fps: Int32) {
        let t = Recorder.timecode(Date(), fps: fps).text
        let s = NSMutableAttributedString(string: "REC  ", attributes: [
            .foregroundColor: NSColor(srgbRed: 1, green: 0.231, blue: 0.188, alpha: 1),
            .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .bold)])
        s.append(NSAttributedString(string: t, attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .bold)]))
        if let w = soundWarningNow {
            s.append(NSAttributedString(string: "\n⚠ " + w, attributes: [
                .foregroundColor: NSColor(srgbRed: 1, green: 0.231, blue: 0.188, alpha: 1),
                .font: NSFont.systemFont(ofSize: 14, weight: .bold)]))
        }
        timecode.attributedStringValue = s
        let w = soundWarningNow
        if let w, soundBanner.stringValue != "⚠ " + w { soundBanner.stringValue = "⚠ " + w; soundBanner.setAccessibilityValue(w) }
        setSoundBanner(visible: w != nil)
        if soundWarningNow != nil, !feedStats.isHidden, ProcessInfo.processInfo.systemUptime - lastWarnDraw > 0.5 {
            lastWarnDraw = ProcessInfo.processInfo.systemUptime; updateFeedStats()
        }
    }

    func stopRecording(_ done: ((Recorder?) -> Void)? = nil) {
        tcTimer?.invalidate(); tcTimer = nil
        recKey.recording = false
        recKey.toolTip = "Record"
        qualityKey.isEnabled = true
        timecode.isHidden = true
        var r: Recorder?
        captureQueue.sync { r = recorder; recorder = nil }
        liveRecorder = nil; liveWithoutSound = false; setSoundBanner(visible: false)
        guard let r else { done?(nil); return }
        r.finish { r in DispatchQueue.main.async {
            self.lastTake = r.url.path; self.currentTake = nil
            self.lastActualQuality = r.quality
            self.lastActualBitrate = r.actualBitrate
            UserDefaults.standard.set(r.actualBitrate, forKey: "lastActualBitrate")
            UserDefaults.standard.set(r.quality.rawValue, forKey: "lastActualQuality")
            if let f = r.failed { self.say("The take failed:\n\(f)") }
            self.updateQualityKey()
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
            recordMissingFrames(at: CMSampleBufferGetPresentationTimeStamp(sb))
            if let pb = CMSampleBufferGetImageBuffer(sb) {
                capturedWidth = CVPixelBufferGetWidth(pb)
                capturedHeight = CVPixelBufferGetHeight(pb)
                capturedPixelFormat = Self.pixelFormatName(CVPixelBufferGetPixelFormatType(pb))
            }
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

    func captureOutput(_ o: AVCaptureOutput, didDrop sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard o === videoOut else { return }
        let count = max(1, CMSampleBufferGetNumSamples(sb))
        droppedFrames += count
        pendingDroppedFrames += count
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

// The camera and sound menus show at most eight characters of the chosen name.
final class ShortPopUpCell: NSPopUpButtonCell {
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        let text = title.string
        if text.hasSuffix(Viewer.sliceSuffix) {
            let short = "▯ " + String(text.dropLast(Viewer.sliceSuffix.count).prefix(6))
            return super.drawTitle(NSAttributedString(string: short, attributes: title.attributes(at: 0, effectiveRange: nil)),
                                   withFrame: frame, in: controlView)
        }
        let length = (String(text.prefix(8)) as NSString).length
        return super.drawTitle(title.attributedSubstring(from: NSRange(location: 0, length: min(length, title.length))),
                               withFrame: frame, in: controlView)
    }
}

// MARK: v6, the local API (ApiServer.swift): the same functions as the window and the record key
private func nn(_ x: Any?) -> Any { x ?? NSNull() }

extension Viewer {
    func apiSetQuality(_ quality: RecordQuality) {
        guard !isRecording else { return }
        recordQuality = quality
        UserDefaults.standard.set(quality.rawValue, forKey: "recordQuality")
        updateQualityKey()
    }

    func apiCaptureControls() -> [String: Any] {
        guard let device = current else { return ["active": false, "formats": []] }
        let active = Self.captureFormatKey(device.activeFormat)
        let formats = device.formats.map { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return [
                "id": Self.captureFormatKey(format),
                "width": Int(size.width),
                "height": Int(size.height),
                "pixelFormat": Self.pixelFormatName(CMFormatDescriptionGetMediaSubType(format.formatDescription)),
                "rates": Self.captureRates(for: format),
                "active": Self.captureFormatKey(format) == active,
            ] as [String: Any]
        }
        let focus = [
            "current": Self.focusName(device.focusMode),
            "locked": device.isFocusModeSupported(.locked),
            "auto": device.isFocusModeSupported(.autoFocus),
            "continuous": device.isFocusModeSupported(.continuousAutoFocus),
        ] as [String: Any]
        let exposure = [
            "current": Self.exposureName(device.exposureMode),
            "locked": device.isExposureModeSupported(.locked),
            "auto": device.isExposureModeSupported(.autoExpose),
            "continuous": device.isExposureModeSupported(.continuousAutoExposure),
        ] as [String: Any]
        let whiteBalance = [
            "current": Self.whiteBalanceName(device.whiteBalanceMode),
            "locked": device.isWhiteBalanceModeSupported(.locked),
            "auto": device.isWhiteBalanceModeSupported(.autoWhiteBalance),
            "continuous": device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance),
        ] as [String: Any]
        return ["active": true, "format": active, "fps": Int(fps), "formats": formats,
                "focus": focus, "exposure": exposure, "whiteBalance": whiteBalance]
    }

    func apiSetCapture(format: String?, rate: Double?, mode: String?, _ done: @escaping ([String: Any]) -> Void) {
        guard let device = current else { done(["ok": false, "error": "no active capture device"]); return }
        queue.async {
            do {
                try device.lockForConfiguration()
                if let format,
                   let selected = device.formats.first(where: { Self.captureFormatKey($0) == format }) {
                    device.activeFormat = selected
                }
                let requestedRate = rate ?? Double(self.fps)
                let supported = Self.supportedCaptureRate(requestedRate, for: device.activeFormat)
                let duration = Self.captureDuration(supported, for: device.activeFormat)
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                self.fps = Int32((1 / CMTimeGetSeconds(duration)).rounded())
                if let mode {
                    switch mode {
                    case "focus:locked": device.focusMode = .locked
                    case "focus:auto": device.focusMode = .autoFocus
                    case "focus:continuous": device.focusMode = .continuousAutoFocus
                    case "exposure:locked": device.exposureMode = .locked
                    case "exposure:auto": device.exposureMode = .autoExpose
                    case "exposure:continuous": device.exposureMode = .continuousAutoExposure
                    case "whiteBalance:locked": device.whiteBalanceMode = .locked
                    case "whiteBalance:auto": device.whiteBalanceMode = .autoWhiteBalance
                    case "whiteBalance:continuous": device.whiteBalanceMode = .continuousAutoWhiteBalance
                    default: break
                    }
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.resetFeedStats()
                    self.updateFeedStatsVisibility()
                    done(["ok": true, "controls": self.apiCaptureControls()])
                }
            } catch {
                DispatchQueue.main.async { done(["ok": false, "error": error.localizedDescription]) }
            }
        }
    }

    func apiStatus() -> [String: Any] {
        let rec = isRecording
        let vertical = wantedID.map { UserDefaults.standard.bool(forKey: "slice." + $0) } ?? false
        return ["version": VERSION, "camera": nn(current?.localizedName ?? wantedName), "id": nn(current?.uniqueID ?? wantedID), "waiting": waiting, "soundWaiting": micWaiting, "interrupted": interrupted, "slice": vertical,
                "recording": rec, "elapsed": rec ? Date().timeIntervalSince(recStart ?? Date()) : 0,
                "lastTake": nn(lastTake), "currentTake": rec ? nn(currentTake) : nn(nil),
                "quality": recordQuality.rawValue, "snapped": snapper.isSnapped,
                "bitrate": recordQuality.bitrate(width: feedWidth, height: feedHeight, fps: recordingFPS),
                "actualBitrate": nn(currentActualBitrate()),
                "recordFPS": Int(recordingFPS),
                "remainingSeconds": Self.recordingSecondsRemaining(
                    at: recordQuality.bitrate(width: feedWidth > 0 ? feedWidth : 1920,
                                              height: feedHeight > 0 ? feedHeight : 1080, fps: recordingFPS)),
                "remainingTime": Self.compactDuration(Self.recordingSecondsRemaining(
                    at: recordQuality.bitrate(width: feedWidth > 0 ? feedWidth : 1920,
                                              height: feedHeight > 0 ? feedHeight : 1080, fps: recordingFPS))),
                "fps": Int(fps), "size": vertical ? "\(Slicer.outW)x\(Slicer.outH)" : "\(feedWidth)x\(feedHeight)",
                "feed": ["width": feedWidth, "height": feedHeight, "format": feedPixelFormat,
                         "active": !feedStats.isHidden, "currentFPS": measuredFPS, "droppedFrames": measuredDrops],
                "levels": lastLevels.map { Double($0) },
                // v23: the take's sound, from the recorder itself
                "sound": nn(UserDefaults.standard.bool(forKey: "nosound") ? nil : currentMic?.localizedName),
                "soundWarning": nn(soundWarningNow),
                "takeSoundSeconds": liveRecorder?.audioSecondsWritten ?? 0,
                "sony": sonyLink.apiStatus()]
    }

    /// v23: GET /sounds and POST /sound {"name"|"id"|"none": true}, the sound menu's own action (remembered)
    func apiSounds() -> [[String: Any]] {
        mics.map { ["name": $0.localizedName, "id": $0.uniqueID, "current": $0.uniqueID == currentMic?.uniqueID,
                    "channels": $0.activeFormat.formatDescription.audioStreamBasicDescription.map { Int($0.mChannelsPerFrame) } ?? 0] }
    }
    func apiSetSound(name: String?, id: String?, none: Bool) -> (ok: Bool, error: String) {
        if isRecording { return (false, "not while recording") }
        if none { chooseMic(nil); return (true, "") }
        var i: Int?
        if let id { i = mics.firstIndex { $0.uniqueID == id } }
        else if let name, !name.isEmpty {
            let n = name.lowercased()
            i = mics.firstIndex { $0.localizedName.lowercased() == n } ?? mics.firstIndex { $0.localizedName.lowercased().contains(n) }
        }
        guard let i else { return (false, "no such sound input") }
        chooseMic(i)
        return (true, "")
    }
    var sony: SonyLink { sonyLink }

    private var recordingFPS: Int32 {
        let live = Int32(max(1, min(120, measuredFPS.rounded())))
        return measuredFPS > 0 ? live : fps
    }
    func apiCameras() -> [[String: Any]] {
        devices.map { ["name": $0.localizedName, "id": $0.uniqueID, "slice": savedSlice($0),
                       "current": $0.uniqueID == current?.uniqueID, "sony": Cameras.isSony($0)] }
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
    func apiSnap(_ on: Bool) -> Bool { if on != snapper.isSnapped { snapper.toggle() }; return snapper.isSnapped }
    func apiFront() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
}
