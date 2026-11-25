#!/usr/bin/env python3
"""vcam_check.py: read "OBS Virtual Camera" as Zoom would (AVFoundation, BGRA) and measure what VCAM sends (v32).

Always N frames and a hard deadline, then the session stops (MANTRA_VIRTUAL_CAM LESSONS 3: never an open-ended reader).
It opens only the OBS camera, never the capture card, so the app's own capture is not touched.

  python3 tools/vcam_check.py --frames 300 --seconds 12 [--png out.png] [--json out.json]

Per frame: arrival host time, the sample's PTS (= the moment VCAM enqueued it), and, when VCAM draws its test stamp
(POST /virtualcam {"stamp": true}), the capture time decoded from the squares along the top-left edge.
Reports: fps of buffers, fps of distinct pictures, delivery (arrival - PTS) and the whole path (arrival - capture).
"""
import argparse, json, signal, sys, threading, time

import numpy as np
import objc
import AVFoundation as AVF
import CoreMedia
import Quartz
from Foundation import NSObject
from libdispatch import dispatch_queue_create

NAME = "OBS Virtual Camera"


def host_now():
    return CoreMedia.CMTimeGetSeconds(CoreMedia.CMClockGetTime(CoreMedia.CMClockGetHostTimeClock()))


class Grab(NSObject):
    def init(self):
        self = objc.super(Grab, self).init()
        self.rows = []
        self.keep = None
        self.want = 0
        self.done = threading.Event()
        self.save_at = 0
        return self

    def captureOutput_didOutputSampleBuffer_fromConnection_(self, out, sb, conn):
        now = host_now()
        if self.done.is_set():
            return
        pts = CoreMedia.CMTimeGetSeconds(CoreMedia.CMSampleBufferGetPresentationTimeStamp(sb))
        pb = CoreMedia.CMSampleBufferGetImageBuffer(sb)
        Quartz.CVPixelBufferLockBaseAddress(pb, 1)
        try:
            w, h = Quartz.CVPixelBufferGetWidth(pb), Quartz.CVPixelBufferGetHeight(pb)
            bpr = Quartz.CVPixelBufferGetBytesPerRow(pb)
            raw = Quartz.CVPixelBufferGetBaseAddress(pb).as_buffer(bpr * h)
            a = np.frombuffer(raw, dtype=np.uint8).reshape(h, bpr)[:, : w * 4].reshape(h, w, 4)
            g = a[12, 12::24, 1][:42].astype(int)          # the centre row of the stamp squares (BGRA: G)
            stamp = None
            if len(g) == 42 and g[0] - g[1] > 120:
                thr = (int(g[0]) + int(g[1])) / 2
                v = 0
                for b in g[2:42]:
                    v = (v << 1) | (1 if b > thr else 0)
                stamp = v / 1e6
            sig = a[100:h:97, 50:w:89, :3].astype(np.int32)   # a sparse grid: which picture is this
            sig_sum = int(sig.sum())
            if len(self.rows) == self.save_at:
                self.keep = (w, h, a.copy())
            self.rows.append({"arrive": now, "pts": pts, "stamp": stamp, "sig": sig_sum, "w": w, "h": h,
                              "grid": sig if len(self.rows) < 2 else None})
        finally:
            Quartz.CVPixelBufferUnlockBaseAddress(pb, 1)
        if len(self.rows) >= self.want:
            self.done.set()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", type=int, default=240)
    ap.add_argument("--seconds", type=float, default=10)
    ap.add_argument("--warmup", type=float, default=1.0, help="seconds of frames thrown away first")
    ap.add_argument("--png", help="save one frame (BGRA raw + PNG via ffmpeg)")
    ap.add_argument("--json", help="write the per-frame rows")
    a = ap.parse_args()
    signal.signal(signal.SIGALRM, lambda *_: (print("deadline: killed"), sys.exit(3)))
    signal.alarm(int(a.seconds + a.warmup + 15))

    devs = [d for d in AVF.AVCaptureDevice.devicesWithMediaType_(AVF.AVMediaTypeVideo) if d.localizedName() == NAME]
    if not devs:
        print(json.dumps({"ok": False, "error": NAME + " not found"})); return 2
    dev = devs[0]
    s = AVF.AVCaptureSession.alloc().init()
    inp, err = AVF.AVCaptureDeviceInput.deviceInputWithDevice_error_(dev, None)
    if inp is None:
        print(json.dumps({"ok": False, "error": str(err)})); return 2
    s.addInput_(inp)
    out = AVF.AVCaptureVideoDataOutput.alloc().init()
    out.setVideoSettings_({Quartz.kCVPixelBufferPixelFormatTypeKey: Quartz.kCVPixelFormatType_32BGRA})
    out.setAlwaysDiscardsLateVideoFrames_(False)
    grab = Grab.alloc().init()
    grab.want = 10 ** 9
    q = dispatch_queue_create(b"vcam_check", None)
    out.setSampleBufferDelegate_queue_(grab, q)
    s.addOutput_(out)
    s.startRunning()
    time.sleep(a.warmup)
    grab.rows = []
    grab.want = a.frames
    grab.save_at = min(30, max(0, a.frames // 2))
    grab.done.wait(a.seconds)
    grab.done.set()
    s.stopRunning()

    rows = grab.rows
    if not rows:
        print(json.dumps({"ok": False, "error": "no frames"})); return 1
    span = rows[-1]["arrive"] - rows[0]["arrive"]
    # a new picture = a new stamp (VCAM's test stamp); without stamps the sparse pixel grid (a still scene counts less)
    key = "stamp" if all(r["stamp"] for r in rows) else "sig"
    distinct = 1 + sum(1 for x, y in zip(rows, rows[1:]) if x[key] != y[key])
    deliver = sorted((r["arrive"] - r["pts"]) * 1000 for r in rows)
    whole = sorted((r["arrive"] - r["stamp"]) * 1000 for r in rows if r["stamp"])
    # distinct pictures only (the first buffer of each picture): the path of a new picture
    firsts = [r for i, r in enumerate(rows) if i == 0 or r[key] != rows[i - 1][key]]
    whole_new = sorted((r["arrive"] - r["stamp"]) * 1000 for r in firsts if r["stamp"])
    gaps = sorted((y["arrive"] - x["arrive"]) * 1000 for x, y in zip(rows, rows[1:]))
    med = lambda v: round(v[len(v) // 2], 2) if v else None
    pct = lambda v, p: round(v[min(len(v) - 1, int(len(v) * p))], 2) if v else None
    res = {"ok": True, "frames": len(rows), "seconds": round(span, 3), "size": f"{rows[0]['w']}x{rows[0]['h']}",
           "fps": round((len(rows) - 1) / span, 2) if span > 0 else None,
           "distinctPictures": distinct, "distinctBy": key, "distinctFps": round((distinct - 1) / span, 2) if span > 0 else None,
           "gapMs": {"median": med(gaps), "p95": pct(gaps, 0.95), "max": round(gaps[-1], 2) if gaps else None},
           "deliveryMs": {"median": med(deliver), "p95": pct(deliver, 0.95)},
           "stamped": len(whole),
           "captureToReaderMs": {"median": med(whole), "p95": pct(whole, 0.95), "min": round(whole[0], 2) if whole else None},
           "captureToReaderNewPictureMs": {"median": med(whole_new), "p95": pct(whole_new, 0.95), "n": len(whole_new)}}
    if a.png and grab.keep:
        w, h, arr = grab.keep
        rawp = a.png + ".bgra"
        arr.tofile(rawp)
        import subprocess
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "bgra", "-s", f"{w}x{h}", "-i", rawp,
                        "-frames:v", "1", a.png], check=False, timeout=30)
        res["png"] = a.png
        res["pngArriveHost"] = rows[grab.save_at]["arrive"] if len(rows) > grab.save_at else None
    if a.json:
        with open(a.json, "w") as f:
            json.dump([{k: v for k, v in r.items() if k != "grid"} for r in rows], f)
    print(json.dumps(res, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
