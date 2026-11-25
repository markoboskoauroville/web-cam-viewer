# LESSONS: Webcam Recorder (Mantra)

1. **The camera list has no fixed order inside an app (1.11.2026).** `AVCaptureDevice.DiscoverySession(...).devices`
   came back FaceTime first from the terminal but NDI first in the app, so the window opened on a black virtual camera.
   Sort it yourself: the built-in camera first, then by name.
2. **A selftest must not change what the user chose.** Walking every camera through the menu's own action saved the last
   one as remembered; the test selects directly instead.
3. **The app cannot photograph its own window** without Screen Recording permission; the screenshot is taken from the
   terminal with `screencapture -l <window id>` after a `--quiet` start (no focus taken, MacBook Pro screen).
4. **Continuity Camera needs `NSCameraUseContinuityCameraDeviceType`** in Info.plist, or AVFoundation warns and leaves
   the iPhone out.
5. **`kVTProfileLevel_HEVC_Main_AutoLevel` needs `import VideoToolbox`**; AVFoundation alone does not bring it in.
6. **A time code track with AVAssetWriter:** a `.timecode` input with a TimeCode32 description, one 4-byte big-endian
   sample (frames since midnight) at the first video pts, `markAsFinished` right after, and the video input's
   `addTrackAssociation(withTrackOf:type: .timecode)`. ffprobe then shows `tmcd` and the same `tag:timecode` on the video.
   Fragmented writing (`movieFragmentInterval` 1 s) keeps it.
7. **The capture time stamps are the host clock.** The wall time of a frame is now − (host now − pts); that, not the
   moment the key was pressed, is the time code's start.
8. **Set the camera to a whole frame rate** (lockForConfiguration, min = max duration 1/30) so the frame-counting time
   code does not drift from the clock.
9. **The α7 V cannot stream and be controlled at once (1.11.2026).** USB Streaming offers UVC video + audio only, and its
   UVC Camera Terminal and Processing Unit control bitmaps are both 0 (read from the descriptor with libusb): no exposure,
   focus or zoom over UVC. PTP needs USB Cnct Mode = Remote Shoot/Trn., and the Help Guide p.416 switches off Wi-Fi remote
   and Bluetooth while streaming. Full picture + control = HDMI capture for the picture, USB Remote Shoot for control.
10. **Two capture sessions on one camera = a black picture (1.11.2026).** The keeper that held the Sony in Output and the
    picture's session both opened it; the picture got no frames. The keeper must release (and its queue drain) before the
    picture opens the device, and a watchdog must reopen a camera that goes silent.
11. **USB Streaming has no start key.** Standby until an app on the computer opens the camera, Output while one does, ends
    only on unplugging (Help Guide p.415). The Mac can only request MSC mode (0xF012), so it cannot switch the camera into
    streaming. Holding the device open is the only "keep streaming".
12. **A build script must not trust stale binaries.** build.sh lipo'd old per-arch files after a failed compile and said
    "built"; delete them first and check both exist.
13. **macOS has no `AVCaptureSession.Preset.inputPriority`** and no ICDeviceBrowser `controlAuthorization`: use
    hd1920x1080 when `canSetSessionPreset`, and skip the authorization call.
14. **The streaming resolution is set in the camera**, not by the app: the α7 V at HD(720p) 25p offers only 1280×720 MJPEG.
15. **Closed popup shows 8 letters (v5):** "<camera> · vertical slice" and "<camera>" are the same eight letters, so the cell draws
    slice entries as "▯ " + six letters (ShortPopUpCell).
16. **Slice = new sample buffer with the old time stamps (13.11.2026).** Crop + Lanczos in Core Image into a pooled 1080x1920
    BGRA buffer, CMSampleBufferCreateReadyWithImageBuffer with the camera's timing; the recorder's time code and the audio
    need no change. The display layer needs DisplayImmediately on each buffer (no timebase). No Mac compile: GitHub only.
