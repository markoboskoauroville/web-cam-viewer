# Mantra VirtualCam: the interface between the recorder and the driver (VC-2, 25.11.2026)

Marko, 25.11.2026 (word for word in momentaryupdates.md): *"I want that our app web cam recorder stream through OBS
virtual camera with all audio and delay processing. You need to also enable Blue Cat PatchWork to be part of the audio
pipeline by taking the source code from a BlackHole virtual audio device I have here or use BlackHole as such. During
that, you need a composite for plugin delays so my students always see me playing in sync."*

This is the contract the app side (VC-3, VC-4, VC-5 of docs/VIRTUALCAM_PLAN.md) codes against. No app code is in this
step. The driver lives in its own public GPL-3 repository **markoboskoauroville/MANTRA_VIRTUALCAM_DRIVER** (fork of
BlackHole 0.7.1, built and tested only by GitHub Actions; its TAKEOVER.md lists every difference from BlackHole and the
install steps). The camera in Zoom stays **"OBS Virtual Camera"** (no paid Apple account); the microphone is
**"Mantra VirtualCam"**.

## 1. The devices

| | Name | UID (stable, use this) | Visible | Streams | Who |
|---|---|---|---|---|---|
| Mic | `Mantra VirtualCam` | `MantraVirtualCam_UID` | yes | 1 input, 2 ch Float32 | Zoom / FaceTime / Chrome / OBS |
| Feed | `Mantra VirtualCam Feed` | `MantraVirtualCamFeed_UID` | **hidden** | 1 output, 2 ch Float32 | the recorder writes here |
| Fallback A1 | `Mantra VirtualCam` (aggregate) | `MantraVirtualCamAggregate_UID` | yes | BlackHole 2ch's 2 in / 2 out | only if the driver is refused |

- Bundle `/Library/Audio/Plug-Ins/HAL/Mantra VirtualCam.driver`, bundle id `community.auroville.mantra.virtualcam.driver`,
  factory UUID `35D75853-9B41-482B-8A1A-FEB55C9ECAFE`. It lives next to BlackHole2ch.driver without a clash.
- Rates 44100 / 48000 / **96000**; 48000 at start. Mic and Feed share one rate (one ring): the recorder sets the Feed's
  `kAudioDevicePropertyNominalSampleRate` to its own processing rate (48000) before starting, and Zoom then reads 48000.
- Neither device can become a default device; nothing uses them unless chosen.
- The mic's volume control exists but does nothing (Zoom's automatic mic volume cannot touch the level). Mute works.
- The two channels arrive exactly as written. Zoom takes the first channel of a stereo mic: write the same mono
  mix to both channels unless a stereo feed is wanted.

## 2. Finding the Feed (it is hidden, so it is not in `kAudioHardwarePropertyDevices`)

```swift
func deviceID(uid: String) -> AudioObjectID {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cf = uid as CFString
    var id = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let err = withUnsafeMutablePointer(to: &cf) { q in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                   UInt32(MemoryLayout<CFString>.size), q, &size, &id) }
    return err == noErr ? id : AudioObjectID(kAudioObjectUnknown)
}
```

Route choice, in order: `MantraVirtualCamFeed_UID` found → route **driver** (write to it); else
`MantraVirtualCamAggregate_UID` found → route **aggregate** (write to its output; warn: shares BlackHole 2ch with
Ableton); else route **none** → the red banner "Mantra VirtualCam driver not installed" and nothing is written.
Re-resolve when `kAudioHardwarePropertyDevices` changes (a coreaudiod restart gives new object IDs). Never resolve by name.

Write with an IO proc on the Feed (`AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart`), not through
AVAudioEngine's output node: the IO proc's `inOutputTime` is what the sync needs. Set the Feed's
`kAudioDevicePropertyBufferFrameSize` to 256 (5.33 ms at 48 kHz) or 128 if the CPU allows.

## 3. Timing: what the driver guarantees

- **One clock, the host clock.** The driver's zero time stamps are `mach_absolute_time` based (BlackHole's model,
  period 16384 frames). The Feed and the Mic return the same zero time stamps.
