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
