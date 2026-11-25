#!/usr/bin/env python3
"""vcam_rival.py: a second feeder of "OBS Virtual Camera" for the VCAM owner-conflict test (v32).

It does what OBS's own Start Virtual Camera does to the sink: start the sink stream from another process (the extension
keeps only the last client), hold it for --seconds while sending nothing, then stop it. Read-only otherwise; no OBS.
  python3 tools/vcam_rival.py --seconds 5
"""
import argparse, ctypes, ctypes.util, json, sys, time

cmio = ctypes.CDLL("/System/Library/Frameworks/CoreMediaIO.framework/CoreMediaIO")
cf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))


def fcc(s):
    return int.from_bytes(s.encode(), "big")


class Addr(ctypes.Structure):
    _fields_ = [("sel", ctypes.c_uint32), ("scope", ctypes.c_uint32), ("elem", ctypes.c_uint32)]


SYSTEM = 1
GLOBAL, MAIN = fcc("glob"), 0
cmio.CMIOObjectGetPropertyDataSize.argtypes = [ctypes.c_uint32, ctypes.POINTER(Addr), ctypes.c_uint32, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
cmio.CMIOObjectGetPropertyData.argtypes = [ctypes.c_uint32, ctypes.POINTER(Addr), ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p]
QPROC = ctypes.CFUNCTYPE(None, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_void_p)
cmio.CMIOStreamCopyBufferQueue.argtypes = [ctypes.c_uint32, QPROC, ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
cmio.CMIODeviceStartStream.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
cmio.CMIODeviceStopStream.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]


def ids(obj, sel):
    a = Addr(fcc(sel), GLOBAL, MAIN); size = ctypes.c_uint32(0)
    if cmio.CMIOObjectGetPropertyDataSize(obj, ctypes.byref(a), 0, None, ctypes.byref(size)) != 0:
        return []
    n = size.value // 4; arr = (ctypes.c_uint32 * n)(); used = ctypes.c_uint32(0)
    cmio.CMIOObjectGetPropertyData(obj, ctypes.byref(a), 0, None, size, ctypes.byref(used), arr)
    return list(arr)


def name(obj):
    a = Addr(fcc("lnam"), GLOBAL, MAIN); ref = ctypes.c_void_p(); used = ctypes.c_uint32(0)
    if cmio.CMIOObjectGetPropertyData(obj, ctypes.byref(a), 0, None, 8, ctypes.byref(used), ctypes.byref(ref)) != 0 or not ref.value:
        return ""
    buf = ctypes.create_string_buffer(512)
    cf.CFStringGetCString(ref, buf, 512, 0x08000100)
    return buf.value.decode()


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--seconds", type=float, default=5); a = ap.parse_args()
    dev = next((d for d in ids(SYSTEM, "dev#") if name(d) == "OBS Virtual Camera"), None)
    if dev is None:
        print(json.dumps({"ok": False, "error": "OBS Virtual Camera not found"})); return 2
    sink = next((s for s in ids(dev, "stm#") if "sink" in name(s).lower()), None)
    if sink is None:
        print(json.dumps({"ok": False, "error": "no sink"})); return 2
    proc = QPROC(lambda *_: None); q = ctypes.c_void_p()
    r1 = cmio.CMIOStreamCopyBufferQueue(sink, proc, None, ctypes.byref(q))
    r2 = cmio.CMIODeviceStartStream(dev, sink)
    t0 = time.time(); time.sleep(a.seconds)
    r3 = cmio.CMIODeviceStopStream(dev, sink)
    print(json.dumps({"ok": r1 == 0 and r2 == 0, "copyQueue": r1, "start": r2, "stop": r3, "held": round(time.time() - t0, 2)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