- **Zero added latency, truthfully reported:** `kAudioDevicePropertyLatency` = 0 and `kAudioDevicePropertySafetyOffset`
  = 0 on both devices and both stream latencies = 0. The app reads them anyway (`Ldrv` below) and adds them.
- **The loopback is sample-time exact:** a sample written into the Feed in the IO cycle whose `inOutputTime` is
  (S, H) reaches Zoom with input time (S, H). So the sound the recorder places at host time H is, for Zoom, sound
  captured at host time H. Proven bit exact by the driver's unit test; `tools/vcam_probe.py --loopback` checks it on
  the real HAL (offset 0 frames).
- **Underrun = silence, never old sound**: if Zoom reads past what the Feed wrote, it gets zeros (counted).
- Expected values on the Mac: Feed/Mic latency 0, safety 0, stream latency 0; buffer as set (512 by default, like
  BlackHole 2ch, which reads 0/0/512 here today).

## 4. The status property `'mvst'` (ring fill and clock, for drift control)

Custom property on both devices: selector `'mvst'` (0x6D767374), global scope, element main. It is a
**CFDictionary** (CFPropertyList, the caller releases it). Read it from a normal thread, at most ~10 Hz, never in an IO proc.

```swift
var addr = AudioObjectPropertyAddress(mSelector: 0x6D76_7374, mScope: kAudioObjectPropertyScopeGlobal,
                                      mElement: kAudioObjectPropertyElementMain)
var ref: Unmanaged<CFPropertyList>?
var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
let st = AudioObjectGetPropertyData(feedID, &addr, 0, nil, &size, &ref) == noErr
    ? (ref?.takeRetainedValue() as? [String: Any]) : nil
```

Keys: `version` (1), `sampleRate`, `clockRatio` (1.0: the device is the host clock), `hostTicksPerFrame`,
`anchorHostTime`, `zeroTimeStampCount`, `zeroTimeStampPeriod`, `ringFrames` (65536), `latencyFrames` (0),
`safetyOffsetFrames` (0), `micClients` / `feedClients` (IO clients running), `lastWriteEndSampleTime`,
`lastWriteHostTime`, `lastWriteFrames`, `lastReadEndSampleTime`, `lastReadHostTime`, `lastReadFrames`,
**`fillFrames` / `fillMs`** (how far the Feed is ahead of what Zoom has read; 0 when either side is stopped),
`writeCycles`, `readCycles`, **`silentReads`** (Zoom read with nothing fresh: an underrun or no writer),
`overloads` (a Feed write missed its deadline), `nowHostTime`.

**Where the drift really is:** the driver runs ON the host clock, so the Feed never drifts against Zoom. The drift
the app must steer is between the capture microphone's crystal (RØDE, UGREEN) and the host clock: the app's own
host-time ring (capture PTS in, Feed `inOutputTime` out) holds its fill with the slow PI loop of VIRTUALCAM_PLAN §7
(±200 ppm). `silentReads` rising or `micClients` > 0 with `feedClients` = 0 are the signals for the red banner;
`fillMs` is a cross-check of the Feed side only.

## 5. The composite delay: students see the hit and hear it together

Everything is in ms on the host clock, relative to the **reference** = the Sony α7 V's own sound in the HDMI
("UGREEN 15389"), which travels with the picture (docs/AVSYNC_PLAN.md).

**Audio path, fixed part** (what the sound costs before Zoom gets it):

    A = micOffset + Lpw + Lau + Lapp + Ldrv

