# A/V sync: every microphone on the picture's frame (plan, 25.11.2026)

Marko (word for word in momentaryupdates.md, 25.11.2026): "if I'm, for example, using audio from road with that picture,
audio is not in sync ... You can use audio from Sony itself as scratch track and then align it with road and then see how
much is delay and then find the way how to calculate delay for every device ... It must be exactly in the same frame, the
sound. So when I'm doing my online lessons with drumming, there is no shift, and I can use any microphone."

**Status 25.11.2026: §2 (takes), §3 (SYNC key without AUTO MEASURE) and §4 (`tools/check_sync.py`) are built in v30;
see TAKEOVER. Drift from arrival times, AUTO MEASURE, §1.4 and the live paths: v31.**

Phase 1 (this document and `tools/avsync.py`): measure, then design. **No app code is changed yet**; a design review comes
first. Companion: docs/VIRTUALCAM_PLAN.md §7 (the same delay values feed Mantra VirtualCam; the keys below are the ones it
already names).

## 1. What was measured on the Mac (25.11.2026, 10:13 to 10:41, Marko in the room, not speaking)

Set-up as found: Sony α7 V (ILCE-7M5) → HDMI → UGREEN 15389 (video "UGREEN 15389 (V)" 2560x1440 30, sound "UGREEN 15389
(A)" = the camera's own microphone, embedded in the HDMI). The app was running, not recording, its sound input on the RØDE.
Test signal: 8 linear chirps (80 ms, 300 to 8000 Hz, irregular gaps 0.55 to 0.80 s) at −30 dBFS peak, played straight to
the ADAM D3V through ffmpeg's audiotoolbox output (the default devices and the volume were not touched; read before and
after: identical, output ADAM, input UGREEN, system BlackHole, volume 100, not muted).
Capture: one `AVCaptureSession` + `AVCaptureAudioDataOutput` per input (PyObjC), native format, exactly as the app captures;
every chirp located by GCC-PHAT (band 300 to 8000 Hz, ×16 up-sampled, parabolic peak) on the buffers' presentation time
stamps (host clock). The positions of the microphones relative to the ADAM were **not** known (Marko away from the desk),
so the numbers include the difference of the air paths (2.9 ms per metre).

`delay` = device minus camera sound, on the host clock. Negative = the device hears the event EARLIER than the camera's
HDMI sound does. The camera's HDMI output (picture and its sound) is late; every other microphone must be **held back**.

| Sound input (Core Audio UID) | at stream start | settled (after ~3 min) | spread inside a run (IQR) | Core Audio reports (dev + safety + stream frames) |
|---|---|---|---|---|
| RØDE NT1 5th Gen (`AppleUSBAudioEngine:RØDE:RØDE NT1 5th Gen:6CE2B668:1`) | −68.12 ms | **−72.48 ms** (drifts −0.14 ms/min) | 0.07 ms | 48 + 162 + 0 = 4.4 ms |
| MacBook Pro Microphone (`BuiltInMicrophoneDevice`) | −40.34 ms | **−44.15 ms** | 0.01 ms | 0 + 74 + 1439 = 31.5 ms |
| External Microphone, 44.1 kHz jack (`BuiltInHeadphoneInputDevice`) | −70.72 ms | **−74.55 ms** | 0.01 ms | 48 + 72 + 0 = 2.7 ms |
| UGREEN 15389 (A) = reference (`AppleUSBAudioEngine:MACROSILICON:UGREEN 15389:20230204:3`) | 0 | 0 | — | 48 + 108 + 0 = 3.3 ms |

"Settled" = the final run, `measure --warmup 200 --runs 6` (48 chirps, 46 used): run medians built-in −44.151 to −44.154,
External −74.552 to −74.555, RØDE −72.414 to −72.545 (its slow drift, §1.2); the same values had been reached at the end of
an earlier 5-minute run (−44.17, −74.53, −72.55). Three fresh sessions gave the same start value within 0.02 ms (RØDE −68.118 / −68.133 / −68.114; built-in −40.337 /
−40.354 / −40.337; External −70.735 / −70.727 / −70.698). Not measured: NDI Audio, Iriun, Zoom (virtual, no microphone),
BlackHole (see §1.2).

### 1.1 The camera sound walks about 4 ms after its stream starts, then stays

