import AppKit
import ApplicationServices

// v15, Marko, 21.11.2026: "I want that this app recognize this remote window [Sony Imaging Edge Remote] and there should
// be some kind of a snap remote action button. It snaps it and they are together as one piece and if I resize any of
// them both are resizing. If I click snap and the remote is not open, the application opens it."
//
// SnapRemote joins this app's window and the main window of Sony's Imaging Edge Remote (bundle com.sony.Remote) into one
// piece: side by side, same height, top edges level, no gap. Moving or resizing either window moves or resizes the
// other. The remote is another process, so it is read and set through the Accessibility API (AXUIElement) and watched
// with an AXObserver. AX coordinates have their origin top-left of the main screen, AppKit's bottom-left: `flip` turns one
// into the other.
final class SnapRemote {
    static let bundleID = "com.sony.Remote"
    static let appPath = "/Applications/Imaging Edge/Remote.app"

    private let window: NSWindow
    private let say: (String) -> Void
    private let changed: () -> Void           // the button's title follows `isSnapped`
    private(set) var isSnapped = false
    private var remoteApp: NSRunningApplication?
    private var remoteWindow: AXUIElement?
    private var observer: AXObserver?
    private var remoteOnRight = true
    private var expectedOurs: NSRect?         // frames we set ourselves: their echo notifications are ignored
    private var expectedRemote: NSRect?
    private var opening = false

