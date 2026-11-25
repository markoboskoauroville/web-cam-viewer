#!/usr/bin/env python3
"""check_sync.py <take.mkv> [--json] [--goal 5] [--limit 16]: is the take's sound on the camera's frame? (v30, 25.11.2026)

A v30 take carries the chosen sound input as audio track 1 (the A/V sync delay applied) and the camera's own HDMI sound
(UGREEN 15389 (A), the reference) as track 2 "camera scratch". This reads both from the file and measures how far
track 1 sits from track 2:
  - chirp mode (when the take holds the chirp train of tools/avsync.py): every chirp located in both tracks by GCC-PHAT
    with x16 interpolation, residual = track 1 minus track 2 per chirp;
  - otherwise windows of 1 s (any sound with some high frequencies: music, drum hits, claps, speech),
    GCC-PHAT of track 1 against track 2.
residual > 0 = the chosen sound is LATER than the camera's sound. Pass: |median| <= --goal (5 ms) and every residual
within --limit (16 ms, half a frame at 30 FPS). Also the trend (ms per 10 min) for the drift correction.
Exit 0 = pass, 1 = fail, 2 = cannot read (no second track, nothing to measure).
"""
import json, os, subprocess, sys
import numpy as np

FFMPEG = next((p for p in ("/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg") if os.access(p, os.X_OK)), "ffmpeg")
SR = 48000


def track(path, n):
    r = subprocess.run([FFMPEG, "-nostdin", "-v", "error", "-i", path, "-map", f"0:a:{n}", "-ac", "1", "-ar", str(SR),
                        "-f", "f32le", "-"], capture_output=True)
    if r.returncode != 0 or not r.stdout:
        return None
    return np.frombuffer(r.stdout, dtype="<f4").astype(np.float64)


def chirp(sr=SR, f0=300.0, f1=8000.0, dur=0.08):          # the same signal as tools/avsync.py
    t = np.arange(int(sr * dur)) / sr
    x = np.sin(2 * np.pi * (f0 * t + (f1 - f0) / (2 * dur) * t * t))
    n = int(sr * 0.005); w = np.ones_like(x); r = 0.5 - 0.5 * np.cos(np.pi * np.arange(n) / n)
    w[:n] = r; w[-n:] = r[::-1]
    return x * w


def gcc_phat(sig, ref, up=16, band=(300, 8000)):
    """lag (samples, fractional) of ref inside sig, PHAT weighted, either polarity; plus the peak quality."""
    n = 1 << int(np.ceil(np.log2(len(sig) + len(ref))))
    G = np.fft.rfft(sig, n) * np.conj(np.fft.rfft(ref, n))
    G /= np.abs(G) + 1e-12
    f = np.fft.rfftfreq(n, 1 / SR); G[(f < band[0]) | (f > band[1])] = 0
    cc = np.fft.irfft(G, n * up)
    m = (len(sig) - len(ref) + 1) * up if len(sig) > len(ref) else len(sig) * up
    cc = cc[:m]
    k = int(np.argmax(np.abs(cc)))
    sg = 1.0 if cc[k] >= 0 else -1.0
    y0, y1, y2 = sg * cc[k - 1], sg * cc[k], sg * cc[(k + 1) % len(cc)]
    d = 0.5 * (y0 - y2) / (y0 - 2 * y1 + y2) if (y0 - 2 * y1 + y2) != 0 else 0.0
    side = np.concatenate([cc[: max(0, k - 4 * up)], cc[k + 4 * up:]])
    q = float(abs(cc[k]) / (np.max(np.abs(side)) + 1e-12)) if len(side) else 0.0
    return (k + d) / up, q


def chirp_positions(ref):
    """sample index of every chirp in the reference track (matched filter, peaks over 40 % of the strongest)"""
    c = chirp()
    n = 1 << int(np.ceil(np.log2(len(ref) + len(c))))
    cc = np.abs(np.fft.irfft(np.fft.rfft(ref, n) * np.conj(np.fft.rfft(c, n)), n)[: len(ref)])
    env = np.sqrt(np.convolve(ref ** 2, np.ones(len(c)), "same") / len(c)) * np.sqrt(np.sum(c ** 2) * len(c)) + 1e-9
    score = cc / env                                     # normalised: a loud noise is not a chirp
    thr = 0.4 * np.max(score)
    out, i = [], 0
    while i < len(score):
        if score[i] > thr:
            j = min(len(score), i + int(0.3 * SR)); k = i + int(np.argmax(score[i:j])); out.append(k); i = k + int(0.3 * SR)
        else:
            i += 1
    return out


def main():
    a = sys.argv[1:]
    if not a or a[0].startswith("-"):
        print(__doc__); return 2
    path = a[0]
    goal = float(a[a.index("--goal") + 1]) if "--goal" in a else 5.0
    limit = float(a[a.index("--limit") + 1]) if "--limit" in a else 16.0
    mic, ref = track(path, 0), track(path, 1)
    if mic is None or ref is None:
        print(f"{path}: needs two audio tracks (the chosen sound and the camera scratch)"); return 2
    n = min(len(mic), len(ref)); mic, ref = mic[:n], ref[:n]
    c = chirp(); res = []; mode = "chirps"
    for p in chirp_positions(ref):
        lo, hi = max(0, p - int(0.04 * SR)), min(n, p + len(c) + int(0.04 * SR))
        if hi - lo < len(c) + int(0.02 * SR):
            continue
        lr, qr = gcc_phat(ref[lo:hi], c)
        pre = min(lo, int(0.15 * SR))                     # the chosen sound may be up to 150 ms off (an unsynced take)
        lm, qm = gcc_phat(mic[lo - pre:hi + int(0.15 * SR)], c)
        lm -= pre
        if qr > 1.05 and qm > 1.05:
            res.append(((lo + lr) / SR, (lm - lr) / SR * 1000))
    if len(res) < 3:
        mode, res = "windows", []
        w, pad = SR, int(0.2 * SR)
        for s in range(pad, n - w - pad, w):
            seg = ref[s:s + w]
            if np.sqrt(np.mean(seg ** 2)) < 0.01:          # under -40 dBFS: room noise only, no event to lock on
                continue
            lag, q = gcc_phat(mic[s - pad:s + w + pad], seg)
            if q > 1.03:                                   # music is tonal: its peaks stand out less than a chirp's
                res.append((s / SR, (lag - pad) / SR * 1000))
    if len(res) < 3:
        print(f"{path}: nothing sharp enough to measure ({len(res)} events)"); return 2
    t = np.array([x for x, _ in res]); v = np.array([y for _, y in res])
    med = float(np.median(v))
    trend = float(np.polyfit(t, v, 1)[0] * 600) if t[-1] - t[0] > 30 else None
    out = {"file": path, "mode": mode, "events": len(v), "median_ms": round(med, 3),
           "iqr_ms": round(float(np.percentile(v, 75) - np.percentile(v, 25)), 3),
           "min_ms": round(float(v.min()), 3), "max_ms": round(float(v.max()), 3),
           "trend_ms_per_10min": None if trend is None else round(trend, 3),
           "first_s": round(float(t[0]), 2), "last_s": round(float(t[-1]), 2)}
    problems = []
    if abs(med) > goal: problems.append(f"median {med:+.2f} ms is over the goal of {goal} ms")
    worst = float(np.max(np.abs(v)))
    if worst > limit: problems.append(f"an event is {worst:.2f} ms off (limit {limit} ms)")
    out["pass"] = not problems; out["problems"] = problems
    if "--json" in a: print(json.dumps(out, indent=1))
    else:
        for k, val in out.items(): print(f"{k:20} {val}")
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main())
