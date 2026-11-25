#!/usr/bin/env python3
"""avsync.py: how late is every sound input against the camera's own sound (Webcam Recorder (Mantra), 25.11.2026).

The Sony a7 V's sound comes embedded in the HDMI ("UGREEN 15389" sound input) and travels with the picture: that is
the REFERENCE (scratch track). Every other input (RØDE NT1, External Microphone, MacBook Pro Microphone, ...) has its
own latency. This tool plays a known chirp train from a speaker, records the reference and the other inputs at the same
time (one ffmpeg avfoundation process per device, all on the host clock: AVCaptureAudioDataOutput presentation time
stamps, the same stamps the app uses), finds every chirp in every recording by GCC-PHAT with sub-sample interpolation,
and reports per device: delay against the reference (ms, median and spread over all chirps of all runs), the device's
clock rate against the host clock (ppm), and what Core Audio itself reports as latency.

    python3 tools/avsync.py list
    python3 tools/avsync.py measure                    # every real input against "UGREEN 15389", 5 runs, ADAM speaker
    python3 tools/avsync.py measure --dev "RØDE NT1 5th Gen" --runs 8 --level -30 --loopback --save
    python3 tools/avsync.py measure --distance "UGREEN 15389=2.4" --distance "RØDE NT1 5th Gen=0.6"
    python3 tools/avsync.py show

Sign: delay_ms > 0 means the device hears the event LATER (on the host clock) than the camera sound; the app must
then move that device's sound EARLIER by delay_ms (audio pts - delay_ms) to sit on the picture.
--distance NAME=metres (speaker to that microphone) removes the travel time of sound (2.915 ms per metre at 343 m/s)
so only the electronic latency is left. --loopback also plays the chirps into BlackHole 2ch from the same ffmpeg
process and records BlackHole: an electrical "emission" reference (absolute latency incl. the speaker's own).

Safety: refuses while the app's /status says recording; never changes the default devices or volumes (plays to the
chosen output device directly); reads them before and after and restores them if anything changed; stops every
process it started. Results go to ~/Library/Application Support/Webcam Recorder (Mantra)/avsync.json (--save), never
into the repository. Needs ffmpeg/ffprobe (the app's own: /opt/homebrew/bin) and numpy.
"""
import argparse, ctypes, datetime, json, os, re, signal, subprocess, sys, tempfile, time, urllib.request
import numpy as np

FFMPEG = next((p for p in ("/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg") if os.access(p, os.X_OK)), "ffmpeg")
FFPROBE = FFMPEG.replace("ffmpeg", "ffprobe")
STORE = os.path.expanduser("~/Library/Application Support/Webcam Recorder (Mantra)/avsync.json")
API = "http://127.0.0.1:8867/status"
REF_DEFAULT = "UGREEN 15389"
OUT_DEFAULT = "ADAM Audio D3V"
LOOP = "BlackHole 2ch"
SKIP_INPUTS = ("ZoomAudioDevice", "NDI Audio", "Iriun Webcam Audio", "BlackHole 2ch")   # virtual: no microphone
SPEED_OF_SOUND = 343.0
SR = 48000

# ---------------------------------------------------------------- Core Audio (ctypes, read only)
class _Addr(ctypes.Structure):
    _fields_ = [("sel", ctypes.c_uint32), ("scope", ctypes.c_uint32), ("elem", ctypes.c_uint32)]

def _fc(s): return int.from_bytes(s.encode(), "big")

