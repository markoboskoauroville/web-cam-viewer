# TAKEOVER: Webcam Recorder (Mantra)

**State 1.11.2026: v4 released, installed, on the page. Project closed.** (v2 notes below.)

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