17. **A GitHub-made release must carry the DMG** (the Site action runs on "release published" and needs exactly one .dmg):
    build.yml creates the release with app.zip and the DMG in one call; make_dmg.sh and build.sh honour SIGN=- (runner).
18. **API = the same functions as the UI (v6):** ApiServer only parses HTTP and hops to the main queue; start/stop/camera call
    startRecording/stopRecording/applyMode, so a take from the API cannot differ from one made with the key. Loopback is enforced
    with requiredLocalEndpoint 127.0.0.1. Releases made with the workflow token do not trigger Site: dispatch it after.
19. **A chosen device is an identity, not a list position (v7):** v6 fell over to FaceTime when the Sony was unplugged because
    refresh() took index 0 when the remembered id was missing. Keep the id and the model name, wait, never substitute; the
    same for the microphone. A click that must open a menu steals the old click (touch focus): the old one moved to Option-click.
20. **Video drops can be inferred but must not be counted twice (v9):** `AVCaptureVideoDataOutput` may report a dropped
    sample and the next sample's presentation stamp may also reveal the same gap. Count the reported frames first, then
    add only the excess missing from the timestamp gap. Actual FPS is measured from delivered frames per monotonic second;
    resolution and format come from the live pixel buffer, not from the recording settings.
21. **A “record then remux to MKV” path is not crash-safe (v13):** the final MKV must exist from the first sample.
    OBS's ffmpeg-mux pattern uses a helper process and continuously flushed clusters; VideoToolbox encodes H.264 and the
    helper packet-copies it into Matroska with AAC. A hard-kill test, not a graceful stop, proves recoverability.
22. **Pipe writes cannot run on the capture queue (v13):** audio filled a FIFO and starved video capture before VideoToolbox
    could submit frames. OBS-style I/O belongs on a separate writer queue; the app validates output dimensions, frame count,
    duration, codec, pixel format, bitrate and decode from the disk file.
23. **Picture Profile gamma and color mode belong to the selected slot (v21).** Sony's 0xD0E1 / 0xD0E9 describe "the Picture
    Profile selected in Picture Profile" (0xD23F); there is no read-out of another slot. Which slot holds S-Log3 /
    S-Gamut3.Cine is therefore learned only while that slot is selected (passively after one second, or READ SLOTS walking the
    slots and putting the old one back). A slot number is never assumed from factory defaults.
24. **A property can be offered and still be refused (v21).** GetSet = 1 means the Mac may set it in principle; IsEnabled 0
    (greyed) or 2 (display only) means not now; exposure program needs Position Key Setting 0xD25A = PC Remote priority (Sony's
    own example sets it first). SDIO_SetExtDevicePropValue answers OK even when the camera keeps its value, so every set is
    read back (up to 1.5 s) and the overlay shows what the camera reports, not what was asked.
25. **SSDP must ask on every interface (v21).** With the default route on the Tailscale exit node or the Nothing hotspot, a
    multicast M-SEARCH leaves on the wrong interface and the camera on the Mantra router's 192.168.1.x never hears it.
    IP_MULTICAST_IF per IPv4 interface (utun excluded), plus the saved address, finds it on whatever LAN route exists.
