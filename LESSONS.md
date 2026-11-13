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
