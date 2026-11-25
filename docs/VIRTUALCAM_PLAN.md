# Mantra VirtualCam: plan (research 25.11.2026)

Marko, 25.11.2026 (word for word in momentaryupdates.md): *"my web recorder become virtual camera. We can call it Mantra
VirtualCam. And then if I'm in any, for example, Zoom, I can choose Mantra VirtualCam as audio source and Mantra VirtualCam
as video source ... the whole processing is done inside my web recorder application ... It must be exactly in the same
frame, the sound."* and *"look deep into the source code of OBS and use everything we can use."*

This is a research and plan document. Nothing was installed, no audio device or Zoom/OBS setting was changed, no app code
was edited. Companion doc: docs/PATCHWORK_CONTROL.md (the audio processing inside PatchWork; this plan takes its
route A, PatchWork hosted as an Audio Unit).

## 1. Decision in six lines

1. **Video: feed the OBS Virtual Camera's sink stream straight from the Webcam Recorder.** OBS does not need to run. The
   extension is already installed, Developer ID signed and approved on this Mac. Marko's own MANTRA_VIRTUAL_CAM proved
   the route on 27.10.2026 (v1 to v5). It adds about 1 frame of latency and needs nothing from Marko.
2. **In Zoom the camera is called "OBS Virtual Camera", not "Mantra VirtualCam".** A camera with our own name needs a
   camera extension signed by a paid Apple team. Marko decided against that on 27.10.2026 ("Please work with OBS only";
   MANTRA_VIRTUAL_CAM TAKEOVER). Legacy DAL plug-ins no longer load (shown below). Nothing else can rename the camera.
3. **Audio: our own CoreAudio HAL driver whose device is named "Mantra VirtualCam".** It is built from BlackHole (GPL-3)
   on GitHub Actions in its own public repository and signed ad hoc. It has a visible input-only device, "Mantra
   VirtualCam", for Zoom, and a hidden output-only twin that the recorder writes into. The microphone does get Marko's
   name.
4. **Fallback for audio if the ad-hoc driver does not load:** an aggregate device named "Mantra VirtualCam" over the
   installed BlackHole 2ch. The recorder creates it through the API, with no install and no password. It shares
   BlackHole with Ableton.
5. **Sync: everything runs on the host clock.** Video frames keep their capture time stamp and are held back by the
   video delay. Audio goes through a ring buffer indexed by host time and is read out by the delay. The audio delay
   (per audio device) and the video delay (per video device) come from the measurement worker. The paths' own
   latencies (PatchWork, driver, processing) are added in automatically.
6. **License:** we copy no OBS code. We only talk to its installed extension through Apple's public CoreMediaIO API, so
   GPLv2 does not reach the app. The driver is a GPL-3 fork in its own repository. The app stays separate.

## 2. Evidence gathered on the Mac (read only, 25.11.2026)

