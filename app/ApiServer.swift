import Foundation
import Network

// v6, Marko 13.11.2026 (MPA_LESSONS_ANALYZER request "Beatrice guides the shooting"): "Beatrice needs to guide me ... I say
// yes, and then it opens up the Sony webcam, and it records. I press stop". A tiny HTTP API on 127.0.0.1:8867 (loopback
// only) so the MPA Lessons Analyzer and Queen can drive the app. Every handler runs on the main queue and calls the same
// Viewer functions the window and the record key call. Port written to ~/.mantra/ports/webcam-recorder.
//   v23: GET /sounds  POST /sound {"name"|"id"|"none"}  GET /sony/status[?check=1]  POST /sony/check|connect|disconnect|takecontrol
//   POST /sony/rec {"on"}  GET /sony/prop?code=  POST /sony/set {"code"|"name", "value"|"label"}
//   v32: GET /virtualcam/status  POST /virtualcam {"on"?, "extraDelayMs"?, "maxHoldMs"?, "trimMs"?, "stamp"?}
//   v31: GET /gain  POST /gain {"db"|"delta"|"reset"|"auto"|"undo"|"stop"|"clear"|"format":"aac"|"f32"|"panel", "uid"?}
//   v30: GET /sync  POST /sync {"ms"|"delta"|"reset", "uid"|"name"?} | {"audio":{"uid","ms"}} | {"video":{"uid"?,"ms"}} | {"scratch"}
//   GET /status   GET /cameras   GET /capture   POST /camera {"name"|"id","slice"}   POST /capture {"format"|"rate"|"mode"}   POST /quality {"quality"}   POST /record/start {"name"?}   POST /record/stop   POST /front   POST /fullscreen {"on"}   POST /snap {"on"}
final class ApiServer {
    static let port: UInt16 = 8867
    private var listener: NWListener?
    private weak var viewer: Viewer?

    init(viewer: Viewer) { self.viewer = viewer }

    func start() {
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        guard let l = try? NWListener(using: p) else { NSLog("Webcam Recorder: API port %d busy", Self.port); return }
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.start(queue: .global())
        listener = l
        let dir = NSString(string: "~/.mantra/ports").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? "\(Self.port)\n".write(toFile: dir + "/webcam-recorder", atomically: true, encoding: .utf8)
    }
    func stop() { listener?.cancel() }

