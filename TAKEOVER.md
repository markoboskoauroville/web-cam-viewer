# TAKEOVER: Webcam Recorder (Mantra)

**State 20.11.2026: v13 = crash-safe H.264 MKV quality recording.** Record now writes the final Matroska file from the
first frame through an OBS-style ffmpeg-mux helper path. VideoToolbox creates H.264 packets at the live feed's exact
dimensions and delivered FPS; ffmpeg packet-copies video and muxes AAC audio into one-second MKV clusters. LOW / MID / HIGH
beside Record use 10 / 25 / 50 Mb/s at 1080p30 and scale by pixels × delivered FPS; the key also shows free-space minutes.
Hard-killing the app during recording left a decodable H.264/AAC MKV.
Final disk verification: on the live 1920×1080 20 FPS UGREEN feed, LOW/MID/HIGH targets were 6.67/16.67/33.33 Mb/s and
their five-second files were Matroska + H.264 High/yuv420p + AAC, exactly 1920×1080 and 20.0 FPS, with all frames decoded.
The static-scene CBR files measured about 5.84/14.83/29.87 Mb/s at the video-plus-overhead probe (about 10% below target).

**State 21.11.2026: v16 = SNAP follows the remote's windows.** Tested with Marko's Accessibility on: snap, moving and resizing either window moves/resizes the other, unsnap, and snap-opens-the-remote all work. Found: the opened remote first shows only its camera list (800x353, "Double-click a device name to connect to it") and replaces it with the tall control panel after connecting, and its text is not readable through Accessibility. v16 prefers the tallest window, follows the replacement (stays snapped), and judges the camera state by window shape: short = list, so the ENABLE / double-click / Refresh instructions show; tall = panel, message cleared. The v15 check against macOS's camera list was wrong (the Sony in USB remote mode is not a video device) and is gone.

**State 21.11.2026: v15 = SNAP REMOTE.** Marko: "this app recognize this remote window and there should be some kind of a snap remote
action button ... they are together as one piece and if I resize any of them both are resizing ... if the remote is not open,
the application opens it ... if it cannot find camera, give instructions to press enable on the screen of Sony camera."
`app/Snap.swift` (SnapRemote): the button SNAP REMOTE in the top bar finds the main window of Sony Imaging Edge Remote
(`com.sony.Remote`, /Applications/Imaging Edge/Remote.app) through the Accessibility API, opens the app first if it is not
running, and places it against this window (same side as it was, same height, top edges level). An AXObserver on the remote
window (moved / resized / destroyed) and NSWindow notifications on ours keep the pair together: moving or resizing either
moves or resizes the other; echoes of frames we set ourselves are recognised and ignored. If the remote refuses a height,
our window takes the height it kept. Click again (SNAPPED ✓) to unsnap; quitting the remote unsnaps. Needs Accessibility
permission (prompted; message says where). If no Sony camera is in the camera list, the picture area says to press ENABLE
on the camera's screen. API: `POST /snap {"on": true|false}`, `/status` has `snapped`. Compiled by GitHub only; not yet seen by Marko.

