# LESSONS: Web Cam Viewer (Mantra)

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
