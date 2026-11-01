# TAKEOVER: Web Cam Viewer (Mantra)

**1.11.2026, v1.** Built from Marko's request (momentaryupdates.md): a simple Swift client showing any webcam, a menu at
the top, ✕ to close. During the build he asked for the bar to lie half see-through over the picture with the menu in the
top middle, not taking any viewing area: done in v1.

**State:** installed, star row in Mac (STAR_SWIFT rows.json). Camera permission allowed by Marko 1.11.2026. Selftest:
FaceTime HD 86 frames in 3 s, moving; Iriun 4 frames (the phone app was not sending); OBS and NDI Virtual Camera 179
frames, still (their placeholder, no source running). Window screenshot checked: picture full window, bar over it.

**Code:** `app/App.swift` (start, flags, menu for ⌘Q), `app/Viewer.swift` (window, bar, AVCaptureSession with an
AVCaptureVideoPreviewLayer, aspect fit; device notifications; selftest frame difference). `icon/make_icon.swift` draws
the webcam icon with the version.

**Next:** Marko's look in use. Ideas only if he asks: hide the bar until the mouse moves, full screen on double click.
