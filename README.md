# Webcam Recorder (Mantra)

Until v1 called Web Cam Viewer (Mantra). A macOS app in Swift: the picture of any camera the Mac sees (FaceTime, USB
webcams and capture cards, the iPhone, OBS / NDI / Iriun virtual cameras), sound from any input, and one key that records.
Page: **https://mantrawebcamrecorder.pages.dev** (download, donation bowl), card 21 in the Kod tab of markobosko.pages.dev.

- **The picture** fills the whole window, never cropped. Over its top edge a half see-through bar: camera menu · sound
  menu · ● record, in the top middle; the full-screen key (four corners) and ✕ at the top right.
- **The VU** of Mantra Manual Camera down the left edge: dB from −54, −6 and −18 marked, green / amber / red, white peak.
- **● records** `~/Movies/mb_YYYY-MM-DD_HH-MM-SS.mov`: H.265 1920×1080 10 Mb/s, AAC 48 kHz, a QuickTime time code track =
  the real-time clock of the first frame (MANTRA_MANIFEST modules/timecode.md); `REC  HH:MM:SS:FF` bottom middle while it
  records. One-second fragments, so a crash loses a second.
- **⌘F** or the corners key: full screen, only the picture. **Escape** goes back.
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
    ffprobe the take: hevc 1920x1080, aac, a tmcd stream with tag:timecode = the wall clock of the first frame