26. **A demo camera behind the same PTP calls (v21).** SonyDemo answers OpenSession, SDIO_Connect, 0x9209, 0x9205 and 0x9207 in
    the real dataset format, so the parser, the set/read-back loop and the overlay are exercised without the body;
    `--sony-selftest` checks the write/parse round trip and the labels (F4, 1/50, 2.5", ISO AUTO, −0.7 EV, S-Log3).
27. **bezelColor is not a state marker (v22).** A rounded NSButton's bezelColor set after the window was shown did not redraw
    while the window was inactive (the demo test window never takes focus), so the current Picture Profile looked unmarked.
    A layer border plus a coloured attributed title shows the state in every window state.
28. **A raw H.264 pipe starves the sound in ffmpeg 9 (v13 to v22, found 21.11.2026).** Annex B on stdin has no time stamps;
    with a second input (PCM in a FIFO) ffmpeg 9's scheduler stopped reading the FIFO until the video ended, so the whole
    take's sound was written in one block at Stop behind the video (60 s take: 50 s lag; Marko's 237 s take: 227 s). ffmpeg
    decodes such a file, so `volumedetect` said "sound present" and the bug hid; IINA and DaVinci Resolve read in file order
    and lost the sound after 0.3 s, and a crash would have lost all of it. Proven in a stand-alone simulation (the app's exact
    ffmpeg line fed in real time): raw H.264 → 9.9 to 19.9 s lag, one FIFO write blocked 17.8 s; the same video in MPEG-TS or
    FLV → lag 0.0. `-fflags +genpts`, a small probe or `-max_interleave_delta` do not help. Fix (v23): the app writes FLV tags
    (avcC sequence header, AVCC frames, the capture clock's millisecond stamps) to the pipe, `-f flv -i pipe:0`.
29. **Never judge a take's sound by decoding it; check it in file order.** `tools/check_take.py <take>`: max lag (newest
    video pts written so far minus each audio packet's pts, in file order) ≤ 1.0 s, audio length = video length, packet
    count vs 1024-sample AAC packets expected, default flags, levels. Every version that touches Recorder runs it on a 60 s
    and a 240 s take in slice + HIGH, plus a hard kill at about 30 s.
30. **The FIFO open must be on the writer's own queue (v23).** v22 opened the audio FIFO on another queue and dropped every
    PCM buffer that came before ffmpeg had opened it (ffmpeg probes input 0 first): the first 1.0 to 1.7 s of sound were lost
    (worst at LOW: the video pipe fills the probe slowest) and the sound started early against the picture. Now the open is
    the first block on the writer queue, later writes wait behind it, and the first sample written is the one at the first
    video frame's time (cut before it, silence if the sound starts later).
31. **A take must say when its sound is missing (v23/v24, silent-failure.md).** No buffer for 2 s, a format change in the
    middle, a write error, or a sound input chosen but no format yet (the start waits up to 1.5 s for the first buffer) =
    a red banner under the bar and `/status soundWarning`. The bar's statistics key is clipped in a narrow window (it showed
    only "2" at 883 pt), so a warning never relies on it: it has its own wrapping line.
32. **A remux with `-c copy` does not repair a badly interleaved MKV.** It reads in file order, so the 10 s interleave limit
    leaves the lag (9.86 s on the simulated file). Read the file twice: `ffmpeg -i in.mkv -i in.mkv -map 0:v -map 1:a -c copy
    -disposition:v:0 default -disposition:a:0 default out.mkv` → lag 0.0 (tested on the simulated broken file).
33. **"Not on Wi-Fi" was a lie by omission (v22, 21.11.2026).** The camera answered ping at 192.168.1.100 (MAC
    80:99:9B:13:AD:3F, the same as its MENU → Network → Wi-Fi → Display Wi-Fi Info.), but 15740, 22, 64321, 80 and 443 were
    closed and no SSDP came, because its remote control was on the USB cable: IOKit showed the PTP interface (class 6) with
    `UsbExclusiveOwner = "pid 4939, Remote"`. One "not found" hid all that. Now SonyDiag measures five stages (Mac LAN; ping +
    ARP; SSDP; 15740/22; USB + owner) and says only what it measured.
34. **One program holds the camera's USB PTP at a time.** Imaging Edge Remote takes the interface exclusively; ImageCaptureCore
    in our app then cannot open a session. The app never closes Remote by itself: TAKE CONTROL (Marko's press, or POST
    /sony/takecontrol on an explicit request) asks Remote to quit like its own Quit, then connects over USB. SNAP opens Remote,
    so while SONY holds the cable S says "DISCONNECT first" instead of opening a Remote that would meet a busy camera.
