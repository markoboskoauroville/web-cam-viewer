#!/usr/bin/env python3
"""check_take.py <take.mkv> [--max-lag 1.0] [--json]

The truth check of a Webcam Recorder take, read from the disk file (21.11.2026, v23).
Players such as IINA and DaVinci Resolve read a Matroska file in order. Sound written at Stop behind the video
(v13 to v22) decodes with ffmpeg but plays only for a fraction of a second. So, in FILE ORDER:
  lag = newest video pts written so far - pts of this audio packet; the take passes when max lag <= --max-lag.
Also: audio present, audio vs video duration, audio packets vs the count expected for that duration (1024 samples
per AAC packet), the default flags, and the mean level of the first 2 s and of the whole take.
Exit 0 = pass, 1 = fail, 2 = cannot read.
"""
import json
import subprocess
import sys


def run(args):
    return subprocess.run(args, capture_output=True, text=True)


def main():
    argv = sys.argv[1:]
    if not argv:
        print(__doc__)
        return 2
    path = argv[0]
    max_lag = float(argv[argv.index("--max-lag") + 1]) if "--max-lag" in argv else 1.0
    as_json = "--json" in argv

    s = run(["ffprobe", "-v", "error", "-show_entries",
             "stream=index,codec_type,codec_name,channels,sample_rate,width,height:stream_disposition=default",
             "-show_entries", "format=duration", "-of", "json", path])
    if s.returncode != 0:
        print("cannot read", path, s.stderr.strip())
        return 2
    info = json.loads(s.stdout)
    streams = info.get("streams", [])
    v = next((x for x in streams if x["codec_type"] == "video"), None)
    a = next((x for x in streams if x["codec_type"] == "audio"), None)

    p = run(["ffprobe", "-v", "error", "-show_entries", "packet=stream_index,pts_time,duration_time,pos",
             "-of", "csv=p=0", path])
    newest_v = None
    max_lag_seen = 0.0
    max_lag_pos = None
    a_count = 0
    a_first = a_last = v_first = v_last = None
    for line in p.stdout.splitlines():
        parts = line.split(",")
        if len(parts) < 4 or parts[1] in ("", "N/A"):
            continue
        idx, pts = int(parts[0]), float(parts[1])
        dur = float(parts[2]) if parts[2] not in ("", "N/A") else 0.0
        if v and idx == v["index"]:
            newest_v = pts if newest_v is None else max(newest_v, pts)
            v_first = pts if v_first is None else min(v_first, pts)
            v_last = pts + dur if v_last is None else max(v_last, pts + dur)
        elif a and idx == a["index"]:
            a_count += 1
            a_first = pts if a_first is None else min(a_first, pts)
            a_last = pts + dur if a_last is None else max(a_last, pts + dur)
            if newest_v is not None and newest_v - pts > max_lag_seen:
                max_lag_seen = newest_v - pts
                max_lag_pos = parts[3]

    def level(extra):
        r = run(["ffmpeg", "-nostats", "-hide_banner"] + extra + ["-i", path, "-map", "0:a:0", "-af", "volumedetect",
                                                                    "-f", "null", "-"])
        for l in r.stderr.splitlines():
            if "mean_volume" in l:
                return l.split("mean_volume:")[1].strip()
        return None

    vdur = (v_last - v_first) if v_first is not None else 0.0
    adur = (a_last - a_first) if a_first is not None else 0.0
    rate = int(a["sample_rate"]) if a else 48000
    expected = int(round(vdur * rate / 1024)) if a else 0
    out = {
        "file": path,
        "video": f'{v["width"]}x{v["height"]}' if v else None,
        "video_seconds": round(vdur, 3),
        "audio": f'{a["codec_name"]} {a.get("channels")} ch {rate} Hz' if a else None,
        "audio_seconds": round(adur, 3),
        "audio_first_pts": a_first,
        "audio_end_vs_video_end": round((a_last or 0) - (v_last or 0), 3) if a else None,
        "audio_packets": a_count,
        "audio_packets_expected": expected,
        "max_lag_seconds": round(max_lag_seen, 3),
        "max_lag_at_byte": max_lag_pos,
        "default_video": v["disposition"]["default"] if v else None,
        "default_audio": a["disposition"]["default"] if a else None,
        "mean_first_2s": level(["-t", "2"]) if a else None,
        "mean_whole": level([]) if a else None,
    }
    problems = []
    if not a:
        problems.append("no audio stream")
    else:
        if max_lag_seen > max_lag:
            problems.append(f"audio lags video by {max_lag_seen:.2f} s in file order (limit {max_lag})")
        if vdur - adur > 1.0:
            problems.append(f"audio {vdur - adur:.2f} s shorter than video")
        if out["default_audio"] != 1:
            problems.append("audio track is not default")
    out["pass"] = not problems
    out["problems"] = problems
    if as_json:
        print(json.dumps(out, indent=1))
    else:
        for k, val in out.items():
            print(f"{k:24} {val}")
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main())