| What | Command | Result |
|---|---|---|
| Signing identities | `security find-identity -v -p codesigning` | 0 valid. One "Mantra Apps" (self-made, CSSMERR_TP_NOT_TRUSTED). |
| Apple Developer account | grep in MANTRA_MANIFEST and MANTRA_VIRTUAL_CAM | None. MANTRA_MANIFEST lessons-learned: "Our own camera named "Mantra …" needs a paid Apple Developer account", and Marko declined it (27.10.2026). |
| Mac build workflow | MANTRA_MANIFEST/workflows/mac-swift.yml, README | `SIGN=-` (ad hoc) on the runner, re-signed "Mantra Apps" on install. **No signing secrets on the repos** ("Secrets: none"). |
| Camera extensions | `systemextensionsctl list` | `com.obsproject.obs-studio.mac-camera-extension (33.0.2)`, team 2MMRE5MTB8, **activated enabled**. Iriun `com.iriun.macwebcam.extension`, NDI `com.newtek...VirtualInput.Extension`, both enabled. |
| OBS extension signature | `codesign -dvv` on the .systemextension | Developer ID Application: Wizards of OBS LLC (2MMRE5MTB8), hardened runtime. Entitlements: app-sandbox and application-groups `2MMRE5MTB8.com.obsproject.obs-studio`. Info.plist CMIOExtensionMachServiceName `2MMRE5MTB8.com.obsproject.obs-studio.mac-camera-extension`. |
| OBS app entitlements | `codesign -d --entitlements` | `com.apple.developer.system-extension.install` (restricted: needs a provisioning profile), team-identifier, application-groups, camera, audio-input. |
| CMIO devices and streams (spike, see section 9) | ctypes on CoreMediaIO, nothing started | `OBS Virtual Camera` uid 7626645E-…: stream "OBS Camera Extension Stream Source" (direction 1) and **"OBS Camera Extension Stream Sink" (direction 0)**. `Iriun Camera` also has an "IriunVideoSink". NDI Virtual Camera: source only. UGREEN 15389, FaceTime HD. |
| DAL plug-ins | `ls /Library/CoreMediaIO/Plug-Ins/DAL` + the spike | `NDIVideoOut.plugin` (com.newtek.cmio.DAL.NDI, built against the 15.2 SDK) is installed **but no device from it appears**, even in an unhardened python process that loads CoreMediaIO in process. `system_profiler SPCameraDataType` lists only UGREEN, FaceTime, OBS, Iriun, NDI Virtual Camera. So DAL is dead on macOS 15.0 here. |
| Zoom | `codesign -d --entitlements /Applications/zoom.us.app` | camera and audio-input. **No disable-library-validation**, so Zoom would not load a self-signed DAL plug-in even where DAL still worked. |
| SIP | `csrutil status` | **disabled**. `nvram boot-args`: none set. See option V-a for why this still does not make our own extension possible. |
| HAL drivers | `codesign -dvv /Library/Audio/Plug-Ins/HAL/*` | ARK (Rogue Amoeba), BlackHole2ch (Existential Audio, Q5C99V536K), IriunMic, NDIAudio, NDIAudioOut, ZoomAudioDevice. All are Developer ID; none is ad hoc, so there is no local proof yet that ad hoc loads (section 6, risk A2). |
| Audio devices | `system_profiler SPAudioDataType` | RØDE NT1 5th Gen (1 in), UGREEN 15389 (2 in), External Microphone, MacBook Pro Microphone, BlackHole 2ch (2/2), NDI Audio (2 in, 6 out), Iriun Webcam Audio, ZoomAudioDevice (2/2), ADAM D3V, BenQ, headphones. |
| PatchWork AU | Component Info.plist | `aumf 1kh1 Bcau` "Blue Cat Audio: BC PatchWork", x86_64+arm64 (docs/PATCHWORK_CONTROL.md). |
| Webcam Recorder signature | `codesign -dvv` | "Mantra Apps", flags 0x0: **no hardened runtime**, so it may load the PatchWork AU in process. |
| Repo visibility | `gh repo view` | web-cam-viewer is PUBLIC. |

## 3. What OBS's source teaches (obs-studio main 0c790bd, 21.11.2026, plugins/mac-virtualcam, libobs)

Cloned (sparse) into the session scratchpad only, not into this repository.