35. **α7 V menu names are not the old ones (ILCE-7M5 Help Guide, helpguide.sony.net/ilc/2540, 21.11.2026).** Wi-Fi remote:
    MENU → Network → [Cnct./Remote Sht.] → [Remote Shoot Function] → [Remote Shooting] → [On], with MENU → Network → [Wi-Fi] →
    [Wi-Fi Connect] → [On]; credentials MENU → Network → [Network Option] → [Access Authen. Info]; USB: MENU → Setup → [USB] →
    [USB Cnct Mode (PORT1)] → [Remote Shoot/Trn.]. There is no "PC Remote Function" / "PC Remote Cnct Method" on this body.
36. **startRunning applies the session preset over a saved format (macOS).** activeFormat set before startRunning with the
    preset hd1920x1080 came back as 1920x1080 at every launch, so Marko's remembered 2560x1440 was lost on each relaunch
    (it was right only after he picked it while running). v24 put it back after startRunning, and it still came back
    1920x1080: EVERY later commitConfiguration re-applies the preset, and the sound input is added after the camera (proven
    on v24 through the API: /capture 2560x1440 → /sound same input → 1920x1080). v25 restores the saved format after each
    commit (reapplySavedCapture). Test a restore by relaunching and by re-selecting the sound input, not by one launch.
37. **"Buffers arrive" is not "sound arrives" (v26).** NDI Audio with no source delivers buffers of exact zeros: the v23
    no-buffer check stayed quiet while the take recorded -91 dB. Exact digital zero for 3 s is now a warning; a real
    microphone always has a noise floor (about -45 dB in his room), so a quiet room never triggers it. Prove a warning by
    making it fire on the installed app (an input that sends zeros) and capturing the window, not by reading the code.
38. **A new overlay element must be checked against every other overlay (v27).** The v26 sound banner sat on the Sony
    overlay's CONNECT row when both were open. Capture the window with every overlay open together; the banner now pushes
    the Sony overlay down by its own wrapped height.
39. **Every centre text needs an owner that takes it away (v28, 25.11.2026).** S said "Opening Sony Imaging Edge Remote…"
    and attach() succeeded, but nothing cleared the text: it stayed over the picture for the whole session while Remote was
    open and snapped. A class that puts text on the shared message label now remembers it (tell) and clears only its own
    text (unsay compares the label) when the state it describes ends: snapped, unsnapped, Remote quit or opened elsewhere.
40. **An open TCP port is not a camera behind a VPN (v28).** A VPN with a 0/1 route (utun99) accepted every TCP connect, so
    15740 and 22 at 192.168.1.100 (and at any address, e.g. .123) "opened" while the Mac was on 10.200.102.x and the camera
    answered no ping and had no ARP entry. The verdict said "The camera's Wi-Fi remote is open" and the connect died with
    "read failed: Connection reset by peer". Trust a port only when the host itself answers (ping/ARP) or SSDP; a control
    probe on a random address (`nc -z 192.168.1.123 15740`) shows the fake at once.
41. **A verdict measured once goes stale (v28).** The Sony diagnosis of 08:05 stood at 08:20 after Imaging Edge Remote had
    changed. While not connected, the cable is now read every 3 s (IOKit only); a change of the Sony's USB owner (Remote
    opened or closed) re-measures every stage at once (seen: about 4 s after Remote quit and after it reopened), and a
    non-idle verdict older than 60 s is measured again. Remote holding the camera is the normal state: say it calmly
    ("Camera online, controlled by Imaging Edge Remote (USB)"), never as an error.
42. **Untagged frames flicker on the display (v29, 25.11.2026).** The sliced BGRA frames (Slicer, CIContext with null colour
    spaces) carried no colour attachments. AVSampleBufferDisplayLayer showed the same frames in two renderings, a gain of
    exactly x1.123 / x0.890 between window captures (5 of 14 pairs), while the recorded take of the same buffers moved 0.2 %
    at most. Normal view (AVCaptureVideoPreviewLayer, tagged camera buffers) never did. Every frame we make ourselves gets the
    source's primaries / transfer / matrix (Rec. 709 default) and its CGColorSpace. Measure flicker motion-robustly: the mode of
    the per-pixel brightness ratio between consecutive captures (static background wins), never a mean while someone moves.