    init(window: NSWindow, say: @escaping (String) -> Void, changed: @escaping () -> Void) {
        self.window = window; self.say = say; self.changed = changed
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(oursChanged), name: NSWindow.didMoveNotification, object: window)
        nc.addObserver(self, selector: #selector(oursChanged), name: NSWindow.didResizeNotification, object: window)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appTerminated(_:)),
                                                          name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    // MARK: the button

    func toggle() { isSnapped ? unsnap() : snap() }

    func snap() {
        guard !isSnapped, !opening else { return }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            say("Snapping needs Accessibility.\nSystem Settings → Privacy & Security → Accessibility → switch on \(NAME), then press SNAP REMOTE again.")
            return
        }
        if let w = findWindow() { attach(w); return }
        // the remote is not open: open it, wait for its window
        guard FileManager.default.fileExists(atPath: Self.appPath) else {
            say("Sony Imaging Edge Remote is not installed (\(Self.appPath)).")
            return
        }
        opening = true
        say("Opening Sony Imaging Edge Remote…")
        let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = false
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: Self.appPath), configuration: cfg) { [weak self] _, err in
            DispatchQueue.main.async {
                guard let self else { return }
                if let err { self.opening = false; self.say("Sony Imaging Edge Remote did not open: \(err.localizedDescription)"); return }
                self.waitForWindow(tries: 40)
            }
        }
    }

    private func waitForWindow(tries: Int) {
        if let w = findWindow() { opening = false; attach(w); return }
        if tries <= 0 { opening = false; say("Sony Imaging Edge Remote opened but shows no window yet.\nPress SNAP REMOTE again."); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.waitForWindow(tries: tries - 1) }
    }

    func unsnap() {
        if let o = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode) }
        observer = nil; remoteWindow = nil; remoteApp = nil
        expectedOurs = nil; expectedRemote = nil
        isSnapped = false
        changed()
    }

    // MARK: finding and holding the remote window

    private func findWindow() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else { return nil }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &ref) == .success,
              let wins = ref as? [AXUIElement] else { return nil }
        // the main window: a standard window with a size (the remote's panel, not its live-view or dialogs)
        let std = wins.filter { w in
            var sub: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &sub)
            return (sub as? String) == (kAXStandardWindowSubrole as String) && axFrame(w) != nil
        }
        remoteApp = app
        return std.first
    }

    private func attach(_ w: AXUIElement) {
        remoteWindow = w
        guard let app = remoteApp, let r = remoteRect() else { say("The remote's window cannot be read."); return }
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<SnapRemote>.fromOpaque(refcon).takeUnretainedValue().remoteChanged()
        }
        if AXObserverCreate(app.processIdentifier, cb, &obs) == .success, let obs {
            let me = Unmanaged.passUnretained(self).toOpaque()
            for n in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification] {
                AXObserverAddNotification(obs, w, n as CFString, me)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            observer = obs
        }
        remoteOnRight = r.midX >= window.frame.midX      // it stays on the side it was on
        isSnapped = true
        changed()
        say("")
        placeRemote()                                    // our window leads the first time
        checkCamera()
    }

    // MARK: one piece

    private var screenH: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    private func flip(_ r: CGRect) -> NSRect { NSRect(x: r.minX, y: screenH - r.maxY, width: r.width, height: r.height) }
    private func axFrame(_ w: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s) == .success else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz), sz.width > 0 else { return nil }
        return CGRect(origin: pt, size: sz)
    }
    private func remoteRect() -> NSRect? { remoteWindow.flatMap { axFrame($0) }.map(flip) }
    private func setRemote(_ r: NSRect) {
        guard let w = remoteWindow else { return }
        var pt = CGPoint(x: r.minX, y: screenH - r.maxY), sz = r.size
        expectedRemote = r
        if let s = AXValueCreate(.cgSize, &sz) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, s) }
        if let p = AXValueCreate(.cgPoint, &pt) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, p) }
        if let actual = remoteRect() { expectedRemote = actual }
    }
    private func setOurs(_ r: NSRect) {
        expectedOurs = r
        window.setFrame(r, display: true)
        expectedOurs = window.frame
    }
    private func near(_ a: NSRect, _ b: NSRect?) -> Bool {
        guard let b else { return false }
        return abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    /// our window leads: the remote gets our height, our top edge, and sits against our side
    private func placeRemote() {
        guard isSnapped, let cur = remoteRect() else { return }
        let o = window.frame
        var r = NSRect(x: 0, y: o.maxY - o.height, width: cur.width, height: o.height)
        r.origin.x = remoteOnRight ? o.maxX : o.minX - r.width
        setRemote(r)
        // the remote may refuse that height (its own limits): then we take the height it kept
        if let got = remoteRect(), abs(got.height - o.height) > 1 {
            var ours = o; ours.size.height = got.height; ours.origin.y = o.maxY - got.height
            setOurs(ours)
            if let again = remoteRect() {
                var fix = again; fix.origin.y = ours.maxY - again.height
                fix.origin.x = remoteOnRight ? ours.maxX : ours.minX - again.width
                setRemote(fix)
            }
        }
    }

    /// the remote leads: we get its height, its top edge, and sit against its side
    private func placeOurs() {
        guard isSnapped, let r = remoteRect() else { return }
        var o = window.frame
        o.size.height = max(r.height, window.minSize.height)
        o.origin.y = r.maxY - o.height
        o.origin.x = remoteOnRight ? r.minX - o.width : r.maxX
        setOurs(o)
        if abs(window.frame.height - r.height) > 1 { placeRemote() }   // our minimum is taller than the remote
    }

    @objc private func oursChanged() {
        guard isSnapped, !window.styleMask.contains(.fullScreen) else { return }
        if near(window.frame, expectedOurs) { return }
        expectedOurs = nil
        placeRemote()
    }

    private func remoteChanged() {
        guard isSnapped, let r = remoteRect() else { return }
        if near(r, expectedRemote) { return }
        expectedRemote = nil
        if window.styleMask.contains(.fullScreen) { return }
        remoteOnRight = r.midX >= window.frame.midX
        placeOurs()
    }

    @objc private func appTerminated(_ n: Notification) {
        guard isSnapped, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == Self.bundleID else { return }
        unsnap()
    }

    // MARK: the camera

    /// Sony's remote only works when the camera is on the network or the cable and has allowed the connection.
    private func checkCamera() {
        guard !Cameras.all().contains(where: Cameras.isSony) else { return }
        say("Sony camera not found.\nOn the camera's screen press ENABLE (allow the connection from this computer),\nthen wait a few seconds. If there is no ENABLE, check the cable or Wi-Fi.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            if self?.isSnapped == true, Cameras.all().contains(where: Cameras.isSony) { self?.say("") }
        }
    }
}
