// Webcam Recorder (Mantra), until v1 Web Cam Viewer (Mantra): the picture of any camera the Mac sees, and nothing else.
//
// v1, Marko, 1.11.2026: "Web Cam Viewer is a simple client for macOS, of course in Swift, which simply shows anything
// that can be viewed on any webcam. It just displays the picture. It has only a drop-down menu at the top, an X for
// closing, and at the top I just choose any webcam the system sees, and you show me the picture. Very simple"
//
// So: one window, a bar at the top with the camera menu on the left and ✕ on the right (✕ quits, the camera light goes
// off), the picture under it, whole, never cropped.
// v2, the same day: a sound input menu beside the camera, the VU hairline of Mantra Manual Camera on the left edge, a
// record key (~/Movies/mb_<date>_<time>.mov, H.265 1080p 10 Mb/s, AAC, a time code track = the real-time clock, shown
// REC HH:MM:SS:FF bottom middle while recording), and full screen: the corners key, ⌘F in, Escape out, only the picture. PERMISSIONS (amber) appears beside ✕ only while the camera is refused.
import AppKit
import AVFoundation

let VERSION = 2
let NAME = "Webcam Recorder (Mantra)"

final class Delegate: NSObject, NSApplicationDelegate {
    var viewer: Viewer!
    var selftest: String?
    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        viewer = Viewer(test: selftest != nil || CommandLine.arguments.contains("--quiet"))
        viewer.show()
        if let out = selftest { viewer.runSelftest(to: out) }
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
        NSApp.mainMenu = main
    }
}

@main
enum Main {
    static let delegate = Delegate()
    static func main() {
        let a = CommandLine.arguments
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
