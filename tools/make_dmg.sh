#!/bin/sh
# make_dmg.sh: the installer, a disk image with the app, a shortcut to Applications and the first-launch note. After build.sh.
set -e
cd "$(dirname "$0")/.."
V=$(sed -n 's/^let VERSION = \([0-9]*\)/\1/p' app/App.swift)
NAME="Webcam Recorder (Mantra)"
STAGE=build/dmg; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "build/$NAME.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read me first.txt" <<TXT
Webcam Recorder (Mantra) $V  —  https://mantrawebcamrecorder.pages.dev

1. Drag "Webcam Recorder (Mantra)" onto the Applications folder.
2. Open it. The first time, macOS says it cannot check the app, because it is signed by its author and not through
   Apple's paid program. Open System Settings > Privacy & Security, scroll down, and press "Open Anyway".
3. Allow the camera and the microphone. Choose a camera and a sound input at the top. The round key records to
   Movies/mb_<date>_<time>.mov: H.265, 1080p, 10 Mb/s, with time code from the clock. Cmd-F is full screen, Esc goes back.

Free to use. If it helps you, put something in the bowl on the website.
TXT
cp "build/$NAME.app/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
OUT="build/MantraWebcamRecorder-$V.dmg"; rm -f "$OUT" build/tmp.dmg
hdiutil create -quiet -volname "$NAME $V" -srcfolder "$STAGE" -fs HFS+ -format UDRW build/tmp.dmg
D=$(hdiutil attach -nobrowse -noverify -noautoopen build/tmp.dmg | awk -F'\t' '/\/Volumes\//{print $NF}')
command -v SetFile >/dev/null && SetFile -a C "$D" || true
hdiutil detach -quiet "$D"
hdiutil convert -quiet build/tmp.dmg -format UDZO -imagekey zlib-level=9 -o "$OUT"; rm -f build/tmp.dmg
codesign --force -s "Mantra Apps" "$OUT"
ls -l "$OUT"
