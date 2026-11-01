// After a build: the running copy is quit through Accessibility (Marko, 31.10.2026: "when you make new version close
// this one which is running and run the new one ... close it through accessibility"), then the new one is opened.
// First the window's OFF (AXIdentifier "off"; "quit" in v4–v6, which had a QUIT); a copy without it (v3 and older, or no window open) is
// quit by its own menu: the app menu's "Quit …" item. Never killed: if it does not go, the script says so and stops.
// Usage: swift tools/relaunch.swift <bundle id> <app path>
import AppKit
import ApplicationServices

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: relaunch.swift <bundle id> <app path>"); exit(2) }
let bundle = args[1], path = args[2]

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func find(_ e: AXUIElement, depth: Int = 0, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
    if match(e) { return e }
    if depth > 30 { return nil }
    for c in children(e) { if let f = find(c, depth: depth + 1, match) { return f } }
    return nil
}

let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
if !running.isEmpty {
    guard AXIsProcessTrusted() else { print("relaunch: no Accessibility for this terminal, the old copy is still running"); exit(1) }
    for app in running {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        // v5: a copy holding takes is not quit: they live only in memory and a build would throw them away
        let wins = (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var takes = 0
        func count(_ e: AXUIElement, _ d: Int) {
            if let id = attr(e, "AXIdentifier") as? String, id.hasPrefix("take") { takes += 1 }
            if d < 30 { for c in children(e) { count(c, d + 1) } }
        }
        for w in wins { count(w, 0) }
        if takes > 0 && !args.contains("--force") {
            print("relaunch: pid \(app.processIdentifier) holds \(takes) take(s), not quit; the new version opens at its next start")
            exit(3)
        }
        // the press is judged by the app going, not by the press's answer: an app that quits inside the action never
        // answers it (v4's first run: the QUIT worked and AXPress still came back as an error)
        func gone(_ secs: Double) -> Bool {
            let end = Date().addingTimeInterval(secs)
            while !app.isTerminated && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            return app.isTerminated
        }
        var how = ""
        let windows = (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        if let quit = windows.lazy.compactMap({ w in find(w) { ["off", "quit"].contains(attr($0, "AXIdentifier") as? String ?? "") } }).first {
            _ = AXUIElementPerformAction(quit, kAXPressAction as CFString)
            if gone(4) { how = "its OFF" }
        }
        if how.isEmpty, let bar = attr(ax, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID(),
           let appMenu = children(bar as! AXUIElement).dropFirst().first,
           let item = find(appMenu, { (attr($0, kAXTitleAttribute) as? String)?.hasPrefix("Quit") == true }) {
            _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
            if gone(6) { how = "its menu's Quit" }
        }
        if how.isEmpty { print("relaunch: pid \(app.processIdentifier) is still running; nothing pressed made it quit"); exit(1) }
        print("relaunch: quit pid \(app.processIdentifier) through \(how)")
    }
}
let cfg = NSWorkspace.OpenConfiguration()
var newPid: pid_t = 0
let sem = DispatchSemaphore(value: 0)
NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: cfg) { app, err in
    newPid = app?.processIdentifier ?? 0
    if let e = err { print("relaunch: open failed: \(e.localizedDescription)") }
    sem.signal()
}
while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
if newPid == 0 { exit(1) }
print("relaunch: opened pid \(newPid)")
