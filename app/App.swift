// Webcam Recorder (Mantra), until v1 Web Cam Viewer (Mantra): the picture of any camera the Mac sees, and nothing else.
//
// v1, Marko, 1.11.2026: "Web Cam Viewer is a simple client for macOS, of course in Swift, which simply shows anything
// that can be viewed on any webcam. It just displays the picture. It has only a drop-down menu at the top, an X for
// closing, and at the top I just choose any webcam the system sees, and you show me the picture. Very simple"
//
// So: one window, a bar at the top with the camera menu on the left and ✕ on the right (✕ quits, the camera light goes
// off), the picture under it, whole, never cropped.
// v2, the same day: a sound input menu beside the camera, the VU hairline of Mantra Manual Camera on the left edge, a
// record key (~/Movies/mb_<date>_<time>.mkv, H.264 at native feed settings, AAC, a time code = the real-time clock, shown
// REC HH:MM:SS:FF bottom middle while recording), and full screen: the corners key, ⌘F in, Escape out, only the picture. PERMISSIONS (amber) appears beside ✕ only while the camera is refused.
import AppKit
import AVFoundation

// v3: two VU hairlines, left and right channel, side by side on the left edge; the record key shows a see-through
// red under the mouse.
// v21 (21.11.2026): the SONY key: our own Sony PTP control of the α7 V as an overlay over the picture (Sony*.swift).
// v22 (21.11.2026): the current Picture Profile / lock key marked by a green border and title, also in an inactive window.
let VERSION = 27
let NAME = "Webcam Recorder (Mantra)"
let APP_NAME = NAME   // v23: the updater kit (MANTRA_MANIFEST kits/mac-updater) names the app by APP_NAME

final class Delegate: NSObject, NSApplicationDelegate {
    var viewer: Viewer!
    var selftest: String?
    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        viewer = Viewer(test: selftest != nil || CommandLine.arguments.contains("--quiet"))
        viewer.show()
        if let out = selftest { viewer.runSelftest(to: out) }
        // v23 (update-at-start.md): a newer release on GitHub is offered at start; never in a test run
        else if !CommandLine.arguments.contains("--quiet") && !CommandLine.arguments.contains("--sony-demo") { Updater.checkAtStart() }
    }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows flag: Bool) -> Bool { viewer.show(); return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) { viewer?.stop() }

    // the app menu only for ⌘Q and the relaunch after a build (tools/relaunch.swift quits through "Quit …")
    private func buildMenu() {
        let main = NSMenu(), appItem = NSMenuItem()
        main.addItem(appItem)
        let m = NSMenu()
        m.addItem(withTitle: "Quit \(NAME)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = m
        // v21: the Sony overlay has text fields (address, user, password): ⌘X ⌘C ⌘V ⌘A must work in them
        let editItem = NSMenuItem(); main.addItem(editItem)
        let e = NSMenu(title: "Edit")
        e.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        e.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        e.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        e.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = e
        NSApp.mainMenu = main
    }
}

@main
enum Main {
    static let delegate = Delegate()
    static func main() {
        let a = CommandLine.arguments
        // v23: a dead ffmpeg helper must make a pipe write fail (and the take say so), never kill the app with SIGPIPE
        signal(SIGPIPE, SIG_IGN)
        // v21, SSH_ASKPASS: /usr/bin/ssh runs this same program to ask for the Sony's password; print it and leave.
        // A yes/no host question is never answered yes here: the fingerprint is approved in the overlay.
        let env = ProcessInfo.processInfo.environment
        if let pw = env["WCR_SONY_ASKPASS"], env["SSH_ASKPASS_REQUIRE"] != nil {
            let prompt = a.dropFirst().joined(separator: " ").lowercased()
            print(prompt.contains("yes/no") || prompt.contains("fingerprint") ? "no" : pw)
            exit(0)
        }
        // --sony-selftest <report.txt>: the Sony dataset parser and labels checked against the demo camera, no window
        if let i = a.firstIndex(of: "--sony-selftest"), i + 1 < a.count {
            let (ok, line) = SonyDemo.roundTrip()
            try? "\(NAME) v\(VERSION)\n\(line)\n".write(toFile: a[i + 1], atomically: true, encoding: .utf8)
            print(line)
            exit(ok ? 0 : 1)
        }
        // --quiet: a test start, on the MacBook Pro screen, without taking Marko's focus
        // --selftest <report.txt>: every camera in turn, frames counted and checked for movement, then quit
        if let i = a.firstIndex(of: "--selftest"), i + 1 < a.count { delegate.selftest = a[i + 1] }
        if a.contains("--list") {
            for d in Cameras.all() { print("\(d.localizedName)\t\(d.deviceType.rawValue)\t\(d.uniqueID)") }
            exit(0)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}
