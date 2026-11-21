// SonyDiag.swift (v23, 21.11.2026): why the Sony is or is not reachable, in stages, never one generic "not found".
// Marko: "I open the menu in my Sony. It's on Wi-Fi, and the application says it's not on Wi-Fi." v22 said "No Sony
// answered on the Mantra network" while the camera answered ping at 192.168.1.100 (MAC 80:99:9B:13:AD:3F): only its remote
// port was closed, because its remote control was on the USB cable (Imaging Edge Remote held it). Each stage is measured:
//   1 the Mac's LAN interface and address   2 the camera reachable (ping, ARP: IP and MAC)   3 SSDP answer
//   4 TCP 15740 (PTP-IP) and 22 (SSH, Access Authentication)   5 the camera on USB and who holds it
import Foundation

/// a JSON value or null
func orNull(_ v: Any?) -> Any { v ?? NSNull() }

struct SonyDiagnosis {
    var lan: (String, String)?          // (interface, address) on the camera's subnet, else the first LAN
    var allLans: [(String, String)] = []
    var address = ""
    var ping = false
    var mac: String?
    var ssdp: [String] = []
    var port15740 = false
    var port22 = false
    var usb: SonyUSBPresence?
    var at = Date()

    var reachable: Bool { ping || mac != nil }
    var wifiRemoteOpen: Bool { port15740 || port22 || !ssdp.isEmpty }

    /// the stages, one line each, for the overlay
    var lines: [String] {
        var l: [String] = []
        if let lan { l.append("1 Mac: \(lan.0) \(lan.1)\(allLans.count > 1 ? " (also " + allLans.filter { $0 != lan }.map { "\($0.0) \($0.1)" }.joined(separator: ", ") + ")" : "")") }
        else { l.append("1 Mac: NO local network (no Wi-Fi or Ethernet address)") }
        if address.isEmpty { l.append("2 Camera address: none saved, only SSDP can find it") }
        else { l.append("2 Camera \(address): " + (reachable ? "ON THE NETWORK (\(ping ? "answers ping" : "no ping")\(mac.map { ", MAC \($0.uppercased())" } ?? ""))" : "does not answer (no ping, no ARP entry)")) }
        l.append("3 SSDP: " + (ssdp.isEmpty ? "no Sony answered" : "answered (\(ssdp.count))"))
        l.append("4 Remote port 15740: " + (port15740 ? "OPEN" : "closed") + " · SSH 22: " + (port22 ? "OPEN" : "closed"))
        if let u = usb {
            l.append("5 USB: \(u.product) on the cable" + (u.heldByOther ? ", held by \(u.ownerName)" : (u.owner.map { ", held by \($0)" } ?? ", free")))
        } else { l.append("5 USB: no Sony on the cable") }
        return l
    }

    /// one plain conclusion with the camera setting that opens the road
    var verdict: String {
        if wifiRemoteOpen { return "The camera's Wi-Fi remote is open." }
        if let u = usb, u.heldByOther {
            return "The camera is on USB and \(u.ownerName) holds it. TAKE CONTROL closes \(u.ownerName) and connects here over USB."
                + (reachable ? " (It IS on Wi-Fi too, but its Wi-Fi remote is off while the cable has it.)" : "")
        }
        if let _ = usb { return "The camera is on USB and free: connecting over USB." }
        if reachable {
            return "The camera IS on Wi-Fi (\(address)), but its remote control is off. On the camera: MENU → Network → Cnct./Remote Sht. → Remote Shoot Function → Remote Shooting: On (Wi-Fi Connect: On, same router as the Mac)."
        }
        if lan == nil { return "This Mac has no local network now." }
        return "No camera at \(address.isEmpty ? "a saved address" : address). On the camera: MENU → Network → Wi-Fi → Wi-Fi Connect: On (router “mantra”), then MENU → Network → Wi-Fi → Display Wi-Fi Info. shows its address."
    }

    var json: [String: Any] {
        var u: Any = NSNull()
        if let usb { u = ["product": usb.product, "productID": usb.productID, "owner": orNull(usb.owner), "heldByOther": usb.heldByOther] as [String: Any] }
        return ["lan": orNull(lan.map { ["interface": $0.0, "address": $0.1] }), "address": address,
                "ping": ping, "mac": orNull(mac), "ssdp": ssdp, "port15740": port15740, "port22": port22, "usb": u,
                "stages": lines, "verdict": verdict, "at": ISO8601DateFormatter().string(from: at)]
    }

    /// measured now; blocks for about 5 s (SSDP 3 s, ping 1 s, ports 1.5 s each at most)
    static func run(address: String, log: ((String) -> Void)? = nil) -> SonyDiagnosis {
        var d = SonyDiagnosis()
        d.address = address
        d.allLans = SonySSDP.interfaces()
        let prefix = address.split(separator: ".").prefix(3).joined(separator: ".") + "."
        d.lan = d.allLans.first { !address.isEmpty && $0.1.hasPrefix(prefix) } ?? d.allLans.first
        let group = DispatchGroup()
        let lock = NSLock()
        group.enter(); DispatchQueue.global().async { let s = SonySSDP.search(seconds: 3, log: log); lock.lock(); d.ssdp = s; lock.unlock(); group.leave() }
        if !address.isEmpty {
            group.enter(); DispatchQueue.global().async { let p = ping(address); lock.lock(); d.ping = p; lock.unlock(); group.leave() }
            group.enter(); DispatchQueue.global().async { let a = SonyTCP.canConnect(address, 15740, timeout: 1.5); lock.lock(); d.port15740 = a; lock.unlock(); group.leave() }
            group.enter(); DispatchQueue.global().async { let a = SonyTCP.canConnect(address, 22, timeout: 1.5); lock.lock(); d.port22 = a; lock.unlock(); group.leave() }
        }
        group.enter(); DispatchQueue.global().async { let u = SonyUSBPresence.find(); lock.lock(); d.usb = u; lock.unlock(); group.leave() }
        _ = group.wait(timeout: .now() + 6)
        if !address.isEmpty { lock.lock(); d.mac = arp(address); lock.unlock() }   // after the ping, the ARP entry is fresh
        d.at = Date()
        return d
    }

    private static func runTool(_ path: String, _ args: [String], seconds: Double) -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let o = Pipe(); p.standardOutput = o; p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "") }
        let deadline = Date().addingTimeInterval(seconds)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
    static func ping(_ ip: String) -> Bool { runTool("/sbin/ping", ["-c", "1", "-t", "2", ip], seconds: 3).0 == 0 }
    /// "? (192.168.1.100) at 80:99:9b:13:ad:3f on en0 ..." → the MAC
    static func arp(_ ip: String) -> String? {
        let (_, out) = runTool("/usr/sbin/arp", ["-n", ip], seconds: 2)
        guard let r = out.range(of: " at ") else { return nil }
        let mac = out[r.upperBound...].prefix { $0 != " " }
        return mac.contains(":") ? String(mac) : nil
    }
}
