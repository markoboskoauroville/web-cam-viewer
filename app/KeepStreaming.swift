import AVFoundation

// v4, Marko, 1.11.2026: "make my application activate this camera streaming always even if it's not selected."
// A Sony in USB Streaming stays on Streaming:Standby until an app on the Mac opens it (Help Guide p.415). While the app
// runs, a second, quiet session holds every connected Sony (ILCE-…) open whenever it is not the chosen camera, so the
// camera stays on Streaming:Output. Frames are dropped at once; the camera's format is never touched (another app, a
// lesson, may be using the same stream).
final class KeepStreaming: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let q = DispatchQueue(label: "webcamviewer.keepstreaming", qos: .utility)
    private var held: String?

    static func isSony(_ d: AVCaptureDevice) -> Bool {
        d.localizedName.uppercased().hasPrefix("ILCE") || d.manufacturer.uppercased().contains("SONY")
    }

    /// hold `device` open, or nothing (nil)
    func hold(_ device: AVCaptureDevice?) {
        let id = device?.uniqueID
        q.async {
            guard id != self.held else { return }
            self.session.beginConfiguration()
            self.session.inputs.forEach(self.session.removeInput)
            self.session.outputs.forEach(self.session.removeOutput)
            if let device, let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) {
                self.session.addInput(input)
                // 1080p, the Sony's own streaming size, so holding it never lowers what another app receives
                if self.session.canSetSessionPreset(.hd1920x1080) { self.session.sessionPreset = .hd1920x1080 }
                let out = AVCaptureVideoDataOutput()
                out.alwaysDiscardsLateVideoFrames = true
                out.setSampleBufferDelegate(self, queue: self.q)
                if self.session.canAddOutput(out) { self.session.addOutput(out) }
                self.held = device.uniqueID
            } else { self.held = nil }
            self.session.commitConfiguration()
            if self.held != nil { if !self.session.isRunning { self.session.startRunning() } }
            else if self.session.isRunning { self.session.stopRunning() }
            NSLog("KeepStreaming: %@", self.held == nil ? "nothing held" : "holding \(device?.localizedName ?? "?")")
        }
    }

    func stop() { hold(nil) }

    /// let go now and wait until it is let go (before the chosen camera opens the same Sony)
    func releaseNow() { hold(nil); q.sync {} }

    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {}
}