| Term | Source | Note |
|---|---|---|
| micOffset | `avsync.json` → `devices[<mic uid>].median_ms` (avsync sign: > 0 = the mic hears LATER than the camera sound) | per input device; the RØDE is usually negative (earlier than the camera's ~68 ms internal path) |
| Lpw | PatchWork: `AUAudioUnit.latency` (s) = `kAudioUnitProperty_Latency` | changes when a plug-in inside PatchWork changes: observe it (KVO on `latency` or `AudioUnitAddPropertyListener`) and recompute. PatchWork already sums its inner plug-ins' latencies. **`tailTime` is NOT added** (it is how long sound rings out after the input stops, not a delay) |
| Lau | every other hosted AU (gain, limiter): the same `latency` | 0 for the plain gain |
| Lapp | the app's own fixed hold between capture and Feed write: the processing block (e.g. 1024 frames if the AU renders in blocks of 1024) + the ring's fill target (20 ms in §7) | measured, not typed |
| Ldrv | Feed `kAudioDevicePropertyLatency` + `SafetyOffset` + stream latency (output scope) + Mic same (input scope) | 0 today; read, never assumed |

The Feed's IO buffer is **not** a separate term: the app chooses, for the cycle at `inOutputTime.mHostTime` H, the
ring samples whose capture time is H − (A − micOffset) − audioHold, so whatever the buffer size, the sound lands at
its planned host time.

**Video path, fixed part:** `V = videoOffset + Pv`, where videoOffset = `sync.videoDelayMs.<camera uid>` (0 for the
UGREEN: it IS the reference) and Pv = our video processing time (enqueue host time − capture PTS, median over 1 s).
The OBS extension forwards our PTS as is (≤ 5.6 ms poll), which Zoom then sees; that small part is inside `trim`.

**The two holds** (one of them is always 0, so the total latency is as small as it can be):

    video_hold = max(0, A − V + trim)          // the picture waits for the sound (PatchWork, buffers)
    audio_hold = max(0, V − A − trim)          // the sound waits for the picture (the mic is earlier than the camera)

`trim` = `virtualcam.trimMs`, signed, default 0, **positive = in Zoom the sound is still later than the picture**
(then the picture must wait longer). It comes from one clap test in a Zoom local recording (VC-6). Note: section 7
of VIRTUALCAM_PLAN.md adds `+ trim` on the audio-hold side while calling positive "audio later"; that would move the
sound the wrong way. VC-4 implements the sign above (and the plan's line is to be corrected with it).

Each frame is enqueued into the OBS sink at `capturePTS + Pv + video_hold` **with that time as its PTS**; each
sound sample is written into the Feed at host time `capturePTS + (A − micOffset) + audio_hold`. Then for Zoom
the hit's picture and the hit's sound carry the same host time: **Marko's students see and hear the stick together.**

Worked examples (48 kHz, Pv = 8 ms, trim = 0, Lapp = 5.3 ms, Ldrv = 0):
- RØDE micOffset −44 ms, PatchWork with nothing latent (Lpw 0): A = −38.7, V = 8 → audio_hold 46.7 ms, video_hold 0.
- Same, PatchWork with a look-ahead limiter of 4096 samples (Lpw 85.3 ms): A = 46.6 → video_hold 38.6 ms, audio_hold 0.
  Removing the limiter during the lesson switches back to audio_hold, with the 5 ms crossfade of §7 (no click).

`GET /virtualcam/status` shows every term: `{audio:{route, micOffsetMs, LpwMs, LauMs, LappMs, LdrvMs, AMs, holdMs,
ringMs, driftPpm, underruns, driver:{fillMs, silentReads, overloads, feedClients, micClients}}, video:{PvMs, VMs,
holdMs}, trimMs}`.

## 6. Re-measuring the whole chain

1. **Audio chain against the camera** (no Zoom needed; the recorder feeding the VirtualCam, VCAM on, the RØDE as
   its microphone, PatchWork in the chain):

       python3 tools/avsync.py measure --dev "Mantra VirtualCam" --dev "RØDE NT1 5th Gen" --warmup 180 --runs 6

   ffmpeg/avfoundation sees "Mantra VirtualCam" as an ordinary input (it is not in avsync's SKIP_INPUTS; check `list`
   shows it). Expected: delay(Mantra VirtualCam) − delay(RØDE) = Lpw + Lau + Lapp + Ldrv + audio_hold, within 1 ms.
   A larger difference = a term the app does not know about (write it in LESSONS).
2. **Picture and sound as an app would get them:** record "OBS Virtual Camera" + "Mantra VirtualCam" together
   (`ffmpeg -f avfoundation -i "OBS Virtual Camera:Mantra VirtualCam"`, a deadline, then kill) while Marko claps or
   hits a stick in front of the α7 V; the flash/clap offset in that file is the virtual path's error before Zoom.
   Goal ±1 frame.
3. **Zoom itself (VC-6):** a Zoom local recording of the same clap; its offset minus step 2's is Zoom's own pipeline
   → `virtualcam.trimMs`.

## 7. Install and what Marko does

Once, at a quiet moment (never during a lesson or a recording: Core Audio restarts, about 2 s of silence on every
device): download the latest release of MANTRA_VIRTUALCAM_DRIVER, unzip, `./install.sh` (he types "yes" and then his
own admin password into sudo or, with `--dialog`, into the macOS dialog; never in a chat). It verifies the device
appears. `./uninstall.sh` removes it. `python3 tools/vcam_probe.py` (read only) shows both devices and the status
property. If coreaudiod refuses the ad-hoc driver: `python3 tools/fallback_aggregate.py create` (route A1).

## 8. The live chain in Zoom: picture and processed sound together (25.11.2026, after the first live call on v32)

Marko, during a live Zoom call on the v32 VCAM: in Zoom he picks OBS Virtual Camera and gets the picture, but how does he
get the sound, processed by the same app, in perfect sync with that picture, as already solved for recordings?

**What v32/v33 can and cannot do with a raw microphone in Zoom.** The RØDE's SYNC value is +72.5 ms: its sound is 72.5 ms
EARLIER than the camera's frame (the α7 V delays its HDMI picture). The VCAM picture adds its own path on top (capture
stamp → enqueue about 64 ms at 2560x1440 30, mostly the card's delivery; LESSONS 59). So with the raw RØDE chosen as
Zoom's microphone the sound reaches Zoom roughly 72.5 + 64 ms (less Zoom's own mic latency) BEFORE the picture. Holding
the picture back makes that worse; the picture cannot be made earlier. Only holding the SOUND fixes it, and the app can
hold sound only in a stream it writes: the Mantra VirtualCam microphone. v33 therefore shows the Zoom mic and how far its
sound is ahead (`GET /virtualcam/status` → `zoomMic`), and holds the picture only for a mic that is LATER than the camera
(negative SYNC value): `hold = sync.videoDelayMs + max(0, −sync.audioDelayMs.<zoomMic>) + trim + extraDelayMs`.
`POST /virtualcam {"zoomMic": "mantra" | "default" | uid | name}` (remembered as `virtualcam.zoomMic`; default = the sound
input chosen in the app).

**The chain of the audio-path version (driver installed, PatchWork hosted):**

    mic (RØDE)  →  SYNC hold (the mic's own value, as in a take)  →  PatchWork AU (latency Lpw)  →  ring  →
    driver Feed "Mantra VirtualCam Feed"  →  Zoom microphone "Mantra VirtualCam"

    camera (UGREEN/α7 V)  →  VCAM convert (Pv)  →  video hold  →  OBS sink  →  Zoom camera "OBS Virtual Camera"

Both streams are planned on the host clock from the capture stamps (§5). The sound of a hit captured at host time t is
written into the Feed for host time t + audioHold + (A − micOffset); the picture of the same hit leaves at
t_frame + Pv + videoHold. With A = micOffset + Lpw + Lau + Lapp + Ldrv and V = videoOffset + Pv:
`videoHold = max(0, A − V + trim)`, `audioHold = max(0, V − A − trim)`: the same arithmetic as the take path (where the
recorder moves the mic by its SYNC value against the picture), plus the plug-in and driver latencies. For the RØDE
(micOffset −72.5) with PatchWork at 0 latency: the sound waits ≈ 72.5 + Pv ms and the picture 0; with a look-ahead
limiter of 85 ms in PatchWork the picture waits instead. Zoom's own extra latency is the same for both streams it
receives as a pair only up to its own pipelines; one clap test in a Zoom local recording measures the rest and sets
`virtualcam.trimMs` (VC-6). extraDelayMs (v32 API) is where the audio side plugs its A in.
