import Foundation
import Network

// v6, Marko 13.11.2026 (MPA_LESSONS_ANALYZER request "Beatrice guides the shooting"): "Beatrice needs to guide me ... I say
// yes, and then it opens up the Sony webcam, and it records. I press stop". A tiny HTTP API on 127.0.0.1:8867 (loopback
// only) so the MPA Lessons Analyzer and Queen can drive the app. Every handler runs on the main queue and calls the same
// Viewer functions the window and the record key call. Port written to ~/.mantra/ports/webcam-recorder.
//   GET /status   GET /cameras   POST /camera {"name"|"id","slice"}   POST /record/start {"name"?}   POST /record/stop   POST /front
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

    struct Request { let method: String; let path: String; let body: [String: Any] }

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
        let path = String(first[1]).components(separatedBy: "?")[0]
        return Request(method: String(first[0]).uppercased(), path: path, body: obj)
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
            case ("POST", "/front"): v.apiFront(); Self.send(c, 200, ["ok": true])
            default: Self.send(c, 404, ["error": "unknown endpoint", "endpoints": ["GET /status", "GET /cameras", "POST /camera", "POST /record/start", "POST /record/stop", "POST /front"]])
            }
        }
    }

    private static func send(_ c: NWConnection, _ code: Int, _ obj: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        let text = code == 200 ? "OK" : code == 404 ? "Not Found" : code == 409 ? "Conflict" : "Error"
        var out = Data("HTTP/1.1 \(code) \(text)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}
