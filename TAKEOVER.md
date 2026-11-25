# TAKEOVER: Webcam Recorder (Mantra)

**State 25.11.2026: v30 = SYNC: every sound input on the camera's frame (phase 1 of docs/AVSYNC_PLAN.md).**
Marko (momentaryupdates.md): "It must be exactly in the same frame, the sound ... I can use any microphone." and, on the
plan, "We are not going to use paid Apple account for now ... Yes."
- **In every take:** the chosen sound input is moved by `sync.audioDelayMs.<audioUID>` minus `sync.videoDelayMs.<videoUID>`
  (the VIRTUALCAM_PLAN §7 keys) where Recorder places its first sample (AudioTrack in Recorder.swift). Seeded on first run
  from avsync.json (never over a value set by hand): RØDE NT1 +72.5, MacBook Pro Microphone +44.2, External Microphone
  +74.6 ms; UGREEN 15389 (A) is the reference, 0. Switching the sound input switches the value.
- **Camera scratch track:** while another input is chosen, a second capture session keeps UGREEN 15389 (A) open from
  launch (its start walk, LESSONS 48) and every take carries it as audio track 2 "camera scratch" (AAC 128k, not
  default); silence fills it if it stops, so it never stalls the take. `POST /sync {"scratch": false}` turns it off.
- **SYNC key** beside the sound menu ("SYNC +73" for 72.5; AX title SYNC, value "+72.5 ms"), opens a box: value, -10 -1
  +1 +10, RESET (back to the measured value), CLOSE, every stored value, picture delay. Escape closes it.
- **API:** `GET /sync`, `POST /sync {ms|delta|reset, uid|name?} | {audio:{uid,ms}} | {video:{uid?,ms}} | {scratch}`;
  /status has `sync` {audioDelayMs, videoDelayMs, appliedMs, scratch, take{audioShiftMs, corrections, jumps, driftMs, scratch}}.
- **Drift / jumps:** each buffer's stamp is compared with the sample count; > 1 ms smoothed = one sample dropped or repeated
  per buffer every 2 s check; two buffers > 70 ms off = placed again. Measured: the stamps carry no drift (0 corrections),
  so the real clock drift (RØDE vs camera −0.14 ms/min) is NOT corrected yet: v31 (arrival-time envelope, LESSONS 49).
- **Verified on the installed v30 (11:25-11:42, all via the API, RØDE as input):** check_take pass on first take after
  launch (8 s), LOW 10 s, slice HIGH 60 s and 240 s, kill -9 at 30 s (audio end +0.12 s of video end), max lag 0.0 s on all.
  `tools/check_sync.py` (new): chirp train from the ADAM, delay 0 → −72.04 ms, delay +72.5 → **+0.53 ms** (IQR 0.02);
  windows on his YouTube sound: 240 s take median +0.17 ms, 30 s blocks within ±0.3 ms; first take after launch +4.36 ms
  (camera sound still walking), +0.96 at 2 min, +0.42 at 3 min.
- **Not in v30 (v31):** AUTO MEASURE in the app (tools/avsync.py measures; the app reads avsync.json), drift correction from
  arrival times, the picture side of the camera sound (clap test, AVSYNC_PLAN §1.4: until then camera sound = picture),
  live delay line for VirtualCam/monitoring. The bar's minimum width grew from 917 to 958 pt (SYNC never cut).


**State 25.11.2026: v29 = no flicker in the vertical slice; (V)/(A) names; "30 FPS max"; capture mode follows a new USB id.**
Marko (word for word in momentaryupdates.md): the picture flickers "only ... in vertical slice", a strange square next to
UGREEN, "remove the slice from the name", "60 FPS max, 30 FPS max".
- **Flicker:** the sliced frames had no colour tags; the window showed them in two renderings (gain x1.123 / x0.890 between
  captures, 5 of 14 pairs on v28) while the take from the same buffers stayed within 0.2 %. Slicer.tagColour copies the camera's
  primaries/transfer/matrix (709 default) and the CGColorSpace onto every frame. v29: slice windowed 30 pairs mean 0.95 %
  (motion only, no x1.12 toggle), normal view 1.35 % (motion), slice full screen on a still scene 19 pairs max 0.2 %.
  check_take on an 8 s v29 take: pass (Y max step 0.54).
