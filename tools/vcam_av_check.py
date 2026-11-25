#!/usr/bin/env python3
"""vcam_av_check.py: picture and sound of the live chain as a Zoom-like reader gets them (Webcam Recorder (Mantra) v34).

Opens ONLY the two virtual devices, "OBS Virtual Camera" (video, BGRA) and "Mantra VirtualCam" (sound), with AVFoundation,
the way Zoom does, for a fixed time with a hard deadline (never an open-ended reader), and measures how far the sound of
an event is from its picture.

  python3 tools/vcam_av_check.py flash  [--seconds 20] [--compare]   # no hands, no speaker: VCAM flashes, VMIC clicks
  python3 tools/vcam_av_check.py adam   [--runs 3]                    # the ADAM plays chirps: raw mic vs Mantra VirtualCam

flash: POST /virtualmic {"flash": true} makes VCAM draw a white frame (with its time stamp) for the first camera frame at
or after every whole second of the host clock, and VMIC write a 3 ms 2 kHz click at the matching moment of the mic's
clock (the same second moved by the mic's SYNC value). A reader of both devices then sees, per second: the white frame
(its buffer time = when VCAM enqueued it) and the click (its sample time = when the driver hands it out). The camera
samples only at its frame times, so the flash frame's own capture stamp minus the whole second is taken off the picture
side (that part is physics, not the chain). offset = picture - sound, ms: > 0 = the picture is later than the sound.
--compare runs it twice: with the composite (as Marko gets it) and without it (POST /virtualmic {"composite": false},
both holds 0: the chain without the composite delay), then puts everything back.

adam: plays avsync.py's chirp train through the ADAM (test signals only, the default output and volume are never
changed and are compared before/after), records the app's chosen sound input and "Mantra VirtualCam" at the same time,
and finds every chirp in both: delay(Mantra VirtualCam) - delay(raw mic) should be the app's soundDelayMs.

Safety: refuses while the app records, while a Zoom meeting runs (CptHost) or while something else reads the Mantra
VirtualCam mic (driver micClients); every test switch is put back; it prints JSON.
"""
import argparse, json, os, signal, subprocess, sys, threading, time, urllib.request

import numpy as np

API = "http://127.0.0.1:8867"
CAM = "OBS Virtual Camera"
MIC = "Mantra VirtualCam"


