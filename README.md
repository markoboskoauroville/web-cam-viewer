# Web Cam Viewer (Mantra)

A macOS app in Swift that shows the picture of any camera the Mac sees: the built-in FaceTime camera, USB webcams and
capture cards, the iPhone (Continuity Camera), and virtual cameras (Iriun, OBS, NDI). One window, the picture fills it
whole (never cropped), and over its top edge a half see-through bar: the camera menu in the middle, ✕ on the right.

- **Choose a camera** in the menu; the choice is remembered. Cameras plugged in or out appear and vanish by themselves.
- **✕** quits; the camera light goes off.
- **PERMISSIONS** (amber, beside ✕) shows only while the camera is not allowed; a click opens Privacy & Security → Camera.
- Drag the window anywhere by the picture, resize from its edges; size and place are remembered.

In the star: folder **Mac**. Installed as `/Applications/Web Cam Viewer (Mantra).app`, bundle id
`community.auroville.webcamviewer`, signed "Mantra Apps".

## Build

    ./build.sh            # swiftc, icon, sign, install in /Applications, quit the old copy, open the new
    ./build.sh --no-run   # build and install only

## Test flags

    WebCamViewer --list                 # the cameras, in the menu's order
    open -n -g "/Applications/Web Cam Viewer (Mantra).app" --args --quiet
                                        # a test start on the MacBook Pro screen, without taking focus
    open -n -g "/Applications/Web Cam Viewer (Mantra).app" --args --selftest /path/report.txt
                                        # every camera 3 s: frames counted, frame difference (moving or frozen), then quit