43. **A camera's id can change with the USB port (v29).** 0x22000002b895389 became 0x2130002b895389: the location half
    changed, vendor+product 2b89:5389 (last 8 hex digits) did not. The remembered capture mode is copied over by that tail.
44. **Menu text: plain letters, never a symbol glyph (v29).** "▯" for the slice read as a broken-font square. Tags are (V) and
    (A); the vertical picture is "(V) 9:16". Selection is by index and id, so titles can change freely.
45. **POST /fullscreen moves the window to the first screen (the BenQ).** To give Marko his full screen back on the MacBook,
    move the window there and press the window's own Full screen key (`macro ax-press ... "Full screen"`). ax-press cannot
    press a key that pops a menu (AX -25204): open it with a real click at its AX position inside `guard run`.
46. **The sync delay is one number per sound input, applied where the sound is placed (v30, 25.11.2026).** The α7 V's own
    HDMI sound (UGREEN 15389 (A)) is the reference; every other input is moved by `sync.audioDelayMs.<uid>` (minus the
    camera's `sync.videoDelayMs.<uid>`) in the first-sample placement: position = (pts + shift − first video pts) × rate.
    No change to the FLV pipe, the FIFO order or the flags (LESSONS 28-31 hold: check_take max lag 0.0 s on every v30 take).
    Proof on the installed v30 with chirps from the ADAM, RØDE vs the camera scratch in the same take: delay 0 → −72.04 ms
    (IQR 0.01, 25 chirps); delay +72.5 → +0.53 ms (IQR 0.02, 17 chirps).
47. **A third ffmpeg input (the camera scratch FIFO) interleaves fine, but must never be able to stall the take.** Tried
    offline first (FLV + two PCM FIFOs, 20 s, max lag 0 on both tracks). In the app a scratch input that sends nothing is
    filled with silence up to 1 s behind the picture, so ffmpeg never waits on it (`padded` in /status sync.take).
48. **The camera sound walks for minutes after its stream opens, so keep it open from launch (v30).** RØDE vs camera in
    takes after a launch: +4.36 ms at 0-1 min, +0.96 ms at 2 min, +0.42 ms at 3 min, +0.15 ms at 5-9 min (AVSYNC_PLAN
    §1.1, seen again inside real takes). The scratch session holds UGREEN 15389 (A) from launch while another input is chosen.
49. **The capture stamps carry no clock drift (v30).** Every buffer's pts matched the sample count exactly (`driftMs`
    0.00 and 0 corrections in every take, 8 s to 240 s), so a stamp-based drift correction does nothing for these inputs:
    their drift against the host clock (UGREEN/Apple −3 ppm, RØDE −0.7 ppm, RØDE vs camera −0.14 ms/min) is only seen in
    the arrival times. Correcting it needs the arrival-time envelope (avsync.py clocks) = v31. In a 240 s take the residual
    stayed within ±0.3 ms per 30 s block (trend −0.11 ms/10 min).
50. **Judge a take's sync from the take itself: `tools/check_sync.py`.** Track 1 (the chosen input) against track 2
    (camera scratch): chirps when present, else 1 s windows of any sound over −40 dBFS (music worked: IQR 0.15-0.24 ms).
    Quiet windows (room noise, −47 dBFS) gave false peaks of ±100-200 ms before the level gate: never trust a low-level window.

51. **The RØDE NT1 5th Gen has a real input gain on the Mac (v31, 25.11.2026).** Core Audio input scope, main element:
    VolumeScalar and VolumeDecibels both settable, range 0…60 dB (read-only probe first: at 13:38 it stood at 60 dB, by
    13:46 Marko had put it to 0 dB himself in Audio MIDI Setup). Setting it moves the take by about the set dB (measured
    in takes with pink noise from the ADAM: 20 → 30 dB = +10.5 dB mean, +10.7 dB max; the camera scratch unchanged within
    0.2 dB). So GAIN uses the device first, like the CQ's gain knob (0 dB in the app = the device's top), digital only for
    what the device cannot give. A device without one gets all of it digitally, in AudioTrack's PCM and in the meter.
    Never write a device's volume unless a value is stored for it (gain.dB.<uid>) or Marko moves it: a new version must
    not change his device by launching.