def api(path, body=None, timeout=5):
    req = urllib.request.Request(API + path, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json"}, method="POST" if body is not None else "GET")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def busy():
    """why a test must not run now (None = free)"""
    st = api("/status")
    if st.get("recording"):
        return "the app is recording"
    if subprocess.run(["pgrep", "-x", "CptHost"], capture_output=True).returncode == 0:
        return "a Zoom meeting runs (CptHost)"
    vm = api("/virtualmic/status")
    mc = (vm.get("driver") or {}).get("micClients", 0)
    if mc and mc > 0:
        return f"another program reads the Mantra VirtualCam mic (micClients {mc})"
    return None


def host_now():
    import CoreMedia
    t = CoreMedia.CMClockGetTime(CoreMedia.CMClockGetHostTimeClock())
    return t.value / t.timescale


# ------------------------------------------------------------------ the reader (one session per device, host clock)
class Reader:
    def __init__(self, video=True, audio_names=(MIC,)):
        import objc, AVFoundation as AV, CoreMedia as CM, Quartz
        from Foundation import NSObject
        from libdispatch import dispatch_queue_create
        self.CM = CM
        outer = self

        class VGrab(NSObject):
            def init(self):
                self = objc.super(VGrab, self).init()
                self.rows = []
                return self

            def captureOutput_didOutputSampleBuffer_fromConnection_(self, out, sb, conn):
                now = host_now()
                p = CM.CMSampleBufferGetPresentationTimeStamp(sb)
                pb = CM.CMSampleBufferGetImageBuffer(sb)
                Quartz.CVPixelBufferLockBaseAddress(pb, 1)
                try:
                    w, h = Quartz.CVPixelBufferGetWidth(pb), Quartz.CVPixelBufferGetHeight(pb)
                    bpr = Quartz.CVPixelBufferGetBytesPerRow(pb)
                    a = np.frombuffer(Quartz.CVPixelBufferGetBaseAddress(pb).as_buffer(bpr * h), dtype=np.uint8)
                    a = a.reshape(h, bpr)[:, : w * 4].reshape(h, w, 4)
                    g = a[12, 12::24, 1][:42].astype(int)
                    stamp = None
                    if len(g) == 42 and g[0] - g[1] > 120:
                        thr = (int(g[0]) + int(g[1])) / 2
                        v = 0
                        for b in g[2:42]:
                            v = (v << 1) | (1 if b > thr else 0)
                        stamp = v / 1e6
                    lum = float(a[60:h:53, 7:w:61, 1].mean())     # below the stamp bar
                finally:
                    Quartz.CVPixelBufferUnlockBaseAddress(pb, 1)
                self.rows.append((p.value / p.timescale, now, stamp, lum))

        class AGrab(NSObject):
            def init(self):
                self = objc.super(AGrab, self).init()
                self.chunks = []; self.fmt = None
                return self

            def captureOutput_didOutputSampleBuffer_fromConnection_(self, out, sb, conn):
                pts = CM.CMSampleBufferGetPresentationTimeStamp(sb)
                bb = CM.CMSampleBufferGetDataBuffer(sb)
                if bb is None:
                    return
                err, data = CM.CMBlockBufferCopyDataBytes(bb, 0, CM.CMBlockBufferGetDataLength(bb), None)
                if self.fmt is None:
                    self.fmt = CM.CMAudioFormatDescriptionGetStreamBasicDescription(CM.CMSampleBufferGetFormatDescription(sb))
                self.chunks.append((pts.value / pts.timescale, CM.CMSampleBufferGetNumSamples(sb), bytes(data)))

        self.sessions, self._keep, self.agrabs = [], [], {}
        self.vgrab = None
        if video:
            devs = [d for d in AV.AVCaptureDevice.devicesWithMediaType_(AV.AVMediaTypeVideo) if d.localizedName() == CAM]
            if not devs:
                raise SystemExit(json.dumps({"ok": False, "error": CAM + " not found"}))
            s = AV.AVCaptureSession.alloc().init()
            inp, err = AV.AVCaptureDeviceInput.deviceInputWithDevice_error_(devs[0], None)
            s.addInput_(inp)
            o = AV.AVCaptureVideoDataOutput.alloc().init()
            o.setVideoSettings_({Quartz.kCVPixelBufferPixelFormatTypeKey: Quartz.kCVPixelFormatType_32BGRA})
            o.setAlwaysDiscardsLateVideoFrames_(False)
            self.vgrab = VGrab.alloc().init()
            q = dispatch_queue_create(b"vcam_av_check.v", None)
            o.setSampleBufferDelegate_queue_(self.vgrab, q); s.addOutput_(o)
            self.sessions.append(s); self._keep += [inp, o, q]
        auds = {d.localizedName(): d for d in AV.AVCaptureDevice.devicesWithMediaType_(AV.AVMediaTypeAudio)}
        for n in audio_names:
            if n not in auds:
                raise SystemExit(json.dumps({"ok": False, "error": f"sound input '{n}' not found"}))
            s = AV.AVCaptureSession.alloc().init()
            inp, err = AV.AVCaptureDeviceInput.deviceInputWithDevice_error_(auds[n], None)
            s.addInput_(inp)
            o = AV.AVCaptureAudioDataOutput.alloc().init(); g = AGrab.alloc().init()
            q = dispatch_queue_create(f"vcam_av_check.{n}".encode(), None)
            o.setSampleBufferDelegate_queue_(g, q); s.addOutput_(o)
            self.agrabs[n] = g; self.sessions.append(s); self._keep += [inp, o, q]

    def start(self):
        for s in self.sessions:
            s.startRunning()

    def stop(self):
        for s in self.sessions:
            s.stopRunning()

    def audio(self, name):
        """the whole recording as one array placed by the buffers' own stamps; (x, rate, t0)"""
        g = self.agrabs[name]; f = g.fmt
        if f is None:
            raise RuntimeError(f"no sound from {name}")
        rate, ch, bits, flags = f.mSampleRate, max(1, f.mChannelsPerFrame), f.mBitsPerChannel, f.mFormatFlags
        planar = bool(flags & 32); bps = bits // 8
        chunks = list(g.chunks)
        p0 = chunks[0][0]; last = chunks[-1]
        x = np.zeros(int(round((last[0] - p0) * rate)) + last[1] + 1)
        for pts, n, data in chunks:
            b = np.frombuffer(data, dtype=np.uint8)
            if planar:
                b = b[: n * bps]
            if flags & 1:
                v = b.view("<f4") if bps == 4 else b.view("<f8")
            elif bps == 2:
                v = b.view("<i2") / 32768.0
            elif bps == 4:
                v = b.view("<i4") / 2147483648.0
            else:
                t = b[: (len(b) // 3) * 3].reshape(-1, 3).astype(np.int32)
                v = ((t[:, 0] | (t[:, 1] << 8) | (t[:, 2] << 16)) << 8 >> 8) / 8388608.0
            if not planar:
                v = v[::ch]
            v = np.asarray(v[:n], dtype=np.float64)
            i = int(round((pts - p0) * rate)); x[i:i + len(v)] = v
        return x, rate, p0


# ------------------------------------------------------------------ flash: white frame vs click
def click_template(rate):
    t = np.arange(int(rate * 0.003)) / rate
    return 0.7 * np.sin(2 * np.pi * 2000 * t)


def find_clicks(x, rate, t0):
    """exact onsets of VMIC's test clicks: the normalised match of the known 3 ms waveform, one per second at most"""
    tpl = click_template(rate); L = len(tpl)
    if len(x) < L * 4:
        return []
    c = np.correlate(x, tpl, mode="valid")
    e = np.sqrt(np.convolve(x * x, np.ones(L), mode="valid")) * np.sqrt((tpl * tpl).sum()) + 1e-12
    score = c / e
    out, last = [], -10**12
    for i in np.flatnonzero(score > 0.95):
        if i - last < rate * 0.5:
            continue
        j = i + int(np.argmax(score[i:i + L]))
        out.append(t0 + j / rate); last = j
    return out


def find_flashes(rows):
    """first white buffer of each flash: (buffer PTS, arrival, the flash frame's own capture stamp)"""
    out, prev = [], 0.0
    for pts, arr, stamp, lum in rows:
        if lum > 200 and prev < 150 and stamp:
            out.append((pts, arr, stamp))
        prev = lum
    return out


def pair(flashes, clicks):
    res = []
    for pts, arr, stamp in flashes:
        k = np.floor(stamp)                 # the whole second this flash stands for
        lateness = stamp - k                # the camera's frame came this long after the second (not the chain)
        if not clicks:
            break
        # the click of the same second: the nearest one (holds are far below 0.5 s)
        cs = min(clicks, key=lambda c: abs((pts - lateness) - c))
        d = (pts - lateness) - cs
        if abs(d) < 0.45:
            res.append({"second": int(k) % 100000, "offsetMs": round(d * 1000, 2),
                        "offsetArrivalMs": round(((arr - lateness) - cs) * 1000, 2), "frameLateMs": round(lateness * 1000, 2)})
    return res


def stats(v):
    if not v:
        return None
    a = np.array(v)
    return {"n": len(v), "median": round(float(np.median(a)), 2), "min": round(float(a.min()), 2), "max": round(float(a.max()), 2),
            "maxAbs": round(float(np.abs(a).max()), 2), "spread": round(float(a.max() - a.min()), 2)}


def flash_run(seconds):
    rd = Reader(video=True, audio_names=(MIC,))
    rd.start()
    time.sleep(1.5)                        # the first buffers of a new reader are thrown away
    rd.vgrab.rows = []; rd.agrabs[MIC].chunks = []
    time.sleep(seconds)
    rd.stop()
    x, rate, t0 = rd.audio(MIC)
    clicks = find_clicks(x, rate, t0)
    flashes = find_flashes(list(rd.vgrab.rows))
    pairs = pair(flashes, clicks)
    vm = api("/virtualmic/status"); vc = api("/virtualcam/status")
    comp = vm.get("composite", {})
    return {"flashes": len(flashes), "clicks": len(clicks), "pairs": pairs,
            "offsetMs": stats([p["offsetMs"] for p in pairs]),
            "offsetArrivalMs": stats([p["offsetArrivalMs"] for p in pairs]),
            "app": {"soundDelayMs": comp.get("soundDelayMs"), "audioHoldMs": comp.get("audioHoldMs"),
                    "videoHoldMs": comp.get("videoHoldMs"), "VpathMs": comp.get("VpathMs"), "AMs": comp.get("AMs"),
                    "VMs": comp.get("VMs"), "LappMs": comp.get("LappMs"), "trimMs": comp.get("trimMs"),
                    "bypassed": comp.get("bypassed"),
                    "underruns": vm.get("underruns"), "drift": vm.get("drift"), "jumps": vm.get("jumps"),
                    "vcamLatencyMs": vc.get("latencyMs"), "vcamFps": vc.get("fps"), "mic": comp.get("mic")},
            "frames": len(rd.vgrab.rows)}


def cmd_flash(a):
    why = busy()
    if why:
        print(json.dumps({"ok": False, "refused": why})); return 4
    vm = api("/virtualmic/status"); vc = api("/virtualcam/status")
    if not vc.get("feeding") or vm.get("state") != "feeding":
        print(json.dumps({"ok": False, "error": "VCAM and VMIC must both be feeding", "vcam": vc.get("feeding"), "vmic": vm.get("state")})); return 2
    out = {"ok": True, "seconds": a.seconds, "sign": "offset = picture - sound (ms); > 0 = the picture is later than the sound"}
    try:
        api("/virtualmic", {"flash": True}); time.sleep(1.0)
        if a.compare:
            api("/virtualmic", {"composite": False}); time.sleep(1.5)
            out["withoutComposite"] = flash_run(a.seconds)
            api("/virtualmic", {"composite": True}); time.sleep(1.5)
        out["withComposite"] = flash_run(a.seconds)
    finally:
        api("/virtualmic", {"flash": False, "composite": True})
    print(json.dumps(out, indent=1))
    return 0


# ------------------------------------------------------------------ adam: chirps through the raw mic and through VMIC
def cmd_adam(a):
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, here)
    import avsync
    why = busy()
    if why:
        print(json.dumps({"ok": False, "refused": why})); return 4
    vm = api("/virtualmic/status")
    raw = vm.get("soundInput")
    if not raw or vm.get("state") != "feeding":
        print(json.dumps({"ok": False, "error": "VMIC must feed from a chosen sound input", "state": vm.get("state")})); return 2
    before = avsync.audio_state()
    outs = avsync.at_outputs()
    out_name = avsync.find(list(outs), avsync.OUT_DEFAULT)
    sig = os.path.join(os.environ.get("TMPDIR", "/tmp"), "vcam_av_check_chirps.wav")
    dur = avsync.write_signal(sig, a.level)
    rd = Reader(video=False, audio_names=(raw, MIC))
    rd.start(); time.sleep(1.5)
    results = []
    try:
        for run in range(a.runs):
            for g in rd.agrabs.values():
                g.chunks = []
            t_play = host_now()
            subprocess.run([avsync.FFMPEG, "-nostdin", "-hide_banner", "-loglevel", "error", "-re", "-i", sig,
                            "-f", "audiotoolbox", "-audio_device_index", str(outs[out_name]), "-"], timeout=dur + 10)
            time.sleep(0.6)
            xr, rr, tr = rd.audio(raw); xm, rm, tm = rd.audio(MIC)
            c = avsync.chirp(rr); starts = avsync.chirp_starts()
            def onsets(x, rate, t0):
                cc = np.correlate(x, avsync.chirp(rate), mode="valid")
                env = np.abs(cc); thr = env.max() * 0.5; res, i = [], 0
                while i < len(env):
                    if env[i] > thr:
                        j = i + int(np.argmax(env[i:i + int(rate * 0.1)])); res.append(t0 + j / rate); i = j + int(rate * 0.3)
                    else:
                        i += 1
                return res
            orr, om = onsets(xr, rr, tr), onsets(xm, rm, tm)
            d = []
            for t in orr:
                m = [u for u in om if 0 <= u - t < 0.6]
                if m:
                    d.append((m[0] - t) * 1000)
            results.append({"run": run + 1, "chirpsRaw": len(orr), "chirpsVmic": len(om), "delayMs": stats(d),
                            "rawLevelDb": round(float(20 * np.log10(np.sqrt(np.mean(xr ** 2)) + 1e-12)), 1)})
    finally:
        rd.stop()
        ok, b, f = avsync.restore(before)
        try:
            os.remove(sig)
        except OSError:
            pass
    vm = api("/virtualmic/status")
    print(json.dumps({"ok": True, "rawInput": raw, "expectedMs": vm.get("soundDelayMs"), "runs": results,
                      "restoredAudioState": ok, "note": "delayMs = Mantra VirtualCam minus the raw input, per chirp"}, indent=1))
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("flash"); f.add_argument("--seconds", type=float, default=20); f.add_argument("--compare", action="store_true")
    d = sub.add_parser("adam"); d.add_argument("--runs", type=int, default=3); d.add_argument("--level", type=float, default=-24)
    a = ap.parse_args()
    budget = (a.seconds * 2 + 30) if a.cmd == "flash" else (a.runs * 15 + 30)
    signal.signal(signal.SIGALRM, lambda *_: (print(json.dumps({"ok": False, "error": "deadline: killed"})), os._exit(3)))
    signal.alarm(int(budget))
    return cmd_flash(a) if a.cmd == "flash" else cmd_adam(a)


if __name__ == "__main__":
    sys.exit(main())