**State 21.11.2026: v14 = actual file bitrate and compact disk time.** The LOW / MID / HIGH key now shows the real MKV
bitrate measured from disk (the finalized value is read by ffprobe and matches the file's `format.bit_rate`) and formats
free-space duration as `h m s`, omitting any zero hour or minute units. A capture frame below 64 KB is shown as `— Mb/s`
until enough output exists to report a meaningful rate. API fields: `actualBitrate`, `remainingSeconds`, `remainingTime`.
Recording dimensions now also follow an active 720p/2K source instead of being forced up to 1920×1080.

**State 20.11.2026: v12 = verified capture-device modes and white status.** Capture formats and exact frame rates are read
from the selected device. The app keeps only rates explicitly exposed by AVFoundation (24/25 are absent for UGREEN 15389),
uses the device's own exact duration timestamps, and verifies real UGREEN mode switches through active readback plus live
dimensions and delivered FPS. The statistics line stays white even while reporting degraded frame delivery.
The connected UGREEN 15389 passed 106/106 format/FPS combinations with active-state readback and live dimensions/rate:
10/20/30/50/60 FPS for 1080p and below, 10/20/30 for 2560×1440. An initial 14 misses were transition timing and all
passed when reset and tested in isolation. UGREEN's own documentation lists 2K@30 and 1080p@60.

**State 20.11.2026: v11 = capture-device controls and no Sony tether.** The Sony PTP/ImageCapture reader, Sony status bar
and unselected-Sony keeper have been removed completely, so Sony's official application retains remote-shooting control.
Clicking the video-input line opens the selected capture device's supported format and frame-rate choices plus supported
focus, exposure and white-balance modes. Format and frame rate choices are remembered per device.

**State 20.11.2026: v10 = live video-input statistics in the top bar.** When a camera and sound input are both active, a compact
line inside the dark input bar, immediately after the record key, shows the source frame's resolution, target frame rate, pixel format and dropped-frame
count. A live frame rate is added in amber when delivery is degraded. AVFoundation drop notifications and presentation
timestamp gaps are combined without double-counting. `GET
/status` exposes the same values as `feed.active`, `width`, `height`, `format`, `currentFPS` and `droppedFrames`.

**State 13.11.2026: v5 = vertical slice (built by GitHub, not yet seen by Marko).** v4 was the last Mac build; since v5 the
workflow `.github/workflows/build.yml` (from MANTRA_MANIFEST/workflows/mac-swift.yml; also makes the DMG the site needs) compiles on a push to main
and releases v<N> (app.zip + MantraWebcamRecorder-<N>.dmg) as Latest. Nothing compiles on the Mac.

**v7 (13.11.2026): choice on a click, wait for the same camera.** `app/ChoiceOverlay.swift`: a click on the picture (windowed or
full screen; Option-click is still the Sony touch focus) opens a see-through layer under the bar with CAMERA (each camera, then
"· vertical slice") and SOUND (inputs, No sound); the current one is green and ticked; a blob picks, a click outside or Esc closes.
Camera, overlay and API all go through `chooseCamera`/`chooseMic`. Never falls over: the chosen camera is kept by uniqueID and model
name (UserDefaults camera, cameraName); unplugged → "Waiting for <name>…" on black, `/status` "waiting": true; on wasConnected
the same id (or same model name, slice choice moved to the new id) restarts the session with its slice. Same for the sound input
("soundWaiting"). A take running at the disconnect is stopped and saved; `/status` lastTake + "interrupted": true until the next take.
Not run by me.

**v6 (13.11.2026): local HTTP API on 127.0.0.1:8867** (app/ApiServer.swift, Network.framework, loopback only; port also in
~/.mantra/ports/webcam-recorder). `GET /status` {camera, id, slice, recording, elapsed, lastTake, currentTake, fps, size, levels},
`GET /cameras`, `POST /camera {"name"|"id","slice"}` (the menu's own action, remembered), `POST /record/start {"name"?}` (title goes
after the mb_ stamp; 409 if already recording), `POST /record/stop` → {path, duration}, `POST /front`. Handlers call the same Viewer
functions as the record key, so file, HEVC, time code and slice are identical. The app must be running. Not run by me (no Mac compile/open).

**v5 (13.11.2026): vertical slice.** The camera menu lists every camera followed by "<camera> · vertical slice"; the Sony α7 V
(ILCE) is first, as in the classroom. Closed menu shows "▯ " + 6 letters for a slice entry (the 8-letter rule would otherwise show
the same text twice). `app/Slicer.swift`: the middle 9:16 of the frame at full height (3840x2160 → 1215x2160), Lanczos
(CILanczosScaleTransform, halved first if the source is over 2x too big) to 1080x1920, new CMSampleBuffer with the original time
stamps. The same buffers go to an AVSampleBufferDisplayLayer (preview, hidden when horizontal) and to the Recorder
(`vertical:` → HEVC 1080x1920, 10 Mb/s; audio, tmcd, mb_ name unchanged). The window turns portrait (9:16, height ≥720 and within
the screen) and goes back to its horizontal size; the choice is kept per camera (UserDefaults `slice.<uniqueID>`); a click on the
vertical picture is mapped into the strip for the Sony touch focus. Horizontal mode is untouched. NOT verified by running (nothing
compiled or opened on the Mac by order): first look = Marko's.
Sources of 1080 height are scaled UP to 1920 (the classroom never scales up; here the file size is fixed).

**1.11.2026, v2, released and published.** Renamed from Web Cam Viewer (Mantra) at Marko's word; bundle id kept.
Requests word for word in momentaryupdates.md: the sound input and the VU, the record key (mb_ file, H.265 1080p 10 Mb/s),
time code from the real-time clock (written into MANTRA_MANIFEST modules/timecode.md), the full-screen key with ⌘F and
Escape, the page on the domain, the Cloudflare secrets in the repository and the worker that updates the page.

**Verified 1.11.2026:** camera and microphone allowed by Marko. Selftest: FaceTime 30 fps moving; the take
mb_2026-11-01_06-42-05.mov was hevc hvc1 1920×1080 30/1 at 9.6 Mb/s, aac 48 kHz mono, tmcd 06:42:05:06 = the wall clock
of its first frame; sound mean −50.7 dB, peak −27.3 dB (the External Microphone in a quiet room). The test take was
deleted afterwards. Window screenshot: both menus and ● centred, corners key and ✕ right, the meter moving. Release v2
(0.6 MB DMG) → Site action success → https://mantrawebcamrecorder.pages.dev answers, the DMG 200, "↓ 0 downloads" shows;
card 21 / SNIMANJE in the bio's Kod tab, HR and EN.

**v3 (1.11.2026):** two VU hairlines, L and R, side by side on the left edge (per-channel RMS, interleaved or not); the
record key shows a see-through red (35 %) under the mouse. Checked by screenshot (`--hover-rec`) and pixels across the
meters (two 3-px greens, a gap). Released v3; the Site action puts it on the page.

**v4 (1.11.2026):** the Sony α7 V group in the bar (app/SonyBar.swift, SonyLink.swift, SonyCamera.swift: PTP 3 over
ImageCaptureCore; REC, battery, AF, F, shutter, ISO, name; touch focus from a click; time code jam on connect), grey while
the Sony is the USB Streaming picture. app/KeepStreaming.swift holds a Sony that is not chosen so it stays in Output;
`releaseNow()` before the picture opens it (Riverside showed the Sony while ours was black: both held it). Frame watchdog
(3 silent seconds → reopen, 8 → a message). Meters two 2-pt hairlines touching; full screen keeps meters and REC time.
build.sh deletes the per-arch binaries first, so a failed compile can no longer be reported "built". Sony streaming was
set to HD(720p) 25p (MJPEG): Marko told MENU → Network → Streaming → USB Streaming → Output Res/Frame Rate → 1080p.

**Not yet seen by Marko:** full screen (⌘F / Escape) and a take of his own with REC and the time code on screen.

**Code:** `app/App.swift` (start, flags, ⌘Q menu), `app/Viewer.swift` (window, bar, menus, capture session, recording
control, full screen, watchdog, selftest), `app/Recorder.swift` (VideoToolbox H.264 plus the OBS-style ffmpeg-mux pattern;
OBS local source commit 48b876374, ISC attribution in the file), and `app/Meter.swift` (StereoMeter and record controls).
`site/public` is the page (SEO by kits/seo, bowl, counters).

**Next:** check each capture card's exposed format and control list in real use. The page's banner and lifestyle pictures are real screenshots for now; Nano Banana renders of
the app in use replace them when made (page-pictures-nano-banana).