52. **The RØDE's 32-bit float is real headroom, all the way into the buffers (v31).** Stream format f32 mono 48 kHz (24-bit
    int and 96/192 kHz also offered); AVCaptureAudioDataOutput with no settings delivers the floats as they are: at 60 dB
    with loud noise the buffers held samples to ±2.26 (+7.1 dBFS, 11183 samples over 0 dBFS in 12 s). An AAC take holds
    them at 0 dBFS (our guard; AAC decode -0.3 dBFS), a 32-bit float take (pcm_f32le in MKV) kept +7.1 dBFS: nothing
    clips, the level can be lowered later. Cost: 0.69 GB per hour mono, 1.38 GB stereo at 48 kHz.
53. **AUTO GAIN is one module: the Sound Recorder's Gain Assistant (MANTRA_SOUND_RECORDER app/Audio.swift
    toggleAutoGain/stepAutoGain, 31.10.2026, the CQ MixPad's "Auto Gain Steps").** Same numbers: wake above -45 dBFS,
    15 s for sound, the loudest peak to -12 dBFS, rounds until within 1.5 dB, 8 rounds, 0.3 s to settle. Only the first
    measuring window is 5 s (Marko plays at his loudest), the checks 2 s. Measured on the RØDE with ADAM chirps: -30 →
    -15 dB in one move, confirmed -11.9; the take of the same chirps peaked at -12.2 dBFS. The peak is measured after the
    digital gain and unclamped, so a clipped float input is seen as it is (the Sound Recorder could not see above 0).
54. **A second click on an NSPopUpButton item is just its action with the same item.** Choosing the already chosen sound
    input called selectMic again, which also STOPPED a running take (v30 and before). v31 opens the GAIN box instead.
55. **The UGREEN 15389's 2560x1440 is 1920x1080 stretched by the card, and its 420v modes are compressed (25.11.2026).**
    Marko saw "rigid coarse pixels" in a 2560x1440 HIGH take (89 Mbps). Measured with the same moment through three roads:
    OBS 33 (mac-avcapture, YUY2 2560x1440, x264 CRF 0 4:4:4) has EVERY row 4k+1 identical to row 4k (100 %, mean step
    0.000) and columns 4k+1 nearly so (mean step 0.82 vs 3.1): 1080 lines and 1920 columns repeated to 1440/2560, so
    every diagonal edge gets a step every third pixel. The 1440 frame is rebuilt from its own 1920x1080 subset at
    50.3 dB. The app's take of the same moment matches OBS at 48.1 dB luma PSNR and ffmpeg's raw card frames at 51.2 dB
    (the encoder at QP 19-21 adds nothing visible; the same raw frames through h264_videotoolbox CBR 86 Mbps: 53.7 dB).
    The card's 420v device formats (1080 and 1440) carry 8x8 block edges (boundary step 1.8-1.9x the others) and half
    the fine detail (mean gradient 1.0-1.1 vs 2.2-2.3): its internal compressed road. 1920x1080 YUY2 (yuvs) at 30 or 60
    has no periodic structure at all (period-4/8 strength 0.06-0.12 vs 0.7-0.9 at 1440). Best mode on this card:
    1920x1080 · yuvs · 30 or 60. Not the app (no fix in code); the period-4 measure: mean |step| per x mod 4.
    Note: ffmpeg's avfoundation input picks the 420v device format for 2560x1440 and LOCKS the device, which changes the
    app's live format; put it back with POST /capture afterwards. OBS holding the card locks ffmpeg out.