def coreaudio_devices():
    """name -> {uid, rate, input/output reported latency frames (device + safety + stream)} for every device."""
    try:
        ca = ctypes.CDLL("/System/Library/Frameworks/CoreAudio.framework/CoreAudio")
        cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    except OSError:
        return {}
    ca.AudioObjectGetPropertyDataSize.argtypes = [ctypes.c_uint32, ctypes.POINTER(_Addr), ctypes.c_uint32, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    ca.AudioObjectGetPropertyData.argtypes = [ctypes.c_uint32, ctypes.POINTER(_Addr), ctypes.c_uint32, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p]
    cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
    cf.CFRelease.argtypes = [ctypes.c_void_p]

    def get(obj, sel, scope="glob", ctype=ctypes.c_uint32):
        a = _Addr(_fc(sel), _fc(scope), 0); n = ctypes.c_uint32(0)
        if ca.AudioObjectGetPropertyDataSize(obj, ctypes.byref(a), 0, None, ctypes.byref(n)): return None
        k = n.value // ctypes.sizeof(ctype)
        buf = (ctype * max(1, k))()
        if ca.AudioObjectGetPropertyData(obj, ctypes.byref(a), 0, None, ctypes.byref(n), buf): return None
        return list(buf)[:k]

    def cfstr(obj, sel):
        v = get(obj, sel, ctype=ctypes.c_void_p)
        if not v or not v[0]: return None
        b = ctypes.create_string_buffer(1024); cf.CFStringGetCString(v[0], b, 1024, 0x08000100); cf.CFRelease(v[0])
        return b.value.decode()

    out = {}
    for d in get(1, "dev#") or []:
        name = (cfstr(d, "lnam") or "").strip()
        info = {"uid": cfstr(d, "uid "), "rate": (get(d, "nsrt", ctype=ctypes.c_double) or [0])[0]}
        for scope, key in (("inpt", "input"), ("outp", "output")):
            streams = get(d, "stm#", scope)
            if not streams: continue
            lat = (get(d, "ltnc", scope) or [0])[0]; safe = (get(d, "saft", scope) or [0])[0]
            slat = max([(get(s, "ltnc") or [0])[0] for s in streams])
            info[key] = {"device": lat, "safety": safe, "stream": slat, "buffer": (get(d, "fsiz", scope) or [0])[0]}
        out.setdefault(name, info)
    return out

# ---------------------------------------------------------------- device lists through ffmpeg
def avf_audio_inputs():
    r = subprocess.run([FFMPEG, "-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", ""],
                       capture_output=True, text=True)
    lines, on = {}, False
    for ln in r.stderr.splitlines():
        if "audio devices" in ln: on = True; continue
        m = re.search(r"\] \[(\d+)\] (.+)$", ln)
        if on and m: lines[m.group(2).strip()] = int(m.group(1))
    return lines

def at_outputs():
    r = subprocess.run([FFMPEG, "-hide_banner", "-f", "lavfi", "-i", "anullsrc", "-t", "0.01", "-f", "audiotoolbox",
                        "-list_devices", "true", "-"], capture_output=True, text=True)
    out = {}
    for ln in r.stderr.splitlines():
        m = re.search(r"\] \[(\d+)\]\s+(.+?), (.+)$", ln)
        if m and m.group(2) != "(null)": out[m.group(2).strip()] = int(m.group(1))
    return out

def find(names, wanted):
    if wanted in names: return wanted
    hits = [n for n in names if wanted.lower() in n.lower()]
    if len(hits) == 1: return hits[0]
    sys.exit(f"device '{wanted}' not found (or ambiguous) among: {', '.join(names)}")

# ---------------------------------------------------------------- state we must leave as found
def audio_state():
    def sh(cmd):
        try: return subprocess.run(cmd, capture_output=True, text=True, timeout=5).stdout.strip()
        except Exception: return None
    return {"output": sh(["SwitchAudioSource", "-c", "-t", "output"]), "input": sh(["SwitchAudioSource", "-c", "-t", "input"]),
            "system": sh(["SwitchAudioSource", "-c", "-t", "system"]), "volume": sh(["osascript", "-e", "get volume settings"])}

def restore(before):
    after = audio_state()
    for t in ("output", "input", "system"):
        if before[t] and after[t] != before[t]:
            subprocess.run(["SwitchAudioSource", "-t", t, "-s", before[t]], capture_output=True)
    if before["volume"] and after["volume"] != before["volume"]:
        m = re.search(r"output volume:(\d+).*output muted:(\w+)", before["volume"])
        if m:
            subprocess.run(["osascript", "-e", f"set volume output volume {m.group(1)}"])
            if m.group(2) == "true": subprocess.run(["osascript", "-e", "set volume with output muted"])
    final = audio_state()
    return final == before, before, final

def app_recording():
    try:
        with urllib.request.urlopen(API, timeout=2) as r: return bool(json.load(r).get("recording"))
    except Exception:
        return None   # app not running: nothing to interrupt

# ---------------------------------------------------------------- the test signal
def chirp(sr, f0=300.0, f1=8000.0, dur=0.08):
    t = np.arange(int(sr * dur)) / sr
    x = np.sin(2 * np.pi * (f0 * t + (f1 - f0) / (2 * dur) * t * t))
    n = int(sr * 0.005); w = np.ones_like(x); r = 0.5 - 0.5 * np.cos(np.pi * np.arange(n) / n)
    w[:n] = r; w[-n:] = r[::-1]
    return x * w

GAPS = [0.55, 0.70, 0.60, 0.80, 0.65, 0.75, 0.58]          # irregular, so no chirp can be mistaken for its neighbour
LEAD = 0.6

def chirp_starts():
    return LEAD + np.concatenate([[0.0], np.cumsum(GAPS)])

def write_signal(path, level_db):
    starts = chirp_starts(); c = chirp(SR)
    total = int(SR * (starts[-1] + 0.08 + 0.6))
    x = np.zeros(total)
    for s in starts:
        i = int(round(s * SR)); x[i:i + len(c)] += c
    x *= 10 ** (level_db / 20)
    st = np.repeat(x[:, None], 2, axis=1).astype("<f4")
    subprocess.run([FFMPEG, "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-f", "f32le", "-ar", str(SR), "-ac", "2",
                    "-i", "pipe:0", "-c:a", "pcm_f32le", path], input=st.tobytes(), check=True)
    return total / SR

# ---------------------------------------------------------------- capture: AVFoundation itself, as the app does
# ffmpeg's avfoundation input is NOT used for capture: it keeps one audio buffer at a time and dropped about 20 % of the
# UGREEN packets when several devices ran at once, and it refuses 24-bit packed sound (the RØDE NT1). PyObjC drives the
# same AVCaptureSession + AVCaptureAudioDataOutput (native format, no audioSettings) the app uses, so the presentation
# time stamps measured here are the ones Recorder.swift aligns with.
class Capture:
    def __init__(self, names):
        import objc, AVFoundation as AV, CoreMedia as CM, dispatch
        from Foundation import NSObject
        self.CM = CM
        devices = {d.localizedName(): d for d in AV.AVCaptureDevice.devicesWithMediaType_(AV.AVMediaTypeAudio)}

        class Grab(NSObject):
            def init(self):
                self = objc.super(Grab, self).init()
                if self is None: return None
                self.chunks = []; self.fmt = None; self.drops = 0; self.arrivals = []
                return self
            def captureOutput_didOutputSampleBuffer_fromConnection_(self, out, sb, conn):
                pts = CM.CMSampleBufferGetPresentationTimeStamp(sb)
                bb = CM.CMSampleBufferGetDataBuffer(sb)
                if bb is None: return
                err, data = CM.CMBlockBufferCopyDataBytes(bb, 0, CM.CMBlockBufferGetDataLength(bb), None)
                if self.fmt is None:
                    self.fmt = CM.CMAudioFormatDescriptionGetStreamBasicDescription(CM.CMSampleBufferGetFormatDescription(sb))
                self.chunks.append((pts.value / pts.timescale, CM.CMSampleBufferGetNumSamples(sb), bytes(data)))
                now = CM.CMClockGetTime(CM.CMClockGetHostTimeClock())
                self.arrivals.append((now.value / now.timescale, pts.value / pts.timescale))
            def captureOutput_didDropSampleBuffer_fromConnection_(self, out, sb, conn):
                self.drops += 1

        self.grabs, self.sessions, self._keep = {}, [], []
        for n in names:
            if n not in devices: raise SystemExit(f"'{n}' is not an AVFoundation sound input")
            s = AV.AVCaptureSession.alloc().init()
            inp, err = AV.AVCaptureDeviceInput.deviceInputWithDevice_error_(devices[n], None)
            if inp is None: raise SystemExit(f"cannot open '{n}': {err}")
            s.addInput_(inp)
            o = AV.AVCaptureAudioDataOutput.alloc().init(); g = Grab.alloc().init()
            q = dispatch.dispatch_queue_create(f"avsync.{n}".encode(), None)
            o.setSampleBufferDelegate_queue_(g, q); s.addOutput_(o)
            self.grabs[n] = g; self.sessions.append(s); self._keep += [inp, o, q]
            s.startRunning()

    def now(self):
        t = self.CM.CMClockGetTime(self.CM.CMClockGetHostTimeClock()); return t.value / t.timescale

    def stop(self):
        for s in self.sessions: s.stopRunning()

    def clock_ppm(self, name):
        """how fast this input's time stamps run against the host clock, from the arrival time of every buffer over the
        whole session (pts made by counting samples drift with the device's own crystal; arrival time does not).
        Positive = the stamps fall behind real time (the device clock runs slow)."""
        a = list(self.grabs[name].arrivals)
        if len(a) < 200 or a[-1][1] - a[0][1] < 20: return None
        arr, pts = np.array([x[0] for x in a]), np.array([x[1] for x in a])
        lag = arr - pts                               # buffer delivery lag; its lower envelope is the clean trend
        n = 40; edges = np.linspace(pts[0], pts[-1], n + 1); xs, ys = [], []
        for i in range(n):
            m = (pts >= edges[i]) & (pts < edges[i + 1])
            if m.any(): xs.append(pts[m].mean()); ys.append(lag[m].min())
        return float(np.polyfit(xs, ys, 1)[0] * 1e6)

    def window(self, name, t0, t1):
        """mono samples (first channel) between host times t0..t1, each buffer placed at its own pts; rate; host time of
        sample 0; drops; largest pts discontinuity seen (ms)."""
        g = self.grabs[name]; f = g.fmt
        if f is None: raise RuntimeError("no sound buffers arrived")
        rate, ch, bits, flags = f.mSampleRate, max(1, f.mChannelsPerFrame), f.mBitsPerChannel, f.mFormatFlags
        planar = bool(flags & 32); bps = bits // 8
        chunks = [c for c in list(g.chunks) if t0 <= c[0] <= t1]
        if not chunks: raise RuntimeError("no sound in the window")
        p0 = chunks[0][0]; last = chunks[-1]
        x = np.zeros(int(round((last[0] - p0) * rate)) + last[1] + 1)
        disc, prev = 0.0, None
        for pts, n, data in chunks:
            b = np.frombuffer(data, dtype=np.uint8)
            if planar: b = b[: n * bps]
            if flags & 1:
                v = b.view("<f4") if bps == 4 else b.view("<f8")
            elif bps == 2: v = b.view("<i2") / 32768.0
            elif bps == 4: v = b.view("<i4") / 2147483648.0
            elif bps == 3:
                t = b[: (len(b) // 3) * 3].reshape(-1, 3).astype(np.int32)
                v = ((t[:, 0] | (t[:, 1] << 8) | (t[:, 2] << 16)) << 8 >> 8) / 8388608.0
            else: raise RuntimeError(f"sample format {bits} bit, flags {flags}")
            if not planar: v = v[::ch]
            v = np.asarray(v[:n], dtype=np.float64)
            i = int(round((pts - p0) * rate)); x[i:i + len(v)] = v
            if prev: disc = max(disc, abs(pts - prev) * 1000)
            prev = pts + n / rate
        return {"x": x, "rate": rate, "t0": p0, "drops": g.drops, "disc_ms": disc,
                "level_db": float(20 * np.log10(np.sqrt(np.mean(x ** 2)) + 1e-12))}

def gcc_phat(sig, ref, up=16, band=None, rate=SR):
    """lag (in samples, fractional) of ref inside sig by PHAT-weighted cross-correlation, upsampled; plus peak quality
    (main peak over the largest value outside +-4 samples)."""
    n = 1 << int(np.ceil(np.log2(len(sig) + len(ref))))
    S, R = np.fft.rfft(sig, n), np.fft.rfft(ref, n)
    G = S * np.conj(R)
    G /= np.abs(G) + 1e-12
    if band:
        f = np.fft.rfftfreq(n, 1 / rate); G[(f < band[0]) | (f > band[1])] = 0
    cc = np.fft.irfft(G, n * up)
    m = (len(sig) - len(ref) + 1) * up if len(sig) > len(ref) else len(sig) * up
    cc = cc[:m]
    k = int(np.argmax(np.abs(cc)))                  # either polarity: the a7 V's own microphone arrives inverted here
    sg = 1.0 if cc[k] >= 0 else -1.0
    y0, y1, y2 = sg * cc[k - 1], sg * cc[k], sg * cc[(k + 1) % len(cc)]
    d = 0.5 * (y0 - y2) / (y0 - 2 * y1 + y2) if (y0 - 2 * y1 + y2) != 0 else 0.0
    side = np.concatenate([cc[: max(0, k - 4 * up)], cc[k + 4 * up:]])
    q = float(abs(cc[k]) / (np.max(np.abs(side)) + 1e-12)) if len(side) else 0.0
    return (k + d) / up, q * sg

def events(rec):
    """host time of every chirp onset in this recording (None where it was not found clearly), and the train's quality."""
    x, rate = rec["x"], rec["rate"]
    c = chirp(rate); starts = chirp_starts()
    full = np.zeros(int(rate * (starts[-1] + 0.2)))
    for s in starts: i = int(round(s * rate)); full[i:i + len(c)] += c
    lag0, q0 = gcc_phat(x, full, up=1, band=(300, 8000), rate=rate)
    out = []
    for s in starts:
        guess = int(lag0 + s * rate); lo = max(0, guess - int(0.03 * rate)); hi = min(len(x), guess + len(c) + int(0.03 * rate))
        if hi - lo < len(c): out.append(None); continue
        lag, q = gcc_phat(x[lo:hi], c, up=16, band=(300, 8000), rate=rate)
        pos = lo + lag
        # a chirp counts when its peak stands out (|q| > 1.05: main peak over the largest reflection/side lobe) and sits
        # within 2 ms of where the whole train put it
        out.append((rec["t0"] + pos / rate, q) if abs(q) > 1.05 and abs(pos - guess) < 0.002 * rate else None)
    return out, q0

# ---------------------------------------------------------------- one run
def run_once(cap, names, sig, dur, out_idx, loop_idx):
    t0 = cap.now()
    time.sleep(0.3)
    play = [FFMPEG, "-nostdin", "-hide_banner", "-loglevel", "error", "-re", "-i", sig,
            "-map", "0:a", "-f", "audiotoolbox", "-audio_device_index", str(out_idx), "-"]
    if loop_idx is not None:
        play += ["-map", "0:a", "-f", "audiotoolbox", "-audio_device_index", str(loop_idx), "-"]
    player = subprocess.Popen(play, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        player.wait(timeout=dur + 10)
    except subprocess.TimeoutExpired:
        player.kill(); player.wait()
    time.sleep(1.0)                                  # the slowest input's last buffers
    t1 = cap.now()
    res = {}
    for n in names:
        try:
            rec = cap.window(n, t0, t1); ev, q0 = events(rec)
            res[n] = {"rec": rec, "events": ev, "q": q0}
        except Exception as e:
            res[n] = {"error": str(e)}
    return res, (t0 + t1) / 2

def summarize(values):
    v = np.array(values)
    if len(v) == 0: return None
    med = float(np.median(v))
    return {"median_ms": round(med, 3), "spread_ms": round(float(np.percentile(v, 75) - np.percentile(v, 25)), 3),
            "min_ms": round(float(v.min()), 3), "max_ms": round(float(v.max()), 3), "n": int(len(v))}

# ---------------------------------------------------------------- commands
def cmd_list(_):
    avf, ca = avf_audio_inputs(), coreaudio_devices()
    print(f"{'#':>2}  {'input (avfoundation)':28} {'rate':>6}  reported in-latency (frames dev+safety+stream)  uid")
    for n, i in sorted(avf.items(), key=lambda t: t[1]):
        c = ca.get(n.strip(), {}); inp = c.get("input", {})
        lat = f"{inp.get('device',0)}+{inp.get('safety',0)}+{inp.get('stream',0)}" if inp else "?"
        print(f"{i:>2}  {n:28} {int(c.get('rate',0)):>6}  {lat:>30}  {c.get('uid')}")
    print("\noutputs (audiotoolbox):", ", ".join(f"[{i}] {n}" for n, i in sorted(at_outputs().items(), key=lambda t: t[1])))

def cmd_measure(a):
    rec_state = app_recording()
    if rec_state:
        sys.exit("Webcam Recorder is RECORDING: no test while a take runs.")
    avf, outs, ca = avf_audio_inputs(), at_outputs(), coreaudio_devices()
    ref = find(list(avf), a.ref)
    devs = [find(list(avf), d) for d in a.dev] if a.dev else [n for n in avf if n != ref and n not in SKIP_INPUTS]
    out_name = find(list(outs), a.out); out_idx = outs[out_name]
    loop_idx = outs.get(LOOP) if a.loopback else None
    if a.loopback and (loop_idx is None or LOOP not in avf): sys.exit("BlackHole 2ch is not present for --loopback")
    dist = {}
    for d in a.distance:
        n, m = d.rsplit("=", 1); dist[find(list(avf), n)] = float(m)
    before = audio_state()
    print(f"reference: {ref}   devices: {', '.join(devs)}   speaker: {out_name.strip()} at {a.level} dBFS   runs: {a.runs}"
          f"{'   + BlackHole loopback' if loop_idx is not None else ''}")
    print(f"left as found before: output={before['output']!r} input={before['input']!r} system={before['system']!r} [{before['volume']}]")
    per = {n: [] for n in devs + ([LOOP] if loop_idx is not None else [])}
    trend = {n: [] for n in per}                     # (host time of the run, run median) for the drift between clocks
    vs_loop = {n: [] for n in [ref] + devs} if loop_idx is not None else {}
    extra = {n: {"drops": 0, "disc": [], "level": [], "q": [], "found": 0, "chirps": 0} for n in [ref] + list(per)}
    sig = os.path.join(tempfile.mkdtemp(prefix="avsync-"), "signal.wav"); dur = write_signal(sig, a.level)
    names = [ref] + list(per)
    cap = Capture(names); clocks = {}
    try:
        time.sleep(max(1.5, a.warmup))               # every session delivering (and its stamps settled) before the first chirp
        for k in range(a.runs):
            if app_recording():
                print("a take started: stopping the measurement"); break
            res, tmid = run_once(cap, names, sig, dur, out_idx, loop_idx)
            line = []
            for n, r in res.items():
                if "error" in r: line.append(f"{n.strip()}: {r['error']}"); continue
                e = extra[n]; e["drops"] = r["rec"]["drops"]; e["disc"].append(r["rec"]["disc_ms"])
                e["level"].append(r["rec"]["level_db"]); e["q"].append(r["q"])
                e["found"] += sum(1 for v in r["events"] if v); e["chirps"] += len(r["events"])
            r0 = res.get(ref, {})
            if "error" in r0: print(f"run {k+1}: reference failed: {r0['error']}"); continue
            for n in per:
                r = res.get(n, {})
                if "error" in r: continue
                ds = [(e[0] - e0[0]) * 1000 - (dist.get(n, 0) - dist.get(ref, 0)) / SPEED_OF_SOUND * 1000
                      for e, e0 in zip(r["events"], r0["events"]) if e and e0]
                if len(ds) >= 3:                     # one chirp masked by a noise in the room must not pull the run
                    m = float(np.median(ds)); ds = [d for d in ds if abs(d - m) <= 1.0]
                per[n] += ds
                if ds: trend[n].append((tmid, float(np.median(ds))))
                line.append(f"{n.strip()}: {np.median(ds):+.3f} ms ({len(ds)}/{len(chirp_starts())})" if ds else f"{n.strip()}: no chirps")
            if loop_idx is not None and "error" not in res.get(LOOP, {}):
                rl = res[LOOP]
                for n in vs_loop:
                    r = res.get(n, {})
                    if "error" in r: continue
                    vs_loop[n] += [(e[0] - el[0]) * 1000 - dist.get(n, 0) / SPEED_OF_SOUND * 1000
                                   for e, el in zip(r["events"], rl["events"]) if e and el]
            print(f"run {k+1}: " + "   ".join(line), flush=True)
            time.sleep(a.pause)
        clocks = {nm: cap.clock_ppm(nm) for nm in names}
    finally:
        cap.stop()
        ok, b, f = restore(before)
        print(f"devices and volume as found: {'yes' if ok else 'NO'}" + ("" if ok else f" (before {b}, after {f})"))
        os.remove(sig); os.rmdir(os.path.dirname(sig))

    method = (f"acoustic chirp train (8 x 80 ms, 300-8000 Hz, {a.level} dBFS) from {out_name.strip()}, GCC-PHAT x16 per "
              f"chirp, AVCaptureAudioDataOutput host-clock pts (as the app), reference {ref}")
    report = {"measured": datetime.datetime.now().isoformat(timespec="seconds"), "method": method,
              "reference": {"name": ref, "uid": ca.get(ref, {}).get("uid")}, "devices": {}, "loopback": {}}
    print("\nRESULT (device minus reference; positive = the device is LATER; apply audio pts - delay)")
    for n, v in per.items():
        s = summarize(v); c = ca.get(n.strip(), {}); e = extra[n]
        if not s: print(f"  {n.strip():26} no usable chirps (found {e['found']}/{e['chirps']}, level {np.median(e['level']) if e['level'] else float('nan'):.1f} dBFS)"); continue
        tr = trend[n]
        slope = (np.polyfit([t for t, _ in tr], [m for _, m in tr], 1)[0] * 60) if len(tr) >= 3 and tr[-1][0] - tr[0][0] > 20 else None
        s.update({"name": n.strip(), "uid": c.get("uid"), "rate": c.get("rate"),
                  "reported_input_latency_frames": c.get("input"),
                  "run_medians_ms": [round(m, 3) for _, m in tr],
                  "drift_ms_per_min": round(float(slope), 3) if slope is not None else None,
                  "clock_ppm_vs_host": None if clocks.get(n) is None else round(clocks[n], 1),
                  "chirps_found": f"{e['found']}/{e['chirps']}", "level_dbfs": round(float(np.median(e['level'])), 1),
                  "drops": e["drops"], "max_pts_discontinuity_ms": round(float(max(e["disc"])), 3),
                  "distance_m": dist.get(n), "reference_distance_m": dist.get(ref)})
        print(f"  {n.strip():26} {s['median_ms']:+8.3f} ms  IQR {s['spread_ms']:.3f}  range {s['min_ms']:+.2f}..{s['max_ms']:+.2f}"
              f"  n={s['n']}  run medians {s['run_medians_ms']}"
              + (f"  drift {slope:+.3f} ms/min" if slope is not None else "")
              + (f"  stamps vs host {clocks[n]:+.1f} ppm" if clocks.get(n) is not None else ""))
        if n != LOOP: report["devices"][s["uid"] or n] = s
    if vs_loop:
        print("\nAGAINST THE BLACKHOLE LOOPBACK (absolute: speaker output latency + air + input latency + output start skew)")
        for n, v in vs_loop.items():
            s = summarize(v)
            if s:
                s["name"] = n.strip(); report["loopback"][ca.get(n.strip(), {}).get("uid") or n] = s
                print(f"  {n.strip():26} {s['median_ms']:+8.3f} ms  IQR {s['spread_ms']:.3f}  range {s['min_ms']:+.2f}..{s['max_ms']:+.2f}  n={s['n']}")
    c = ca.get(ref.strip(), {}); e = extra[ref]
    print(f"\n  reference {ref}: chirps found {e['found']}/{e['chirps']}, level {np.median(e['level']):.1f} dBFS, "
          f"train quality {np.median(e['q']):.1f}, drops {e['drops']}, max pts discontinuity {max(e['disc']):.3f} ms")
    if clocks.get(ref) is not None: print(f"  reference stamps vs host clock: {clocks[ref]:+.1f} ppm")
    report["reference"].update({"reported_input_latency_frames": c.get("input"), "chirps_found": f"{e['found']}/{e['chirps']}",
                                "clock_ppm_vs_host": None if clocks.get(ref) is None else round(clocks[ref], 1)})
    if a.save:
        os.makedirs(os.path.dirname(STORE), exist_ok=True)
        store = json.load(open(STORE)) if os.path.exists(STORE) else {"version": 1, "devices": {}, "history": []}
        store["reference"] = report["reference"]
        for uid, s in report["devices"].items():
            store["devices"][uid] = {**s, "measured": report["measured"], "method": method, "reference": ref}
        store["history"] = (store.get("history", []) + [report])[-20:]
        json.dump(store, open(STORE, "w"), indent=2, ensure_ascii=False)
        print(f"\nsaved: {STORE}")
    if a.json:
        json.dump(report, open(a.json, "w"), indent=2, ensure_ascii=False)

def cmd_clocks(a):
    """no sound played: open the inputs and watch, every --step seconds, how far each input's presentation stamps sit
    behind the host clock at delivery (lower envelope of arrival - pts). A stamp that walks against the host clock moves
    the sound against the picture by the same amount."""
    avf = avf_audio_inputs()
    names = [find(list(avf), d) for d in a.dev] if a.dev else [n for n in avf if n not in SKIP_INPUTS]
    cap = Capture(names); t_start = cap.now(); base = {}
    print(f"{'s':>5}  " + "  ".join(f"{n.strip()[:18]:>18}" for n in names) + "   (ms: envelope change since the first step)")
    try:
        while cap.now() - t_start < a.seconds:
            time.sleep(a.step)
            row = []
            for n in names:
                arr = [x for x in list(cap.grabs[n].arrivals) if x[0] > cap.now() - a.step]
                if not arr: row.append(f"{'-':>18}"); continue
                env = min(x[0] - x[1] for x in arr) * 1000
                base.setdefault(n, env); row.append(f"{env - base[n]:>+18.3f}")
            print(f"{cap.now() - t_start:5.0f}  " + "  ".join(row), flush=True)
    finally:
        cap.stop()

def cmd_show(_):
    if not os.path.exists(STORE): sys.exit("nothing measured yet")
    s = json.load(open(STORE))
    print(f"reference: {s.get('reference', {}).get('name')}")
    for uid, d in s["devices"].items():
        print(f"  {d['name']:26} {d['median_ms']:+8.3f} ms  IQR {d['spread_ms']:.3f}  n={d['n']}  {d['measured']}  ({uid})")

def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = p.add_subparsers(dest="cmd", required=True)
    sp.add_parser("list"); sp.add_parser("show")
    c = sp.add_parser("clocks", help="watch each input's time stamps against the host clock (silent)")
    c.add_argument("--dev", action="append", default=[]); c.add_argument("--seconds", type=float, default=300)
    c.add_argument("--step", type=float, default=15)
    m = sp.add_parser("measure")
    m.add_argument("--ref", default=REF_DEFAULT, help="reference input (the camera's embedded HDMI sound)")
    m.add_argument("--dev", action="append", default=[], help="input to measure (repeat); default: every real input")
    m.add_argument("--out", default=OUT_DEFAULT, help="speaker that plays the chirps (played to it directly)")
    m.add_argument("--runs", type=int, default=5)
    m.add_argument("--warmup", type=float, default=1.5,
                   help="seconds the inputs run before the first chirp; the UGREEN's stamps walk ~4 ms in the first ~3 min")
    m.add_argument("--pause", type=float, default=0.5, help="seconds between runs (long pauses show the clock drift)")
    m.add_argument("--level", type=float, default=-30.0, help="chirp peak in dBFS (moderate: -30)")
    m.add_argument("--loopback", action="store_true", help="also play into BlackHole 2ch and record it (electrical reference)")
    m.add_argument("--distance", action="append", default=[], help="NAME=metres from the speaker (removes 2.915 ms/m)")
    m.add_argument("--save", action="store_true", help=f"write the result to {STORE}")
    m.add_argument("--json", help="also write this run's report to a file")
    a = p.parse_args()
    {"list": cmd_list, "measure": cmd_measure, "show": cmd_show, "clocks": cmd_clocks}[a.cmd](a)

if __name__ == "__main__":
    main()