- **Names:** cameras "UGREEN 15389 (V)" and "UGREEN 15389 (V) 9:16", sounds "UGREEN 15389 (A)", bar "UGREEN (V)" /
  "UGREEN (A)" (popups 118 pt). Format menu "2560×1440 · 420v · 30 FPS max". Seen in captures of the opened menus.
- **Capture mode:** a camera with no remembered mode takes the one of the same vendor+product (the id's last 8 hex digits).
- **Not verified:** the migration path itself on the body (his mode was already saved under the new id before v29 started).


**State 25.11.2026: v28 = messages that no longer apply go away by themselves.** Marko: "So I asked you to open Sony Imaging
Edge remote, and it is opened up. It's already here. It's online, but the message is kind of persistent on the screen."
- **The stuck text** was the centre label "Opening Sony Imaging Edge Remote…" (Snap.swift): said when S opened Remote, never
  cleared after the snap succeeded. SnapRemote now owns its texts (tell/clear, Viewer's unsay clears only if the label still
  shows ours) and clears them when it snaps, unsnaps, Remote quits or Remote is opened from elsewhere; a Remote window that
  appears late (>20 s) is still snapped for 5 min. Proven on the installed v28: /snap with Remote closed showed the text at
  1 s, snapped at 1-2 s, text gone (screenshots v28_opening / v28_snapped in the session's scratchpad).
- **The Sony verdict** "The camera's Wi-Fi remote is open." + "read failed: Connection reset by peer" was false: a VPN 0/1
  route accepted every TCP connect (LESSONS 40). Ports count only when ping/ARP or SSDP answers; stage 4 says "answered, but
  not by the camera". Remote holding the cable: "Camera online, controlled by Imaging Edge Remote (USB). TAKE CONTROL closes
  Imaging Edge Remote and controls it from here." A 3 s cable watcher re-measures on any USB owner change and every 60 s
  (LESSONS 41). Proven: Remote quit → "Camera online on USB (ILCE-7M5), free. CONNECT controls it from here." in about 4 s;
  Remote reopened (it reconnected to the camera by itself) → the calm Remote text again.
- **Not verified:** the Wi-Fi road on the Mantra router (the Mac was on 10.200.102.x behind a VPN); camera control itself.


**State 21.11.2026: v23 → v27 = the sound is really in the take; the Sony diagnosis is honest; USB control road; updater.**
Marko: "It doesn't record the sound first ... It's on Wi-Fi, and the application says it's not on Wi-Fi. Please make it connect
to the camera and remotely control it." (word for word in momentaryupdates.md). Skill: ~/.claude/skills/webcam-recorder.
- **Sound (v23).** v13 to v22 wrote all of a take's sound in one block at Stop (a raw H.264 pipe has no time stamps and ffmpeg 9
  starved the audio FIFO; LESSONS 28), dropped the first 1.0 to 1.7 s (30), and had no default flags. Players that read in order
  (IINA, Resolve) lost the sound after 0.3 s. Now: FLV video tags with capture time stamps on the pipe, the FIFO opened on the
  writer queue, audio aligned to the first frame, default flags, SIGPIPE ignored. Verified on the installed app with
  tools/check_take.py: first take after launch 2560x1440 HIGH, LOW, 60 s and 240 s slice HIGH, UGREEN HDMI audio (2 ch), a take
  started right after switching the input, and a kill -9 at 30 s: every one max lag 0.0 s, audio end within 0.05 s of the
  video end, packets = expected (240 s: 11260 / 11258), decodes clean.
- **Warnings (v23/v24/v26/v27).** No sound buffers for 2 s, a format change, a write error, an input with no buffers at start,
  or only digital zeros for 3 s = red banner under the bar (its own wrapping line; it pushes the Sony overlay down) and
  `/status soundWarning`. Proven on v27: NDI Audio (zeros) → "the sound input sends only SILENCE (digital zero)" at 3 s,
  window captured with the Sony overlay open. The "no buffers" path is built but not fired on the body (no input does that).
- **Capture mode (v24/v25).** The remembered capture format (2560x1440 30) came back as 1920x1080 at every launch and after every
  sound-input change (session preset re-applied on each commit; LESSONS 36). Restored after each commit; checked on v25 by
  launch and by re-selecting the sound input.
- **Sony (v23/v24).** SONY / CONNECT and `GET /sony/status?check=1` measure five stages (Mac LAN, camera ping + MAC, SSDP,
  15740/22, USB + owner) and say only what was measured. Order: Wi-Fi PTP-IP if its port is open, else USB PTP through
  ImageCaptureCore (SonyUSB.swift) if the cable is free, else the stages; TAKE CONTROL (Marko's press) closes Imaging Edge Remote
  and connects over USB. API: /sony/status, check, connect, disconnect, takecontrol, rec {on}, prop?code=, set {code|name,
  value|label} (answer = camera read-back), /sounds, /sound.
  On the body 21.11.2026: camera 192.168.1.100 MAC 80:99:9B:13:AD:3F answers ping; 15740/22/64321/80/443 closed; no SSDP;
  USB ILCE-7M5 held by "pid 4939, Remote". **Not verified:** the USB road and every control against the body (connect, ISO,
  shutter, REC, READ SLOTS): it needs Imaging Edge Remote closed (TAKE CONTROL), which is Marko's decision. The Wi-Fi road
  needs MENU → Network → Cnct./Remote Sht. → Remote Shoot Function → Remote Shooting: On with the cable out or Remote closed
  (whether the body opens 15740 then is not yet seen).
- **Updater (v23).** Updater.swift (kits/mac-updater), checkAtStart at launch, repo web-cam-viewer.
- **Old take repair (not run):** `ffmpeg -i in.mkv -i in.mkv -map 0:v -map 1:a -c copy -disposition:v:0 default
  -disposition:a:0 default in_fixed.mkv` (LESSONS 32; a plain -c copy keeps the lag).


**State 20.11.2026: v13 = crash-safe H.264 MKV quality recording.** Record now writes the final Matroska file from the
first frame through an OBS-style ffmpeg-mux helper path. VideoToolbox creates H.264 packets at the live feed's exact
dimensions and delivered FPS; ffmpeg packet-copies video and muxes AAC audio into one-second MKV clusters. LOW / MID / HIGH
beside Record use 10 / 25 / 50 Mb/s at 1080p30 and scale by pixels × delivered FPS; the key also shows free-space minutes.
Hard-killing the app during recording left a decodable H.264/AAC MKV.
Final disk verification: on the live 1920×1080 20 FPS UGREEN feed, LOW/MID/HIGH targets were 6.67/16.67/33.33 Mb/s and
their five-second files were Matroska + H.264 High/yuv420p + AAC, exactly 1920×1080 and 20.0 FPS, with all frames decoded.
The static-scene CBR files measured about 5.84/14.83/29.87 Mb/s at the video-plus-overhead probe (about 10% below target).

**State 21.11.2026: v22 = the current key is marked for sure.** In the v21 demo test the green bezel of the current Picture Profile key (and AEL ✓) was not redrawn in an inactive window; v22 marks the current one with a green border and green title (accessibility value "current").

**State 21.11.2026: v21 = the SONY key (our own PTP control of the α7 V).** Marko: "I need to have button Sony control, and all its icons and pop up menus you overlay over my image ... and I can change all the settings inside my own window, not digging through the sub menus." He chose our own PTP route (no Imaging Edge window, no stolen mouse). The bar now has SONY beside F and S (green "SONY ●" while connected); a click toggles a see-through overlay under the bar (never over it, Escape or HIDE closes; open/closed is remembered as `sony.overlay`, and a remembered open overlay finds the camera again at start). Option-click on SONY, or `--sony-demo`, opens it on the built-in demo camera.
The overlay, top to bottom, all native AppKit, all wrapping with the window width and scrolling: CONNECT / address field (saved `sony.ip`; empty = SSDP) / DEMO / HIDE and the status; the Access Authentication fingerprint, USER, PASSWORD and SAME AS CAMERA · CONNECT when the camera asks (password in the login Keychain, service "Webcam Recorder (Mantra) Sony camera"; host key in ~/Library/Application Support/Webcam Recorder (Mantra)/sony_known_hosts); PICTURE PROFILE big: PP1, the slot the camera reports as S-Log3 / S-Gamut3.Cine, a pop-up of every slot, READ SLOTS; CAMERA BUTTONS: REC (movie button 0xD2C8, toggle 0xF001 fallback, confirmed by 0xD21D), AEL 0xD2C3, FEL 0xD2C9, AWBL 0xD2D9 (Down then Up; ✓ from the lock indications); facts (REC/STBY, battery, card time, how many settings are settable); SETTINGS cards for exposure program, shutter, F-number, ISO, EV, white balance, Kelvin, DRO, metering, focus mode, focus area, still file format, image size, RAW type, compression format, Creative Look, gamma, color mode, Position Key (PC Remote priority); then EVERY OTHER SETTING THE CAMERA OFFERS (every GetSet=1 property it reports). Each card shows the camera's current value; enumerations are pop-ups of the camera's own "Set" list, ranges are − value +; grey when the camera says not now (IsEnabled 0/2) or read only.
Code: app/SonyNet.swift (bytes, TCP, SSDP on every LAN interface), SonyPtp.swift (PTP-IP, SSH tunnel, Keychain; moved from SONY_REMOTE_MAC, which stays untouched), SonyProps.swift (full 0x9209 parser and writer, labels), SonyCatalog.swift (codes and value names generated by tools/sony_catalog.py from the reference PDF on the Mac, labels only), SonyLink.swift (session, 0.5 s poll, 0x9205 set and read back, 0x9207 buttons, REC, Picture Profile slots), SonyDemo.swift (pretend camera behind the same PTP calls), SonyPanel.swift (the overlay). No live view over Wi-Fi: the picture stays the HDMI capture.
Picture Profile slots are never guessed: gamma 0xD0E1 and color mode 0xD0E9 describe the slot selected in 0xD23F, so a slot is learned when it has been current for a second, or by READ SLOTS (each offered slot in turn, then the one before is put back; refused while recording). Learned slots are remembered per model (`sony.slots.<model>`). The S-Log3 key reads "S-Log3: READ SLOTS first" until one is known.
Discovery: SSDP on every IPv4 interface except tunnels, then the saved location, then http://<saved address>:64321/dd.xml, then direct ports 15740/22 at the saved address. The Mac must reach the camera through the Mantra router (192.168.1.x; the Nothing hotspot isolates clients). `--sony-selftest <file>`: parser round trip and labels on the demo dataset, no window.
**Verified:** only the GitHub build and the demo (see the v21 lines in LESSONS). **Not verified:** anything against the real camera; on 21.11.2026 it was not on the network (Mac on the Nothing hotspot 10.55.2.x, no SSDP answer, Mantra router off). First real test: camera Wi-Fi on "mantra", Remote Shooting On, Mac on the Mantra router, SONY → CONNECT, then READ SLOTS.

**State 21.11.2026: v20 = F is a folder picker.** Marko: "I need to pick the folder" (the F click only opened the folder in his file manager). A click on F now pops a small menu under it: "Choose folder…" (the system folder panel, remembered as `recordFolder`) and "Show the folder in Finder". The name beside F updates at once.

**State 21.11.2026: v19 = folder name on the bar.** Marko: "Next to folder, give me the name of the last folder, not the whole path." The F key shows the last component of the recordings folder (e.g. Movies) before its icon; the tooltip has the full path; it updates when the folder is chosen.

**State 21.11.2026: v18 = remembered state, no "Sony camera not found".** Marko: the "Sony camera not found / press ENABLE" text annoyed him (he works through a UGREEN HDMI-to-USB adapter, the camera is fine): all camera hints in Snap.swift are removed. "The whole state should be remembered": the recordings folder is now chosen (right-click or Option-click F → Choose folder…) and remembered (`recordFolder`, default ~/Movies; used by Record and the free-space time); snapped state is remembered and restored at the next start if the remote is still open (`snapped`; never opens the remote by itself). Already remembered: window frame, camera, sound, quality, capture format and rate per device.

**State 21.11.2026: v17 = S and F beside full screen.** Marko: "Snap should be the small button next to the full screen button" and "Next to S I need F; F is giving me the folder where I'm recording my videos." The bar's right side is now: PERMISSIONS (when needed), F (folder icon, opens ~/Movies with the newest take selected), S (snap icon, green while snapped), full screen, ✕. The SNAP REMOTE text key is gone from the left group.

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
(0.6 MB DMG) → Site action success → https://webcamrecorder.markobosko.org answers, the DMG 200, "↓ 0 downloads" shows;
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
