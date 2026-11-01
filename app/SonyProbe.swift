import AppKit

// --sony-probe <file>: open the Sony, ask GetDeviceInfo (0x1001), write what came back, quit (a test door, no window).
enum SonyProbe {
    static var link: SonyLink?
    static func run(_ path: String) {
        var lines: [String] = []
        func out(_ s: String) { lines.append(s); try? lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8) }
        let l = SonyLink(); link = l
        l.log = { out("log: \($0)") }
        l.onReady = { cam in
            out("ready: \(cam.name ?? "?") vendor \(String(format: "0x%04X", cam.usbVendorID)) product \(String(format: "0x%04X", cam.usbProductID))")
            l.send(0x1001) { data, r in
                out(String(format: "GetDeviceInfo response 0x%04X, %d bytes", r.code, data.count))
                out("hex: " + data.prefix(64).map { String(format: "%02x", $0) }.joined())
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
        l.onGone = { out("gone") }
        l.start()
        out("browsing")
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { out("timeout"); NSApp.terminate(nil) }
    }
}