**The camera extension** (src/camera-extension/*.swift):
- `OBSCameraDeviceSource` makes one CMIOExtensionDevice with **two streams**: a Source (what Zoom reads) and a **Sink**
  (what a feeding app writes). Both have one format only: **1920x1080, kCVPixelFormatType_32BGRA, 60 fps**
  (`OBSCameraFrameRate = 60`). That is why MANTRA_VIRTUAL_CAM measured "it takes only 1920x1080" (its LESSONS 2).
- With no sink client, a 60 Hz timer sends the placeholder picture.
- When a client starts the sink, a timer at **3 x 60 = 180 Hz** calls `consumeSampleBuffer(from: client)`. Each buffer
  goes on to the Source **with the buffer's own presentationTimeStamp as hostTimeInNanoseconds**. This matters for sync:
  the time stamp we put on a frame is the time stamp Zoom gets. The extension forwards a frame as soon as it receives it
  and never schedules by PTS, so any delay must be applied by us before we enqueue the frame.
- `OBSCameraStreamSink.authorizedToStartStream(for:)` accepts any client and remembers only the last one. Any process
  may feed it (proven 27.10.2026 with OBS closed). If OBS starts its own virtual camera at the same moment, the two
  feeders fight.
- The extension has no audio at all. OBS has never shipped a virtual microphone on the Mac (`import IOKit.audio` is used
  only for the transport-type constant).

**The feeding side** (src/obs-plugin/plugin-main.mm), the same as our VirtualCamera.swift:
CMIOObjectGetPropertyData(kCMIOHardwarePropertyDevices), find the device by its UID (from the plug-in's Info.plist
`OBSCameraDeviceUUID`; we use the name). Take its second stream (the sink). Call `CMIOStreamCopyBufferQueue`, then
`CMIODeviceStartStream`. For each frame, make an IOSurface-backed CVPixelBuffer from a pool,
`CMSampleBufferCreateForImageBuffer` with PTS = frame timestamp in ns, then `CMSimpleQueueEnqueue`. Frames reach the
extension through IOSurface, so there is no copy across the process boundary. (Before macOS 13 OBS used a mach server
(OBSDALMachServer) for the DAL plug-in. Not needed now.)

**Audio sync in libobs** (obs-source.c), ideas we take:
- Every source has a **sync offset in ns** (`obs_source_set_sync_offset`, the "Sync Offset" field in Advanced Audio
  Properties), simply added to the audio time stamps (`in.timestamp += sync_offset`, line 1688). This is the per-device
  delay of our interface (section 7).
- `TS_SMOOTHING_THRESHOLD = 70 ms`: a jump in a source's time stamps under 70 ms counts as jitter and is smoothed. A
  bigger jump is a real discontinuity and resets the source. Our ring buffer does the same.
- Audio is mixed in blocks of `AUDIO_OUTPUT_FRAMES = 1024` (21.3 ms at 48 kHz). Video is held to match audio time
  stamps, not the other way round.

## 4. Video: the options

| | Route | Name in Zoom | Latency added | Marko's hands | Risks | Verdict |
|---|---|---|---|---|---|---|
| V-a | Our own CMIO camera extension "Mantra VirtualCam" | Mantra VirtualCam | about 1 frame | System Settings approval, a paid Apple team | The container app needs the restricted entitlement `com.apple.developer.system-extension.install`, which only a provisioning profile grants. The extension's mach service name must start with an app group of a Team ID, and an ad-hoc signature has no Team ID. SIP off plus `systemextensionsctl developer on` drops the /Applications and notarization checks, but not the entitlement check (only the boot-arg `amfi_get_out_of_my_way`, which turns off code-signing enforcement for the whole Mac, would). | **Not possible** without the paid account Marko declined on 27.10.2026. Not proposed. |
| **V-b1** | **Recorder writes into the OBS Virtual Camera sink (CMIO, IOSurface)** | OBS Virtual Camera | ≤ 5.6 ms in the extension (180 Hz poll) + our processing | none (already approved) | Fixed 1920x1080 BGRA (the slice gets pillarboxed). OBS updates could change the extension: the stream names have been stable since OBS 30, and the feeder checks them and says so in a calm text. OBS's own "Start Virtual Camera" fights with us, so we detect that and warn. | **Recommended.** Proven 27.10.2026 (MANTRA_VIRTUAL_CAM probe/sinkprobe.swift, Sources/VirtualCamera.swift). |
| V-b2 | Recorder → NDI or Syphon → OBS scene → OBS starts virtual cam over obs-websocket 5 (`StartVirtualCam`) | OBS Virtual Camera | NDI encode/decode 1 to 3 frames + OBS render frame + OBS's audio-sync buffering | OBS must run | Two apps, OBS settings to keep, more latency, DistroAV plug-in versions | Only as a fallback if the sink ever stops taking foreign clients. |
| V-b3 | Recorder sends NDI (NDI SDK) → "NDI Virtual Input" app → NDI Virtual Camera + NDI Audio | NDI Virtual Camera / NDI Audio | 1 to 3 frames (SpeedHQ) | NDI Virtual Input running with our source chosen | Proprietary SDK license, a third app, NDI names | One plus: audio and video share NDI time stamps. Not chosen: the latency and the names. |
| V-c | Legacy DAL plug-in | (ours) | n/a | admin install | **Does not load on macOS 15** (NDIVideoOut.plugin installed, no device appears). Zoom also has library validation. | Dead. |
| V-d | Iriun Camera's "IriunVideoSink" | Iriun Camera | ? | none | Undocumented, proprietary, may break with any Iriun update | No. |

## 5. Audio: the options

| | Route | Name in Zoom | Install | Risks | Verdict |
|---|---|---|---|---|---|
| **A2** | **Own HAL driver from BlackHole: visible input-only "Mantra VirtualCam" 2 ch 48 kHz, hidden output-only mirror "Mantra VirtualCam Feed"** (`kDevice_HasOutput=false`, `kDevice2_IsHidden=true`, `kDevice2_HasInput=false`, `kDevice2_HasOutput=true`, `kCanBeDefaultDevice=false`, `kSampleRates=48000`, `kLatency_Frame_Size=0`, new `kDriver_Name`, `kPlugIn_BundleID`, `kManufacturer_Name`, our icon) | **Mantra VirtualCam** | Once: copy into /Library/Audio/Plug-Ins/HAL + `killall coreaudiod`. Marko types his own admin password into the macOS dialog. | **Ad-hoc signature not yet proven** on this Mac (every installed driver is Developer ID). Building BlackHole and Background Music without a team is common practice; if coreaudiod refuses, A1 takes over the same day. Restarting coreaudiod cuts all sound for about 2 s (never during a take or a lesson). | **Recommended.** Isolated: nobody else writes into it. The name is Marko's. Zero added latency (BlackHole's loopback reads in the same IO cycle). It runs on the host clock (`gDevice_HostTicksPerFrame = hostClockFrequency / sampleRate`). |
| A1 | Aggregate device "Mantra VirtualCam" over the installed BlackHole 2ch, made by the recorder with `AudioHardwareCreateAggregateDevice` (public, not private) | Mantra VirtualCam | none, no password | **BlackHole 2ch is Marko's Ableton recording route** (skill ableton): our feed would mix into his Ableton recordings and the other way round. Aggregates can add a safety offset. | Fallback only, and only while Ableton is not recording through BlackHole. |
| A3 | Own driver written from Apple's NullAudio AudioServerPlugIn sample | Mantra VirtualCam | same as A2 | More code to own (the loopback, the ring and the time stamps are ours to get right) | Only if the GPL-3 license of A2 is ever a problem. It is not today: the driver is its own program. |
| A4 | NDI Audio (via NDI Virtual Input) | NDI Audio | none | the NDI names, a third app, latency | No. |
| A5 | ZoomAudioDevice | — | — | Zoom's private device for screen-share sound | No. |

**Why not a shared-memory ring between the app and the driver?** A2 needs none. The recorder plays into the hidden
output device, the driver's ring is the shared memory, and Zoom reads the visible input. All the timing information we
need is in the IO-proc time stamps (section 7). A custom shared-memory driver (App Group or mach service) would need the
same signing the camera extension needs, and adds nothing.

## 6. The recommendation, with its risks

- **V-b1 + A2, with A1 as the audio fallback.** In Zoom: Video "OBS Virtual Camera", Microphone "Mantra VirtualCam".
  The recorder still captures the UGREEN/Sony picture and the RØDE (or any) microphone itself. Everything the take
  shows and hears is what Zoom gets: picture, slice, overlays (if wanted), PatchWork, delays.
- **Risk 1 (medium): the ad-hoc driver may be refused by coreaudiod.** Check: after the install, does `system_profiler
  SPAudioDataType` show "Mantra VirtualCam"? Does `log show --predicate 'process == "coreaudiod"' --last 5m` complain
  about the signature? If refused: A1, then a "Mantra Apps"-signed build as a second try.
- **Risk 2 (low): an OBS update changes the extension.** The feeder looks up the sink by direction 0 and the name
  "Sink", checks the format, and says in the status line what it found. Do not update OBS before a lesson without
  checking VCAM.
- **Risk 3 (low): OBS itself starts its virtual camera.** Detect it (OBS running + websocket `GetVirtualCamStatus`, or
  frames we did not send) and tell Marko. Never stop his OBS.
- **Risk 4 (medium): clock drift.** The mic (USB RØDE: its own crystal) and the driver (host clock) differ by up to about
  100 ppm, roughly 6 ms per minute. Without correction the ring underruns or overruns within minutes. The ring adapts
  its read rate (a tiny resampling ratio, like OBS's resampler) to hold its fill at the target. See section 7.
- **Risk 5 (Zoom, not ours):** Zoom processes the camera and the mic in separate pipelines, and its noise suppression
  eats drums. Marko sets in Zoom (his hands, his settings): Audio → "Original sound for musicians" ON, "Automatically
  adjust microphone volume" OFF, echo cancellation off for drumming. The leftover Zoom pipeline difference is measured
  once (clap test, Zoom local recording) and stored as `virtualcam.trimMs`.
- **Name of the camera:** it stays "OBS Virtual Camera" (fact, from Marko's own decision of 27.10.2026). The bar key
  and the status say "Mantra VirtualCam → OBS Virtual Camera" so he knows what to pick in Zoom.

## 7. A/V sync in the virtual path: the interface

**One clock: the host clock** (mach_absolute_time, `CMClockGetHostTimeClock`). AVCapture gives both the video and the
audio sample buffers PTS on the host clock. The OBS extension passes our PTS on as host time. The driver's zero time
stamps are host time. So every point can be compared without converting.

**Values the measurement worker provides** (it measures them; the VirtualCam and the recorder only read them):

| Key (UserDefaults `community.auroville.webcamviewer`) | Type | Meaning |
|---|---|---|
| `sync.audioDelayMs.<audioDeviceUID>` | Double, ≥ 0 | How long to hold back this audio device's sound so it lands on its frame (α7 V camera audio = the in-sync reference). |
| `sync.videoDelayMs.<videoUniqueID>` | Double, ≥ 0 | How long to hold back this video device's picture, for the case where the sound is later than the picture. |
| `virtualcam.trimMs` | Double, signed, default 0 | Virtual path only: Zoom's leftover difference, from one clap test. Positive = audio later. |

The worker normalizes each audio/video pair so at most one of the two delays is non-zero. The recorder's takes use the
same two per-device values (without the trim), so a take and Zoom agree. The API (same functions as the window):
`GET /sync` → `{video:{uid, delayMs}, audio:{uid, delayMs}, trimMs, applied:{audioMs, videoMs}}`; `POST /sync {audio:
{uid, ms}} | {video:{uid, ms}} | {trimMs}`. A change takes effect within one ring period, with a short crossfade and no
click.

**What the VirtualCam adds by itself** (measured live, never typed in):
- `Pv`: our video processing time = host time at enqueue minus capture PTS (slice, CI scale, BGRA). Median over 1 s.
- `Pa`: the audio path = PatchWork `AUAudioUnit.latency` (+ its `tailTime` is ignored) + one IO buffer of the feed
  device + the visible device's `kAudioDevicePropertyLatency` + `kAudioDevicePropertySafetyOffset` (both 0 in BlackHole
  by default; read them, do not assume).
- Applied delays: `D = audioDelay − videoDelay + (Pv − Pa) + trim`. If D ≥ 0, the audio is held back by D; if D < 0,
  the video is held back by −D. The smaller of the two is always 0, so the total latency is as low as it can be.

**How each side applies it:**
- **Video:** a small frame queue ordered by `capturePTS + videoHold`. A frame is enqueued into the sink when the host
  time reaches it, **with that time as its PTS** (the extension hands the PTS to Zoom). Queue cap 500 ms. If the sink's
  CMSimpleQueue is full, the oldest frame is dropped (as now), and the drops are counted.
- **Audio:** the capture buffers (after PatchWork) are written into a ring indexed by host time. Each buffer's
  start = its PTS, and every sample's time follows from the rate. The IO proc of "Mantra VirtualCam Feed" gets
  `inOutputTime.mHostTime` = the moment those samples will exist. It reads the ring at `mHostTime − audioHold − Pa` (as
  far as the ring can know them). Fill target 20 ms over the minimum. Drift: the read-pointer ratio is steered by a
  slow PI loop on the fill (±200 ppm max, inaudible), the same idea as OBS's audio resampling. A jump in capture time
  stamps over 70 ms (OBS's `TS_SMOOTHING_THRESHOLD`) resets the ring with a 5 ms fade. An underrun writes silence and
  counts it. It never repeats old sound.
- **Status:** `GET /virtualcam/status` → `{video:{on, sink:"OBS Virtual Camera", fps, sent, dropped, holdMs, PvMs},
  audio:{on, device:"Mantra VirtualCam", route:"driver|aggregate", ringMs, targetMs, driftPpm, underruns, overruns,
  holdMs, PaMs}, obsOwnVirtualCam: bool, warnings:[...]}`. The same values appear on the stats line when VCAM is on.

## 8. Build in small releases (each one = the next whole version, built by GitHub Actions only)

Version numbers are "the next free N". Other workers release into the same repo, so check `let VERSION` in app/App.swift
at the start of each step. Steps VC-1, VC-3 and VC-4 touch Viewer.swift/Recorder.swift, which the PatchWork and sync workers
change too. Agree the order with them, never two at once.

1. **VC-1 = video only (no install, nothing for Marko).** New module `app/VirtualCam.swift`: the CMIO sink feeder from
   MANTRA_VIRTUAL_CAM Sources/VirtualCamera.swift (Marko's own code, one module everywhere: move it into a shared file
   both apps compile, or copy with a note), extended with sink lookup by direction 0 + "Sink", format check, capture-PTS
   time stamps and the frame-hold queue. A key **VCAM** on the bar (NSButton with AX title, green "VCAM ●" while
   feeding), `POST /virtualcam {on}`, `GET /virtualcam/status`, remembered `virtualcam.on`. It feeds the processed frame
   (slice pillarboxed into 1920x1080). Check: read "OBS Virtual Camera" with ffmpeg avfoundation, N frames with a deadline,
   then kill (MANTRA_VIRTUAL_CAM LESSONS 3: never an open-ended reader). Compare a frame with the recorder's own. Latency
   = capture PTS vs the PTS that arrives. CPU and the take check (`tools/check_take.py`) while VCAM is on.
2. **VC-2 = the driver (new public repo `mantra-virtualcam-audio`, GPL-3, README/TAKEOVER/LESSONS).** A fork of
   BlackHole with the constants of section 5. A GitHub workflow: `xcodebuild` Release with `GCC_PREPROCESSOR_DEFINITIONS`,
   `CODE_SIGN_IDENTITY=-`, zip of `Mantra VirtualCam.driver` + `install.sh` / `uninstall.sh`, a release marked Latest.
   Install (Marko's hands, once): the recorder (or the line in the release notes) runs the copy and `killall coreaudiod`
   through the macOS administrator dialog. **Marko types his password into that macOS dialog himself. It is never asked
   for in chat or by voice, and never stored.** Check: the device appears in system_profiler and Audio MIDI Setup; the
   Feed twin is hidden and found by `kAudioHardwarePropertyTranslateUIDToDevice`; coreaudiod's log is clean. If it is
   refused: build A1 into VC-3 instead.
3. **VC-3 = audio into "Mantra VirtualCam".** An IO proc on the hidden Feed device, the host-time ring with drift control
   (section 7), with no PatchWork yet. `/virtualcam/status` audio fields; the red banner if the driver is missing or
   underruns repeat. Check: a 1 kHz tone burst is played into the capture path and read back from "Mantra VirtualCam"
   with ffmpeg, N seconds with a deadline. Offset is stable over 30 min (drift loop holds, 0 underruns). Takes are
   unchanged (check_take.py).
4. **VC-4 = the sync values applied.** Read the keys of section 7, compute D, hold video or audio, `GET/POST /sync`,
   crossfade on change. The recorder takes use the same per-device values (in Recorder.swift, coordinated with its owner).
   Check: set 100 ms on a known source → the measured offset moves by 100 ± 1 ms in both the take and the Zoom-side read.
5. **VC-5 = PatchWork inside the chain** (docs/PATCHWORK_CONTROL.md v+4/v+5: host `aumf 1kh1 Bcau`, then audio through
   it). Its `latency` goes into Pa automatically. Check: the offset stays the same with a latency-adding plug-in
   inserted.
6. **VC-6 = proof in Zoom.** Zoom's "Test speaker and microphone" + a local Zoom recording of a clap or a stick hit in
   front of the α7 V. The measurement worker's tool reads the offset from that recording and writes `virtualcam.trimMs`.
   Goal: the audio within ±1 frame (±16.7 ms at 60, ±33 ms at 30) on the drum hit. Marko's hand: start the Zoom test
   meeting and hit the drum (asked by voice).

Every step: his words saved first, a green GitHub run, the release Latest, the installed copy re-signed "Mantra Apps",
his settings compared before and after, testclean, LESSONS/TAKEOVER/skill/registry updated (skill webcam-recorder,
ten-point check).

## 9. The safe spike that was run

`python3 -I cmio_list.py` (session scratchpad, ctypes on CoreMediaIO, read only: it lists devices, streams and
directions and never starts a stream). It found the OBS sink alive on OBS 33.0.2 ("OBS Camera Extension Stream Sink",
direction 0) and confirmed that the installed NDI DAL plug-in produces no device on macOS 15.0. Nothing else was run:
no `auval -v`, no stream start, no install.

## 10. What Marko must approve or do with his hands

| When | What | Why |
|---|---|---|
| VC-1 | nothing; in Zoom pick **OBS Virtual Camera** | the extension is already approved |
| VC-1 | do not press OBS's own "Start Virtual Camera" while VCAM is on | one feeder at a time |
| VC-2 | approve the driver install: **he types his own admin password into the macOS dialog** (never asked for in chat) | /Library/Audio/Plug-Ins/HAL is root-owned; coreaudiod restarts (about 2 s of silence everywhere, not during a lesson) |
| VC-3 | in Zoom pick microphone **Mantra VirtualCam** | — |
| VC-3 | his Zoom audio settings: Original sound for musicians ON, auto volume OFF (his settings, his hands; we only tell him) | Zoom's processing would undo the drum sound |
| VC-6 | one Zoom test with a clap or a drum hit | sets the trim |
| never | no paid Apple account, no camera extension of our own, no SIP/AMFI boot-args | his decision of 27.10.2026 and the Mac's safety |

## 11. Licenses: what we may copy, what we only learn from

- **OBS Studio: GPL-2.0-or-later.** We copy **no** OBS code. The app talks to OBS's installed, separately distributed
  extension through Apple's public CoreMediaIO API (no linking, no OBS file in our repo), so the GPL does not apply to
  the Webcam Recorder. What we take from it are ideas, which are not copyrightable: the sink pattern, PTS as host time,
  the per-source sync offset, 70 ms time-stamp smoothing, holding video to match audio. If OBS code were ever copied
  (for example its camera-extension Swift files), the whole program containing it would have to be GPLv2-or-later with
  source published. The repo is public, but the app's license would change and every later copy would have to keep the
  notices. Do not.
- **BlackHole: GPL-3.0.** The fork lives in its own public repository under GPL-3, keeps the copyright notice and
  LICENSE, and is renamed (we must not ship it as "BlackHole": its README requires new kDriver_Name/bundle id/icon, and
  Existential Audio wants a paid license only for non-GPL-3 projects). The Webcam Recorder only talks to it through
  CoreAudio (a separate program at arm's length), so the app's license is not affected. Release zips carry the source
  link.
- **Apple NullAudio sample** (Apple sample-code license, permissive): the alternative A3 if GPL-3 is ever unwanted.
- **NDI SDK** (proprietary): not used.
- **Blue Cat's PatchWork**: Marko's commercial license, hosted as an Audio Unit as any DAW does; nothing copied.
- **MANTRA_VIRTUAL_CAM VirtualCamera.swift**: Marko's own code, reused freely.
