import Foundation
import ImageCaptureCore

// The Sony on USB (USB Connection Mode: Remote Shoot), reached through ImageCaptureCore's raw PTP pipe
// (ICCameraDevice.requestSendPTPCommand), so no Sony SDK is needed. The protocol is Sony's Camera Control PTP 3
// (SONY_REMOTE_CONTROLLER reference/sony-official, Camera Remote Command 2.02.00), the same one TC Jam speaks on Android.
final class SonyLink: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    private let browser = ICDeviceBrowser()
    private(set) var camera: ICCameraDevice?
    private var transaction: UInt32 = 1
    private let q = DispatchQueue(label: "webcamviewer.sony")
    private var busy = false
    private var pending: [(Data, Data?, (Data, PTPResponse) -> Void)] = []

    var onReady: ((ICCameraDevice) -> Void)?
    var onGone: (() -> Void)?
    var onEvent: ((UInt16, [UInt32]) -> Void)?
    var log: (String) -> Void = { _ in }

    struct PTPResponse { let code: UInt16; let params: [UInt32]; var ok: Bool { code == 0x2001 } }

    func start() {
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
    }

    // MARK: PTP

    /// a PTP command container: length, type 1, code, transaction, parameters (little-endian)
    private func container(_ code: UInt16, _ params: [UInt32]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        u32(UInt32(12 + 4 * params.count)); u16(1); u16(code); u32(transaction)
        transaction &+= 1
        params.forEach(u32)
        return d
    }

    private static func parse(_ r: Data) -> PTPResponse {
        guard r.count >= 12 else { return PTPResponse(code: 0, params: []) }
        let code = r.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) }.littleEndian
        var p: [UInt32] = []
        var o = 12
        while o + 4 <= r.count { p.append(r.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt32.self) }.littleEndian); o += 4 }
        return PTPResponse(code: code, params: p)
    }

    /// one command at a time, in order; `out` is the data phase sent to the camera
    func send(_ code: UInt16, _ params: [UInt32] = [], out: Data? = nil, done: @escaping (Data, PTPResponse) -> Void = { _, _ in }) {
        q.async {
            self.pending.append((self.container(code, params), out, done))
            self.next()
        }
    }

    private func next() {
        guard !busy, let cam = camera, !pending.isEmpty else { return }
        busy = true
        let (cmd, out, done) = pending.removeFirst()
        cam.requestSendPTPCommand(cmd, outData: out) { data, response, error in
            let r = Self.parse(response)
            if let error { self.log("PTP error \(error.localizedDescription)") }
            done(data, r)
            self.q.async { self.busy = false; self.next() }
        }
    }

    // MARK: browser

    func deviceBrowser(_ b: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let cam = device as? ICCameraDevice else { return }
        let isSony = (cam.name ?? "").uppercased().contains("ILCE") || (cam.name ?? "").uppercased().contains("SONY")
            || cam.usbVendorID == 0x054C
        guard isSony, camera == nil else { return }
        log("found \(cam.name ?? "?")")
        camera = cam
        cam.delegate = self
        cam.requestOpenSession()
    }

    func deviceBrowser(_ b: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if device === camera { gone() }
    }

    private func gone() {
        camera = nil
        q.async { self.pending.removeAll(); self.busy = false }
        DispatchQueue.main.async { self.onGone?() }
    }

    // MARK: device delegate

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error { log("session: \(error.localizedDescription)"); return }
        log("session open")
    }
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        DispatchQueue.main.async { self.onReady?(device) }
    }
    func didRemove(_ device: ICDevice) { if device === camera { gone() } }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) { if device === camera { gone() } }
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        let r = Self.parse(eventData)
        DispatchQueue.main.async { self.onEvent?(r.code, r.params) }
    }
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}