With the inputs opened together, the camera sound moved later against **all three** Mac inputs at the same rate, about
1.5 ms per minute, for about 2.5 minutes, then stopped (runs 48 s apart: RØDE −68.11, −69.39, −70.64, −71.92, −72.33,
−72.44, −72.55). The time stamps themselves did not walk against the host clock in that time (`avsync.py clocks`, no
sound: UGREEN and the Apple inputs both −3 ppm, RØDE −0.7 ppm from the arrival-time envelope). So it is the content: the
UGREEN's buffer between the camera's HDMI audio clock and its own USB clock fills by ~4 ms after the USB sound starts, then
holds. Consequences: (a) calibrate only after the UGREEN sound has run for 3 minutes (`--warmup 180`); (b) the app's
automatic calibration does the same (or keeps the UGREEN sound open from launch); (c) a 4 ms uncertainty is the worst case
if this is ignored: still under the 5 ms goal, but it is the biggest single error.

### 1.2 The clocks drift slowly; a long lesson needs a correction

Against the host clock (the picture's clock), the stamps of the Apple inputs and the UGREEN run 3 ppm, the RØDE 0.7 ppm
(silent 5-minute watch, lower envelope of delivery time minus pts). The Recorder places the first sample by its stamp and
then counts samples, so a 60-minute lesson on the MacBook microphone ends about 11 ms off; on the RØDE about 2.5 ms.
After settling, the RØDE still moved −0.144 ms per minute against the camera sound (about 8.6 ms per hour between the
two), while the Apple inputs stayed within 0.002 ms/min of it (they share its −3 ppm).
Not fatal for one take, but the design below corrects it continuously.

### 1.3 Methods compared

| Method | Result | Verdict |
|---|---|---|
| **Acoustic chirp from the ADAM, reference = the camera's own sound** | settled: per chirp IQR 0.01 ms (Apple inputs), 0.07 ms (RØDE, its drift included); run to run 0.003 ms | **Tightest. The one to use.** Measures exactly what Marko needs: each mic against the camera's sound. |
| Loopback: the same ffmpeg plays into BlackHole 2ch as well, BlackHole recorded | run medians spread 23 to 54 ms (e.g. −86.6, −28.8, −23.2, −83.7 ms) | **Useless as built**: two audiotoolbox outputs start independently, so the electrical "emission" moves by tens of ms. A real loopback reference needs ONE IO proc that writes the ADAM and BlackHole in the same IO cycle (an aggregate device), which is not worth it: the camera reference already removes the speaker's latency. Also BlackHole 2ch is Marko's Ableton recording route (VIRTUALCAM_PLAN §5): never play into it again without need. |
| Core Audio's reported latency | RØDE 4.4 ms, built-in 31.5 ms, External 2.7 ms, UGREEN 3.3 ms | **Not a substitute.** The built-in mic reports 31.5 ms and does sit ~28 ms later than the RØDE, but the camera's 68 ms is invisible to Core Audio (it is inside the camera). |

Precision achieved: ±0.01 to 0.1 ms per measurement (sub-sample, 48 kHz), ±0.02 ms repeatability, plus two systematic terms: the
air path (unknown distances; 2.9 ms/m; `--distance NAME=m` removes it) and the UGREEN start walk (≤ 4.4 ms, §1.1).

### 1.4 What the camera's own sound is NOT yet proven to be: in sync with its picture

The whole plan rests on "the α7 V's HDMI sound is on the picture's frame". Embedded audio travels with the frames through
the HDMI cable, but after the UGREEN the picture (UVC) and the sound (USB audio class) are two separate USB streams with
separate stamps. **This was not measured** (the camera faces the room, not a screen; Marko could not clap). Three ways, in
order of cost:
1. **Clap / stick hit in view (cheapest, needs Marko once):** 10 hits of a drumstick on the rim in the picture at 60 FPS.
   Sound onset from the UGREEN (A) stamps; picture: the frame where the stick stops (motion energy per frame, sub-frame by
   fitting the stick's path). Accuracy ±4 ms at 60 FPS with 10 hits. Gives `sync.videoOffsetMs.<videoID>`.
2. **Screen flash + beep:** point the camera at the MacBook screen; `avsync.py flash` (to be written) shows white for one
   frame and starts a chirp from the ADAM at the same host time. The display's own latency (10 to 30 ms) must be known
   first, so this is worse than 1 unless a photodiode is used.
3. **Sony's own check:** record the same clap internally on the camera card (its file is in sync by Sony) and compare
   with the take: any difference is the HDMI + UGREEN path.

Until one of these is done, the app treats camera sound = picture (videoOffsetMs = 0).

## 2. How the app applies it (Recorder.swift; design only)

**Values.** One number per sound input, remembered per Core Audio UID (= `AVCaptureDevice.uniqueID` of the sound input):
`sync.audioDelayMs.<uid>` (UserDefaults `community.auroville.webcamviewer`, the key VIRTUALCAM_PLAN §7 already names),
positive = hold this input's sound back. From the measurement: `audioDelayMs = −delay + videoOffsetMs(camera)`, e.g. RØDE
= +72.5 ms today. The camera's own sound has 0. A per-camera `sync.videoDelayMs.<videoID>` is used only when a sound
would have to come EARLIER than the picture (negative audio delay): then the picture is held instead (never both).

**In a take (Recorder.swift)** the delay is almost free, because the Recorder already places the sound by time stamp:
- In `writeAligned` the first sample's offset is `pts − firstVideoPTS`. With the delay it becomes
  `(pts + audioDelay) − firstVideoPTS`: positive delay = more silence before the first sample, negative = more cut. One
  line plus the value passed into `Recorder.init(audioDelay:)`. The FIFO, FLV pipe and ffmpeg line stay as they are.
  ffmpeg's interleaving copes with the sound arriving up to ~100 ms after its picture (the FLV/FIFO queues are 1024 deep).
- **Drift (§1.2):** every 2 s on the capture queue compare `samplesWritten / rate` with `(pts + audioDelay − firstVideoPTS)`
  of the newest buffer, where `pts` is corrected by the input's measured clock ratio against the host clock (smoothed
  arrival envelope, the method of `avsync.py clocks`). If they differ by more than 1 ms, drop or repeat ONE sample per
  ~20 ms of sound until even (inaudible at 48 kHz; at 3 ppm that is one sample every ~7 s). Count the corrections in
  `/status sync.corrections` so a fault cannot hide (silent-failure rule).
- A **stamp jump** over 70 ms (device restart, USB hiccup: OBS's `TS_SMOOTHING_THRESHOLD`) re-aligns by the stamp with a
  5 ms fade, and is a `soundWarning` line.
- **Scratch track:** when the camera's own sound is not the chosen input, the take carries it as a second audio track
  (`-map 2:a`, a second FIFO, AAC 128k, disposition 0, title "camera scratch"). Cost: one more AVCaptureAudioDataOutput on
  a second session for the UGREEN (A). It makes every take verifiable (§4) and repairable in DaVinci, and keeps the UGREEN
  stream running so its 4 ms walk (§1.1) is over before a lesson starts.

**In the live paths (preview monitoring, Mantra VirtualCam)** the sound is played or sent in real time, so the delay is a
real delay line: a ring buffer indexed by host time (as VIRTUALCAM_PLAN §7 "Audio"), read at `now − audioDelay`; for a
negative value the picture queue holds frames by `videoDelay` instead. A change of value crossfades 10 ms.

## 3. The SYNC control (UI proposal)

- In the bar, right of the sound pop-up: an NSButton titled **SYNC** (AX title "SYNC"), showing the current value of the
  chosen sound input: `SYNC +72` (ms). Narrow window: only `SYNC` (never clipped; it drops the number first, after the
  stats key). Grey value = never measured for this input; amber = measured more than 30 days ago or under different
  input settings (rate changed).
- A click opens a see-through overlay under the bar (the ChoiceOverlay style; Esc / click outside closes; it pushes the
  Sony overlay and the sound banner like LESSONS 38):
  - one row per sound input: name `(A)`, value field in ms (one decimal) with − / + keys (1 ms; Option = 0.1 ms), the date
    and method of the last measurement, spread;
  - **AUTO MEASURE** (NSButton, AX title "AUTO MEASURE"): runs §3.1 for the chosen input, or for all of them with
    Option-click;
  - **CAMERA OFFSET** row (videoOffsetMs, §1.4), set by the clap test;
  - the reference line: "Reference: UGREEN 15389 (A), the camera's own sound".
- API (same functions as the window, LESSONS 18): `GET /sync` → `{reference, inputs:[{uid, name, delayMs, measured,
  method, spreadMs}], videoOffsetMs, applied:{audioMs, videoMs}, corrections}`; `POST /sync {uid, ms}`; `POST
  /sync/measure {uid?|all, method: "chirp"|"clap"}` → the result (409 while recording).

### 3.1 Automatic calibration inside the app (with the Sony sound as scratch track)

1. Refuse while recording. Make sure the UGREEN (A) stream has run 180 s (it does if the scratch track input is kept open
   from launch; otherwise "warming up the camera sound, 3 min" with a countdown).
2. Open the input(s) to measure on their own short sessions next to the running one (no change to the chosen input).
3. **Chirp mode (default, no hands):** play the 8-chirp train at −30 dBFS to the current default output (the ADAM here),
   through an AVAudioEngine player node on that device only; never touch the default device or the volume. Repeat 3
   times.
   **Clap mode:** "Clap 5 times in front of the camera": GCC-PHAT of the two recordings directly against each other
   (any sharp broadband sound works, a drum hit too), so no known template is needed.
4. Locate each event by GCC-PHAT (vDSP FFT, 300 to 8000 Hz, ×16 interpolation), on the stamps. Keep chirps whose peak
   stands out (> 1.05 over the largest reflection) and lie within 1 ms of the median. Result = median; spread = IQR.
5. Accept only if ≥ 12 of 24 chirps and IQR < 1 ms; otherwise say why ("the camera did not hear the chirps: louder, or
   point it at the speaker"). Store value, date, method, spread. Show the before/after on the SYNC key.
6. Optional distance entry ("speaker to mic", "speaker to camera") removes 2.9 ms/m; without it the error is the
   difference of the two paths (at a desk: < 2 ms).

## 4. Re-verification (frame-accurate)

`tools/check_sync.py <take>` (to be written with the first build, in the style of check_take.py): reads the take's
track 1 (chosen mic, delay applied) and track 2 (camera scratch), GCC-PHAT in 10 s windows over the whole take, prints
the residual per window and its trend. Pass: |residual| < 5 ms everywhere (goal), never above 16 ms (half a frame at
30 FPS); trend < 1 ms per 10 min (drift correction working). Required takes for any version that touches sync: 60 s RØDE,
60 s MacBook mic, a 20-minute RØDE take (drift), a take started within 30 s of launch (UGREEN walk), and a hard kill.
The picture side is re-checked by §1.4 method 1 when Marko is there.

## 5. Interface for Mantra VirtualCam (only the interface)

The VirtualCam reads, never measures:
- `sync.audioDelayMs.<audioUID>` (Double, ms, ≥ 0 after normalising) and `sync.videoDelayMs.<videoID>` (Double, ≥ 0), as
  VIRTUALCAM_PLAN §7 defines; plus `sync.videoOffsetMs.<videoID>` (signed, camera sound vs its picture, §1.4) which the
  recorder folds into the two values above.
- `~/Library/Application Support/Webcam Recorder (Mantra)/avsync.json` is the measurement record (written by
  `avsync.py --save` and later by AUTO MEASURE): `{version, reference{name, uid}, devices{<uid>: {name, median_ms,
  spread_ms, min_ms, max_ms, n, run_medians_ms, drift_ms_per_min, clock_ppm_vs_host, reported_input_latency_frames,
  distance_m, measured, method, reference}}, history[≤20]}`. `median_ms` here is device minus camera sound (negative =
  earlier), so `audioDelayMs = −median_ms + videoOffsetMs`. The app imports it only for inputs that have no value of their
  own yet; a value Marko set by hand always wins.
- Change notification: `NSNotification` `SyncValuesChanged` inside the app; `GET /sync` for other processes.

## 6. What Marko must do with his hands

Nothing for the microphones (the chirp measurement runs by itself while he is quiet). Once, for the proof of the picture
side (§1.4): 10 drumstick hits in front of the camera, or a clap. Whenever the microphones move: AUTO MEASURE again (the
air path changes 2.9 ms per metre).

## 7. How to run the tool

    python3 tools/avsync.py list                                   # inputs, UIDs, Core Audio latencies, outputs
    python3 tools/avsync.py measure --warmup 180 --runs 6 --save   # every real input vs UGREEN (A), chirps from the ADAM
    python3 tools/avsync.py measure --dev "RØDE NT1 5th Gen" --distance "RØDE NT1 5th Gen=0.6" --distance "UGREEN 15389=2.5"
    python3 tools/avsync.py clocks --seconds 300                   # silent: each input's stamps against the host clock
    python3 tools/avsync.py show                                   # what avsync.json holds

It refuses while `/status` says recording, and stops between runs if a take starts. Needs the system's pyenv python3 with
numpy and PyObjC (both present on this Mac), and ffmpeg for playback only. ffmpeg's avfoundation input is not used for
capture: with several inputs open it lost about 20 % of the UGREEN packets (it keeps one audio buffer at a time) and it
refuses the RØDE's 24-bit packed format.
