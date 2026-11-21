// SonyUSB.swift (v23, 21.11.2026): the second road to the α7 V, the USB cable. Marko: "Please make it connect to the camera
// and remotely control it." The camera sat on USB (ILCE-7M5, 0x054c:0x0f56) with Sony's Imaging Edge Remote holding its PTP
// interface, while its Wi-Fi had no remote port open. The same Sony Camera Control PTP 3 calls as over Wi-Fi go through
// ImageCaptureCore's raw PTP pipe (ICCameraDevice.requestSendPTPCommand), behind the SonyTransport protocol, so SonyLink,
// the overlay and the API do not know which road is used. Camera: MENU → Setup → USB → USB Cnct Mode = Remote Shoot/Trn.
// Only one program can hold the camera's USB PTP interface: IOKit's "UsbExclusiveOwner" says which ("pid 4939, Remote").
import Foundation
import ImageCaptureCore
import IOKit

/// the Sony on the cable, as IOKit sees it (no session needed, nothing is opened)
struct SonyUSBPresence {
    var product: String          // "ILCE-7M5"
    var productID: Int
    var owner: String?           // "pid 4939, Remote" while another program holds the PTP interface
    var ownerPID: Int32? {
        guard let o = owner, o.hasPrefix("pid ") else { return nil }
        return Int32(o.dropFirst(4).prefix { $0.isNumber })
    }
    /// held by a program that is not macOS's own camera service and not this app
    var heldByOther: Bool {
        guard let o = owner, !o.isEmpty else { return false }
        if let p = ownerPID, p == getpid() { return false }
        let l = o.lowercased()
        return !(l.contains("ptpcamera") || l.contains("imagecapture") || l.contains("icdevice"))
    }
    var ownerName: String {
        guard let o = owner, let comma = o.firstIndex(of: ",") else { return owner ?? "" }
        let n = o[o.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        return n == "Remote" ? "Imaging Edge Remote" : n
    }

    static func find() -> SonyUSBPresence? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        while case let dev = IOIteratorNext(iter), dev != 0 {
            defer { IOObjectRelease(dev) }
            guard intProp(dev, "idVendor") == 0x054C else { continue }
            var found = SonyUSBPresence(product: strProp(dev, "USB Product Name") ?? "Sony", productID: intProp(dev, "idProduct") ?? 0, owner: nil)
            // the PTP interface (class 6 = still image) and who holds it
            var kids: io_iterator_t = 0
            if IORegistryEntryCreateIterator(dev, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &kids) == KERN_SUCCESS {
                while case let k = IOIteratorNext(kids), k != 0 {
                    defer { IOObjectRelease(k) }
                    if intProp(k, "bInterfaceClass") == 6 { found.owner = strProp(k, "UsbExclusiveOwner"); break }
                }
                IOObjectRelease(kids)
            }
            return found
        }
        return nil
    }
    private static func intProp(_ e: io_registry_entry_t, _ key: String) -> Int? {
        (IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
    }
    private static func strProp(_ e: io_registry_entry_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }
}

/// Sony Camera Control PTP over USB through ImageCaptureCore. tx() blocks the caller (SonyLink's work queue) while the
/// browser and the device answer on the main thread.
final class SonyUSB: NSObject, SonyTransport, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    private var browser: ICDeviceBrowser?
    private var camera: ICCameraDevice?
    private var transaction: UInt32 = 1
    private let opened = DispatchSemaphore(value: 0)
    private var openError: String?
    private(set) var name = "Sony"
    private var log: (String) -> Void

    init(log: @escaping (String) -> Void) { self.log = log }

    /// find the Sony among the Mac's cameras and open a session; throws with a plain sentence when it cannot
    func open(timeout: Double = 12) throws {
        DispatchQueue.main.sync {
            let b = ICDeviceBrowser()
            b.delegate = self
            b.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
                ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
            browser = b
            b.start()
        }
        if opened.wait(timeout: .now() + timeout) == .timedOut {
            close()
            throw SonyPtpError.unexpected(camera == nil
                ? "the Mac's camera service did not offer the Sony on USB within \(Int(timeout)) s (USB Cnct Mode must be Remote Shoot/Trn.)"
                : "the Sony on USB did not open its session within \(Int(timeout)) s")
        }
        if let e = openError { close(); throw SonyPtpError.unexpected("USB session: \(e)") }
    }

    private func container(_ code: UInt16, _ params: [UInt32]) -> Data {
        var w = SonyWriter()
        w.u32(UInt32(12 + 4 * params.count)); w.u16(1); w.u16(code); w.u32(transaction)
        transaction &+= 1
        params.forEach { w.u32($0) }
        return w.data
    }

    func tx(_ op: UInt16, _ params: [UInt32], out: Data?, timeout: Double) throws -> SonyReply {
        guard let cam = camera else { throw SonyPtpError.unexpected("the Sony left the USB cable") }
        let cmd = container(op, params)
        let done = DispatchSemaphore(value: 0)
        var inData = Data(), response = Data(), failure: String?
        DispatchQueue.main.async {
            cam.requestSendPTPCommand(cmd, outData: out) { d, r, e in
                inData = d; response = r; failure = e?.localizedDescription
                done.signal()
            }
        }
        if done.wait(timeout: .now() + timeout) == .timedOut { throw SonyPtpError.unexpected("USB: no answer to \(sonyHex(op)) within \(Int(timeout)) s") }
        if let failure, response.count < 8 { throw SonyPtpError.unexpected("USB \(sonyHex(op)): \(failure)") }
        // the response container: length, type 3, code, transaction, parameters
        guard response.count >= 8 else { throw SonyPtpError.unexpected("USB \(sonyHex(op)): empty response") }
        let code = UInt16(response[response.startIndex + 6]) | UInt16(response[response.startIndex + 7]) << 8
        var ps: [UInt32] = []
        var o = 12
        while o + 4 <= response.count { ps.append(response.sonyU32(at: o) ?? 0); o += 4 }
        // a data phase that still carries its own 12-byte container header (type 2) is unwrapped
        if inData.count >= 12, let len = inData.sonyU32(at: 0), Int(len) == inData.count,
           inData[inData.startIndex + 4] == 2, inData[inData.startIndex + 5] == 0 {
            inData = inData.subdata(in: (inData.startIndex + 12)..<inData.endIndex)
        }
        return SonyReply(code: code, data: inData, params: ps)
    }

    func close() {
        let cam = camera, b = browser
        camera = nil; browser = nil
        DispatchQueue.main.async {
            cam?.requestCloseSession()
            b?.stop()
        }
    }

    // MARK: browser and device (main thread)

    func deviceBrowser(_ b: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard camera == nil, let cam = device as? ICCameraDevice else { return }
        let n = (cam.name ?? "").uppercased()
        guard cam.usbVendorID == 0x054C || n.contains("ILCE") || n.contains("SONY") else { return }
        camera = cam
        name = cam.name ?? "Sony"
        log("USB: found \(name), opening its session")
        cam.delegate = self
        cam.requestOpenSession()
    }
    func deviceBrowser(_ b: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if device === camera { camera = nil; log("USB: the Sony left") }
    }
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error { openError = error.localizedDescription }
        opened.signal()
    }
    func didRemove(_ device: ICDevice) { if device === camera { camera = nil } }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}
