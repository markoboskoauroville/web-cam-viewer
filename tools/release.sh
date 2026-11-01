#!/bin/sh
# release.sh: GitHub release v<N> with the DMG (made, or its DMG replaced). The Site action (.github/workflows/site.yml)
# runs after it and puts the newest release behind https://mantrawebcamrecorder.pages.dev/download/WebcamRecorder.dmg.
set -e
cd "$(dirname "$0")/.."
V=$(sed -n 's/^let VERSION = \([0-9]*\)/\1/p' app/App.swift)
DMG="build/MantraWebcamRecorder-$V.dmg"
[ -f "$DMG" ] || { echo "no $DMG: run tools/make_dmg.sh"; exit 1; }
if gh release view "v$V" >/dev/null 2>&1; then gh release upload "v$V" "$DMG" --clobber
else gh release create "v$V" "$DMG" --title "Webcam Recorder (Mantra) $V" --notes "See momentaryupdates.md and TAKEOVER.md for what changed."; fi
gh workflow run site.yml >/dev/null 2>&1 || true
echo "released v$V"