56. **OBS's camera extension counts the FIRST feeder, not the last (v32, 25.11.2026).** Read in its source
    (plugins/mac-virtualcam/src/camera-extension, OBS 33): `authorizedToStartStream(for:)` only stores the client;
    `startStream()` (which starts the 180 Hz timer that consumes that client's queue) runs once, when the sink starts.
    A second feeder while we feed changes nothing (tools/vcam_rival.py: the reader kept our 30 pictures/s). A feeder
    that was there FIRST keeps the sink: our CMSimpleQueue (capacity 10) is then never read; VCAM sees it full for
    0.5 s and says so (ownerConflict, red note), and the reader gets no frames at all. After that feeder stops, the
    extension still reads nobody until VCAM is turned off and on (measured). So "never fight" = never restart by itself;
    VCAM off/on is his hand. OBS's own Start Virtual Camera behaves like the rival (it is just another client).
57. **Never hold capture buffers in a delay ring: convert first, hold our own (v32).** The capture queue hands VCAM a
    retained 420v buffer (at most 2 in flight, else the frame is skipped and counted `converterBusy`); a separate queue
    fits it into a BGRA 1920x1080 IOSurface from our own pool (allocation threshold = the ring cap), and only those are
    held. Memory: 8.3 MB per held frame (200 ms at 30 fps = 6 frames, 47.5 MB measured; cap 400 ms = 79 MB at 30 fps).
    Takes with VCAM on passed check_take exactly as with it off (max lag 0.0 s, 0 capture drops).
58. **Core Image: 42 composited squares cost ~40 ms a frame.** The test stamp first made 42 CIImage composites per frame:
    convert went to ~40 ms, 20 % of the frames were skipped and the path showed 115 ms. One 42x1 bitmap scaled 24x with
    `samplingNearest()` costs nothing measurable (convert 7-9 ms at 2560x1440 → 1920x1080 Lanczos, 2 ms at 720x480).
59. **Where the video latency is (v32, measured with the stamp read back by tools/vcam_check.py):** capture stamp → our
    delegate 52-55 ms at 2560x1440 30 (the UGREEN + AVFoundation, before any app code; 15 ms at 720x480 60), our
    convert 7-9 ms, extension + reader 4-7 ms: a new picture reaches a reader 69-71 ms after its capture stamp (p95 90 ms).
    The capture stamp is on the host clock (the reader's delivery = arrival − PTS = 2-6 ms), so the audio side can
    plan against it. A hold is added on top of capture + Pv: +100 → +103.6 ms, +200 → +203.0 ms at the reader, and the
    spread shrinks (p95 − median 20 ms → 12 ms) because the arrival jitter is taken out.
60. **The sink stays 60 fps by repeats only in the input's gaps.** A fresh frame goes out at once; a repeat only when 16 ms
    passed and the next picture is not due within 8 ms (else 30 fps in made 68 buffers/s). Measured at the reader:
    57-60 buffers/s, 30.0 distinct pictures/s from a 30 fps camera (counted by stamp; a sparse-pixel signature
    undercounts a still scene: 25/s). CPU of the app: 19 % without VCAM, 32-35 % with it, plus ~5 % in the OBS extension.
61. **A raw microphone in Zoom cannot be synced by delaying the picture (25.11.2026).** The RØDE is +72.5 ms (its sound
    is EARLIER than the camera's frame), and the VCAM picture adds ~64 ms of its own path: in Zoom its sound leads the
    picture by roughly 130 ms less Zoom's mic latency. Delaying the picture "by the mic's SYNC value" would double the
    error. The picture is held only for a mic that is LATER than the camera (negative value); an early mic needs its
    sound held, which only the app's own microphone (Mantra VirtualCam, the audio path) can do.
62. **Do not leave a test state on the live path.** A slice test left VCAM sending the 9:16 picture pillarboxed while
    Marko joined a Zoom call on it (and a ZZTEST take was running in front of him). Before a test that changes what
    VCAM sends, check that no one reads OBS Virtual Camera (zoom.us running = assume he is in a call), and put the
    picture back the moment a test ends.
