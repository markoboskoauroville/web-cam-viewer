# Webcam Recorder (Mantra)

Until v1 called Web Cam Viewer (Mantra). A macOS app in Swift: the picture of any camera the Mac sees (FaceTime, USB
webcams and capture cards, the iPhone, OBS / NDI / Iriun virtual cameras), sound from any input, and one key that records.
Page: **https://mantrawebcamrecorder.pages.dev** (download, donation bowl), card 21 in the Kod tab of markobosko.pages.dev.

- **The picture** fills the whole window, never cropped. Over its top edge a half see-through bar: camera menu · sound
  menu · ● record, in the top middle; the full-screen key (four corners) and ✕ at the top right.
- **Two VU hairlines** down the left edge, left and right channel, 2 pt each and touching (v4), the meter of Mantra Manual
  Camera: dB from −54, −6 and −18 marked, green / amber / red, white peak; a mono input lights both.
- **The record key** is a white ring; under the mouse it fills with a see-through red (v3), pressed it turns solid red.
- **● records** `~/Movies/mb_YYYY-MM-DD_HH-MM-SS.mov`: H.265 1920×1080 10 Mb/s, AAC 48 kHz, a QuickTime time code track =
  the real-time clock of the first frame (MANTRA_MANIFEST modules/timecode.md); `REC  HH:MM:SS:FF` bottom middle while it
  records. One-second fragments, so a crash loses a second.
- **⌘F** or the corners key: full screen: the picture, the two meters (whole height) and the REC time code; only the bar
  goes. **Escape** goes back.
- **Sony α7 V group** in the bar (v4): `REC | BAT | AF | F | shutter | ISO | name`. Camera and sound menus at the left,
  cut to 8 characters. Over PTP (USB Cnct Mode = Remote Shoot/Trn.): REC toggles the camera's recording, AF green when
  focused (press = half-press until green), a click on the picture = touch focus there, and on connect the camera's time
  code is jammed to the Mac clock. While the Sony is the USB Streaming picture nothing can be controlled, so the group is
  grey (see LESSONS 9). The PTP side is written but not yet tried on the camera (waits for the HDMI capture card).
- **The Sony keeps streaming** (v4): a second capture session holds any connected Sony when it is not the chosen camera,
  so it stays in Output, not Standby; it lets go before the picture opens it. A watchdog reopens a camera that sends no
  frames for 3 s.
- **✕** quits (a running take is closed first). **PERMISSIONS** (amber) only while the camera or the microphone is refused.

Installed as `/Applications/Webcam Recorder (Mantra).app`, bundle id `community.auroville.webcamviewer` (kept from v1 so the
permissions stay), signed "Mantra Apps", universal (arm64 + x86_64). In the star: folder **Mac**.

## Build and publish

    ./build.sh             # build, sign, install, quit the old copy, open the new
    ./build.sh --no-run    # build and install only
    ./build.sh --release   # also tools/make_dmg.sh and tools/release.sh: GitHub release v<N> with the DMG

The release starts `.github/workflows/site.yml`, the worker that updates the page by itself: it puts the newest release's
DMG behind the fixed address `download/WebcamRecorder.dmg`, writes its version and size on the page and deploys to
Cloudflare Pages. Repository secrets: `CLOUDFLARE_API_TOKEN` (Marko pasted it), `CLOUDFLARE_ACCOUNT_ID` (set from
~/Downloads/API/Cloudflare.api.txt). A change in `site/` deploys on push too.

## Test flags

    WebCamViewer --list                 # the cameras, in the menu's order
    open -n -g "/Applications/Webcam Recorder (Mantra).app" --args --quiet
                                        # a test start on the MacBook Pro screen, without taking focus
    open -n -g "/Applications/Webcam Recorder (Mantra).app" --args --selftest /path/report.txt
                                        # every camera 3 s (frames, frame difference), then a 6-second take; quits
    ... --args --quiet --hover-rec      # the record key drawn as if the mouse were over it (for a screenshot)
    ffprobe the take: hevc 1920x1080, aac, a tmcd stream with tag:timecode = the wall clock of the first frame
