# Webcam Recorder (Mantra)

Until v1 called Web Cam Viewer (Mantra). A macOS app in Swift: the picture of any camera the Mac sees (FaceTime, USB
webcams and capture cards, the iPhone, OBS / NDI / Iriun virtual cameras), sound from any input, and one key that records.
Page: **https://webcamrecorder.markobosko.org** (download, donation bowl), card 21 in the Kod tab of markobosko.org.

- **The picture** fills the whole window, never cropped. Over its top edge a half see-through bar: camera menu · sound
  menu · ● record, in the top middle; the full-screen key (four corners) and ✕ at the top right.
- **Video input statistics** appear at the top while both a camera and a sound input are active: negotiated resolution,
  target FPS, pixel format and dropped frames. If the feed falls behind, its live FPS appears beside the target in white.
  The line sits inside the dark input bar, immediately beside the record key. Click it for capture-device preferences:
  supported format, frame rate, focus, exposure and white-balance modes. Choices are kept per device. The connected
  UGREEN 15389 passed every exposed combination (106/106): 10/20/30/50/60 FPS through 1080p and 10/20/30 at 1440p.
  It does not expose 24/25 FPS or focus/exposure/white-balance controls on this Mac.
- **Two VU hairlines** down the left edge, left and right channel, 2 pt each and touching (v4), the meter of Mantra Manual
  Camera: dB from −54, −6 and −18 marked, green / amber / red, white peak; a mono input lights both.
- **The record key** is a white ring; under the mouse it fills with a see-through red (v3), pressed it turns solid red.
- **PLAY** beside Record opens the last completed take in the local player. It has two waveform rows (selected audio and
  the camera reference), click-to-seek, Space play/pause, Left/Right one-frame stepping and Shift+Left/Right ten frames.
  **AUTO ALIGN** measures the residual between both audio tracks; **PHONE TC / LTC** reads 25 fps LTC from audio and OCRs
  the phone timecode from the picture. Both refuse low-confidence measurements and apply the measured delta per input.
- **● records** `~/Movies/mb_YYYY-MM-DD_HH-MM-SS.mkv`: H.264 at the live camera resolution and delivered frame rate, AAC
  48 kHz, with the real-time start time code in the file metadata; `REC  HH:MM:SS:FF` is shown while it records.
  LOW / MID / HIGH scale from 10 / 25 / 50 Mb/s at 1920×1080 30 FPS, by pixels × delivered FPS. The quality key is next
  to Record and shows the actual bitrate from the MKV on disk plus estimated free-space recording time. Space is shown
  compactly as hours, minutes and seconds; zero units are omitted. The MKV is flushed through one-second clusters from the
  first frame so an unplanned app/computer stop leaves a readable file.
- **⌘F** or the corners key: full screen: the picture, the two meters (whole height) and the REC time code; only the bar
  goes. **Escape** goes back.
- **No Sony tether.** Webcam Recorder never opens an ImageCapture/PTP session and never holds an unselected Sony open.
  Sony remote shooting remains owned by the official Sony application.
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
    WebCamViewer --sync-math-selftest   # verifies sample-lag correlation and the 25 fps LTC decoder
    curl http://127.0.0.1:8867/status    # includes feed, actualBitrate and remainingTime
    curl http://127.0.0.1:8867/capture   # verified formats, FPS and supported controls
    open -n -g "/Applications/Webcam Recorder (Mantra).app" --args --quiet
                                        # a test start on the MacBook Pro screen, without taking focus
    open -n -g "/Applications/Webcam Recorder (Mantra).app" --args --selftest /path/report.txt
                                        # every camera 3 s (frames, frame difference), then a 6-second take; quits
    ... --args --quiet --hover-rec      # the record key drawn as if the mouse were over it (for a screenshot)
    ffprobe the take: hevc 1920x1080, aac, a tmcd stream with tag:timecode = the wall clock of the first frame