    private func serve(_ c: NWConnection) {
        c.start(queue: .global())
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ acc: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { c.cancel(); return }
            var buf = acc; if let data { buf.append(data) }
            if let req = Self.parse(buf) { self.handle(req, c); return }
            if done || err != nil || buf.count > 1_000_000 { c.cancel(); return }
            self.read(c, buf)
        }
    }

    struct Request { let method: String; let path: String; let body: [String: Any]; var query = "" }

    /// nil while the request is not complete yet
    private static func parse(_ d: Data) -> Request? {
        guard let r = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: d[..<r.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return Request(method: "", path: "", body: [:]) }
        var len = 0
        for l in lines.dropFirst() where l.lowercased().hasPrefix("content-length:") {
            len = Int(l.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let body = d[r.upperBound...]
        if body.count < len { return nil }
        let obj = (try? JSONSerialization.jsonObject(with: body.prefix(len))) as? [String: Any] ?? [:]
        let parts = String(first[1]).components(separatedBy: "?")
        return Request(method: String(first[0]).uppercased(), path: parts[0], body: obj, query: parts.count > 1 ? parts[1] : "")
    }

    private func handle(_ req: Request, _ c: NWConnection) {
        DispatchQueue.main.async { self.route(req, c) }
    }

    private func route(_ req: Request, _ c: NWConnection) {
        do {
            guard let v = self.viewer else { Self.send(c, 503, ["error": "closing"]); return }
            switch (req.method, req.path) {
            case ("GET", "/status"): Self.send(c, 200, v.apiStatus())
            case ("GET", "/cameras"): Self.send(c, 200, ["cameras": v.apiCameras()])
            case ("GET", "/capture"): Self.send(c, 200, v.apiCaptureControls())
            case ("POST", "/capture"):
                v.apiSetCapture(format: req.body["format"] as? String, rate: (req.body["rate"] as? NSNumber)?.doubleValue,
                                mode: req.body["mode"] as? String) { Self.send(c, 200, $0) }
            case ("POST", "/quality"):
                let quality = (req.body["quality"] as? String).flatMap(RecordQuality.init(rawValue:))
                if let quality { v.apiSetQuality(quality); Self.send(c, 200, v.apiStatus()) }
                else { Self.send(c, 409, ["error": "quality must be low, mid or high"]) }
            case ("POST", "/camera"):
                let r = v.apiSetCamera(name: req.body["name"] as? String, id: req.body["id"] as? String, slice: req.body["slice"] as? Bool)
                if r.ok { Self.send(c, 200, v.apiStatus()) } else { Self.send(c, 404, ["error": r.error]) }
            case ("POST", "/record/start"):
                v.apiStart(title: req.body["name"] as? String) { url, err in
                    if let url { var s = v.apiStatus(); s["path"] = url.path; Self.send(c, 200, s) }
                    else { Self.send(c, 409, ["error": err]) }
                }
            case ("POST", "/record/stop"):
                v.apiStop { path, dur, err in
                    if let path { Self.send(c, 200, ["path": path, "duration": dur] as [String: Any]) } else { Self.send(c, 409, ["error": err]) }
                }
            case ("POST", "/fullscreen"):
                _ = v.apiFullscreen((req.body["on"] as? Bool) ?? true); Self.send(c, 200, v.apiStatus())
            case ("POST", "/snap"):
                _ = v.apiSnap((req.body["on"] as? Bool) ?? true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Self.send(c, 200, v.apiStatus()) }
            case ("POST", "/front"): v.apiFront(); Self.send(c, 200, ["ok": true])
            // v23: the sound input, and the Sony (status with the staged check, connect, REC, any setting)
            case ("GET", "/sounds"): Self.send(c, 200, ["sounds": v.apiSounds()])
            // v30: the A/V sync values (Sync.swift): per sound input, the camera's picture delay, the scratch track
            case ("GET", "/sync"): Self.send(c, 200, v.apiSync())
            case ("POST", "/sync"):
                let r = v.apiSetSync(req.body)
                if r.ok { Self.send(c, 200, v.apiSync()) } else { Self.send(c, 409, ["error": r.error]) }
            // v31: the gain of the chosen sound input (Gain.swift): value, AUTO GAIN, UNDO, the take's audio format
            case ("GET", "/gain"): Self.send(c, 200, v.apiGain())
            case ("POST", "/gain"):
                let r = v.apiSetGain(req.body)
                if r.ok { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Self.send(c, 200, v.apiGain()) } } else { Self.send(c, 409, ["error": r.error]) }
            // v32: VCAM, the picture into the OBS Virtual Camera (VirtualCam.swift)
            case ("GET", "/virtualcam/status"), ("GET", "/virtualcam"): Self.send(c, 200, v.apiVirtualCam())
            case ("POST", "/virtualcam"):
                v.apiSetVirtualCam(req.body) { err in
                    if let err { Self.send(c, 409, ["error": err]); return }
                    // a start: answer once frames went out (or the reason they cannot)
                    DispatchQueue.main.asyncAfter(deadline: .now() + ((req.body["on"] as? Bool) == true ? 1.0 : 0.3)) { Self.send(c, 200, v.apiVirtualCam()) }
                }
            case ("POST", "/sound"):
                let r = v.apiSetSound(name: req.body["name"] as? String, id: req.body["id"] as? String, none: (req.body["none"] as? Bool) ?? false)
                if r.ok { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Self.send(c, 200, v.apiStatus()) } } else { Self.send(c, 409, ["error": r.error]) }
            case ("GET", "/sony/status"):
                if req.query.contains("check=1") { v.sony.check { Self.send(c, 200, v.sony.apiStatus()) } }
                else { Self.send(c, 200, v.sony.apiStatus()) }
            case ("POST", "/sony/check"): v.sony.check { Self.send(c, 200, v.sony.apiStatus()) }
            case ("POST", "/sony/connect"):
                v.sony.findAndConnect()
                Self.later(c, v, seconds: (req.body["wait"] as? NSNumber)?.doubleValue ?? 15)
            case ("POST", "/sony/disconnect"): v.sony.disconnect(); Self.later(c, v, seconds: 1)
            case ("POST", "/sony/takecontrol"):
                // the same as Marko's TAKE CONTROL key: closes Imaging Edge Remote; only on an explicit request
                v.sony.takeControl(); Self.later(c, v, seconds: (req.body["wait"] as? NSNumber)?.doubleValue ?? 20)
            case ("POST", "/sony/rec"):
                guard v.sony.connected else { Self.send(c, 409, ["error": "the Sony is not connected"]); return }
                let on = (req.body["on"] as? Bool) ?? !v.sony.recording
                if on != v.sony.recording { v.sony.toggleRec() }
                // answered when the camera's own REC state (0xD21D, read back) shows it, at most 8 s
                let end = Date().addingTimeInterval(8)
                func wait() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        if v.sony.recording == on || Date() > end || !v.sony.connected { Self.send(c, 200, v.sony.apiStatus()) } else { wait() }
                    }
                }
                wait()
            case ("GET", "/sony/prop"):
                let key = req.query.components(separatedBy: "&").first { $0.hasPrefix("code=") }.map { String($0.dropFirst(5)) } ?? ""
                if let code = v.sony.code(for: key.removingPercentEncoding ?? key), let p = v.sony.apiProp(code) { Self.send(c, 200, p) }
                else { Self.send(c, 404, ["error": "no such setting reported by the camera"]) }
            case ("POST", "/sony/set"):
                let key = (req.body["code"] as? String) ?? (req.body["name"] as? String) ?? ""
                v.sony.apiSet(key: key, value: (req.body["value"] as? NSNumber)?.uint64Value, label: req.body["label"] as? String) { ok, text in
                    Self.send(c, ok ? 200 : 409, ["ok": ok, "result": text, "status": v.sony.apiStatus()])
                }
            default: Self.send(c, 404, ["error": "unknown endpoint", "endpoints": ["GET /status", "GET /cameras", "GET /capture", "POST /camera", "POST /capture", "POST /quality", "POST /record/start", "POST /record/stop", "POST /front", "POST /fullscreen", "POST /snap", "GET /sounds", "POST /sound", "GET /virtualcam/status", "POST /virtualcam {on, extraDelayMs, maxHoldMs, trimMs, stamp}", "GET /sync", "GET /gain", "POST /gain {db|delta|reset|auto|undo|stop|clear|format|panel, uid?}", "POST /sync {ms|delta|reset, uid|name?} {video:{uid?,ms}} {scratch}", "GET /sony/status[?check=1]", "POST /sony/check", "POST /sony/connect", "POST /sony/disconnect", "POST /sony/takecontrol", "POST /sony/rec {on}", "GET /sony/prop?code=", "POST /sony/set {code|name, value|label}"]])
            }
        }
    }

    /// answer with the Sony status once it settled: when connected or no longer searching/connecting, or after `seconds`
    private static func later(_ c: NWConnection, _ v: Viewer, seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        func tick() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let p = v.sony.phase
                let settled = v.sony.connected ? v.sony.busy == nil : ![SonyLink.Phase.searching, .connecting].contains(p)
                if (settled && Date().timeIntervalSince(end.addingTimeInterval(-seconds)) > 1.5) || Date() > end { send(c, 200, v.sony.apiStatus()) } else { tick() }
            }
        }
        tick()
    }

    private static func send(_ c: NWConnection, _ code: Int, _ obj: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        let text = code == 200 ? "OK" : code == 404 ? "Not Found" : code == 409 ? "Conflict" : "Error"
        var out = Data("HTTP/1.1 \(code) \(text)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}
