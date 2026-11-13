# TAKEOVER: Webcam Recorder (Mantra)

**State 13.11.2026: v5 = vertical slice (built by GitHub, not yet seen by Marko).** v4 was the last Mac build; since v5 the
workflow `.github/workflows/build.yml` (from MANTRA_MANIFEST/workflows/mac-swift.yml; also makes the DMG the site needs) compiles on a push to main
and releases v<N> (app.zip + MantraWebcamRecorder-<N>.dmg) as Latest. Nothing compiles on the Mac.

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

**Code:** `app/App.swift` (start, flags, ⌘Q menu), `app/Viewer.swift` (window, bar, menus, session with video and audio
data outputs, recording control, full screen, Sony wiring, watchdog, selftest), `app/Recorder.swift` (AVAssetWriter: HEVC,
AAC, the tmcd track), `app/Meter.swift` (StereoMeter, the record key, the corners key), `app/SonyBar.swift`,
`app/SonyLink.swift`, `app/SonyCamera.swift`, `app/SonyProbe.swift` (`--sony-probe`), `app/KeepStreaming.swift`. `site/public` the page (SEO by kits/seo, bowl, counters).

**Next:** (1) Marko sets the Sony's streaming to 1080p; check the format list shows 1920×1080. (2) When the UGREEN HDMI
capture card arrives (in his basket): Sony USB Cnct Mode (PORT1) = Remote Shoot/Trn., picture via the card, then test every
Sony control and the TC jam (`--sony-probe` first). (3) Offered, not asked for: a one-cable mode switcher (frozen frame
while the camera changes USB mode). (4) His look in use. The page's banner and lifestyle pictures are real screenshots for now; Nano Banana renders of
the app in use replace them when made (page-pictures-nano-banana).
