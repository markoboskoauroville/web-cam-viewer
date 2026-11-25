# Blue Cat's PatchWork as the second companion: control, audio routing, attach

Written 25.11.2026 (read-only research; nothing in the open PatchWork session was changed: no preset loaded, no button pressed,
audio setup untouched). Request, word for word, is in `momentaryupdates.md` (25.11.2026, "Mantra VirtualCam, Blue Cat Patchwork
companion, A/V sync"): a second companion "in the same size, same style", PatchWork magnetized to the other side of the recorder
window, controlled from the recorder, and the recorder's audio processed inside PatchWork.

## 1. Decision in five lines

1. **There is no backdoor and no network port.** The standalone PatchWork is a plain Cocoa app with no URL scheme, no AppleScript
   dictionary, no command line control, no OSC, no HTTP. Its window is custom-drawn (OpenGL/Cairo): Accessibility sees only the three
   traffic-light buttons and the title. Pressing its controls through the Mantra Macro Recorder would be pixel clicking: fragile, and
   it takes the mouse from Marko. Not recommended as the main route.
2. **The official remote control is MIDI** (CC, 14-bit CC, NRPN, Note, Bank Select + Program Change for whole presets) and host
   automation of 40 mapped "Control 01..40" parameters. That is the route to build: the recorder drives PatchWork through a virtual
   MIDI port, no clicking.
3. **Cleanest audio route: host the PatchWork Audio Unit inside the recorder** (AVAudioUnit, in process). The AU `BC PatchWork AU`
   (aumf / 1kh1 / Bcau) is installed, universal arm64 + x86_64. Then the processing chain sits between the capture device and the
   recorder's MKV writer with no virtual cable and no extra latency from a second app, and the recorder can show the plug-in's own
   window. The standalone PatchWork stays what it is for Marko's other work.
4. **The companion window (SNAP PATCH) is still built**, because he asked for the magnetic look and because the standalone window
   is the only way to see and edit the chain with the app already open; it reuses Snap.swift nearly entirely (section 5).
5. **Interim route that needs no new audio code:** microphone as PatchWork's input device, PatchWork output = BlackHole 2ch, the
   recorder's sound input = BlackHole 2ch. Works today with a setting change by hand (section 3).

## 2. Evidence: what PatchWork exposes

All commands run 25.11.2026 on the MacBook, PatchWork 2.75 running (pid 25474).

| Question | Command | Result |
|---|---|---|
| Bundle | `plutil -p "/Applications/Blue Cat's PatchWork.app/Contents/Info.plist"` | `com.bluecataudio.blue-cat-s-patchwork`, version 2.75, no `CFBundleURLTypes`, no `NSAppleScriptEnabled`, no `OSAScriptingDefinition`; document type "All Files" (viewer) only. |
| Binary | `file`, `otool -L` | universal x86_64 + arm64; links Cocoa, OpenGL, CoreAudio, AudioUnit, AudioToolbox, **CoreMIDI**, ImageIO. No WebKit, no network framework, no CFNetwork. |
| Signature | `codesign -dv` | hardened runtime, Team FR28HR7442, entitlements: allow-jit, allow-unsigned-executable-memory only (no `automation` entitlement, so no AppleScript receiver). |
| AppleScript | `osascript ... System Events` | the process has no scripting dictionary; only `Blue Cat's PatchWork` and `Edit` menus (Apple, app, Edit). `sdef` needs full Xcode here, but with no `NSAppleScriptEnabled` key the answer is no. |
| Ports | `lsof -nP -a -p 25474 -i` | **nothing**: no TCP, no UDP listener or connection (exit 1, empty). The only network feature is the "Connector Slave" driver type, which is off (manual p. 7, below). |
| MIDI ports | CoreMIDI via ctypes (`MIDIGetNumberOfSources`) | 1 source, 1 destination, both "Bus 1" (the IAC driver). The standalone app **does not publish its own virtual port**; it opens the devices that exist (Edit > Audio Setup, MIDI In "All", MIDI Out "None"). So MIDI can reach it through any existing port such as IAC "Bus 1", or a port the recorder creates itself (a CoreMIDI virtual source shows up as a MIDI input device, but the list is scanned at launch: "make sure all MIDI devices are connected ... they are scanned upon launch", manual p. 7). |
| Settings file | `~/Library/Preferences/Blue Cat Audio/Blue Cat's PatchWork/audio-midi-setup.xml` | `subSystemName="Core Audio" inputDeviceName="BlackHole 2ch" outputDeviceName="ADAM Audio D3V" bufferSize="2048" sampleRate="48000" midiInputs="All" midiOutputs="None"`; also play/record/tap-tempo MIDI map slots (all disabled). Plain XML, readable and writable, but only read at launch. |
| Presets | `~/Documents/Blue Cat Audio/Blue Cat's PatchWork/Presets/*.preset` (Default, clean, DJEMBE CLASS, YOGA, GULLFOSS MASTER, 02 - CLARITY, ...) | `file` says XML 1.0 text. Root `<Preset version="4">`, `<MIDIInputSettings settingCount="90">` (90 mappable settings in this version, not 128), then `<plugin>`, `<state>`, `<params>`, `<map>`, `<skin>`. 78 KB for `clean.preset`; plug-in states are embedded. Plain XML: the recorder can list, copy and name them. Generating a valid chain from scratch is not documented; copy a saved preset instead. |
| Manual | `Contents/Resources/Blue Cat's PatchWork data/manual.pdf` (49 pages, text extracted with PDFKit) | see quotes below. |
| AU / VST3 | `ls /Library/Audio/Plug-Ins/Components`, `auval -a` | `aumf 1kh1 Bcau  -  Blue Cat Audio: BC PatchWork`, `aumf fc00 Bcau` and `aumu fc00 Bcau` (Synth), `aumi v4nm Bcau` (MFX); VST3 `BC PatchWork VST3.vst3` and `BC PatchWork Synth VST3.vst3`. `lipo -archs` on the AU: `x86_64 arm64`. |

**Quotes from the manual** (Blue Cat's PatchWork User Manual, 2013-2025):

- Standalone, network (p. 7): "It is also possible to use the applications as a 'slave' of another application that sends audio and MIDI
  with the Connector plug-in locally or over the network. To do this you should select the 'Network Audio' driver type and 'Connector
  Slave' driver." This is a Blue Cat product protocol (the Connector plug-in), not a documented open API.
- Parameters (p. 17): "With Blue Cat's PatchWork, it is possible to map sub plug-ins parameters in order to control them with host
  automation, an external control surface ... (up to 40 controls are available)." "They are named 'Control 01' to 'Control 40'."
  Several parameters can share one control (macros, Params Map Editor).
- MIDI routing (p. 18-19): "Blue Cat's PatchWork lets you build your own MIDI connections between inserted plug-ins and the host application ...
  Port A to Port P: these are virtual ports that can be used to connect sub plug-ins together."
- Presets by MIDI (p. 32): "It is possible to load presets remotely using MIDI 'Bank Select' and 'Program Change' messages. To enable this
  feature, select a MIDI channel to receive the events from in the MIDI Program Change menu item from the presets menu." "This setting is
  saved for each plug-in instance with your session but not in presets." Every root folder is a bank (factory = bank 0). Bank select by
  CC0 / CC32 (actual bank = 128*CC0 + CC32).
- Control (p. 33-35): "Blue Cat's PatchWork can also be remotely controlled via MIDI using MIDI CC ('Control Change') messages or automation
  curves ... customize the channel, control numbers, range and response curve used for each parameter." Control types: CC (7 bit), CC 14-bit,
  NRPN (14 bit), Note On/Off; MIDI Learn and MIDI Learn Once per control.
- Standalone MIDI (changelog): "MIDI output is now enabled in standalone application." A tap-tempo and play/record/rewind MIDI map exists
  (the `*ControlSetting` slots in `audio-midi-setup.xml`).

**AX tree** (`macro ax-read "Blue Cat's PatchWork"` and System Events, read only): window `Blue Cat's PatchWork`, AXStandardWindow,
at x=1360 y=211, size 620 x 480, currently on the BenQ. Children: close, zoom, minimize buttons (three unlabeled `button`s) and one
`statictext` with the title. Nothing else: every knob, slot and menu inside the rack is drawn by OpenGL. There is nothing to
`ax-press` inside it. `macroskill has "patchwork"` and `macro has "Blue Cat"`: not stored.

**Verdict on "does it have a backdoor?"** No hidden control channel was found and none was looked for beyond what is openly
exposed (no reverse engineering, no protection tampering). The doors that exist are MIDI (CC, NRPN, Program Change), host automation of 40
Controls, the preset XML files, the Audio/MIDI setup XML (read at launch), and the Connector network-slave mode.

## 3. Audio routing: the options compared

Recorder today: `AVCaptureAudioDataOutput` from an `AVCaptureDevice` (`Viewer.swift`, list in line 23: `.microphone, .external`), written
to MKV with ffmpeg; BlackHole already shows in its list. PatchWork standalone today: input BlackHole 2ch, output ADAM Audio D3V.

| Route | How | For | Against |
|---|---|---|---|
| A. Host the AU in the recorder (recommended) | `AVAudioUnit.instantiate(with: AudioComponentDescription(aumf, 1kh1, Bcau))`, an `AVAudioEngine` offline-style chain: capture buffers -> AU -> recorder's PCM FIFO. Load/save the chain with `fullState` (the AU's `aupreset`) and PatchWork presets. UI through `AUAudioUnit.requestViewController` in a recorder-owned panel. | one process, no cable, no second sample clock, latency known (`AUAudioUnit.latency`, feeds the A/V sync work), recorder can set parameters directly (`parameterTree`, 40 Controls) and send MIDI events to it, no clicking, works with the window closed | new audio path in Recorder.swift (the area with the most past pain: LESSONS 28-32, so it needs the full take check); the AU's custom OpenGL view must be hosted correctly; a host that is not a DAW must supply a render block and a sample-time clock; the recorder's own UI must live with a plug-in view. |
| B. Loopback with the standalone app | microphone -> PatchWork input; PatchWork output -> BlackHole 2ch; recorder sound input = BlackHole 2ch | works today with two settings (Edit > Audio Setup in PatchWork); no recorder audio code | the standalone's engine is a second clock and adds a buffer (2048 at 48 kHz = 43 ms plus the virtual device, each way) which must be measured for the A/V sync; PatchWork then plays nowhere audible unless BlackHole is combined with the ADAM in a Multi-Output (changing Marko's audio devices, not done here); only one BlackHole (2ch) is installed, so it cannot be both the source feeding PatchWork and the sink behind it; MIDI/automation cannot be set from the recorder except through a CoreMIDI port. |
| C. Connector slave | PatchWork standalone as network server, a Blue Cat Connector plug-in sends audio | official Blue Cat way | needs the separate Connector plug-in and a host for it; not installed; not simpler than A. |

Choice: build **A** as the real route; offer **B** as the zero-code stopgap so Marko can already hear/record processed sound.
Never route through BlackHole while Marko's session is running (he may be using it): the setup change is his.

## 4. The Mantra Macro Recorder route

- The macro tool can do for PatchWork exactly what it does for any app: `macro win-list/win-move/win-snap` (windows, needs only
  Accessibility), `macro capture-window "Blue Cat's PatchWork"` (pixels, also behind other windows), `macro ocr window:...` and
  `click-text` (Apple Vision finds the labels drawn on the plug-in UI) and `macro do 'Click x, y'`. That can open a slot or toggle a
  bypass, but each click takes the input lock and the mouse, depends on the skin and on the window position, and cannot read values back
  except by OCR. Use it only for what MIDI cannot do (opening a file dialog, choosing audio devices in Edit > Audio Setup).
- **Code reuse is not needed for the recorder to reach it:** Macro Recorder is a separate app with a local API (blob endpoint
  127.0.0.1:8829 and the `macro` command). `grep -n "8829\|macro" app/*.swift` in this repo: **no existing call** from the Webcam
  Recorder to it (only a Sony catalogue string matches). Embedding Macro's clicking code in the recorder (the user's second option) would
  duplicate `AX.swift`/`Keys.swift`/`Guard.swift` for no gain; if clicks are ever needed the recorder should call the `macro` command or its
  API like the sessions do.
- Rule check: a missing hand goes into MACRO_SKILLS (`macroskill add`) the same turn it is built; the first needed skills would be
  `patchwork open chain <name>` and `patchwork audio setup` (only if the MIDI route cannot do them).

**Recommended control route, in order:** (1) in-process AU parameters and MIDI when PatchWork is hosted (route A); (2) CoreMIDI
Program Change / CC to the standalone through a virtual port when only the standalone is used; (3) preset files copied into
`~/Documents/Blue Cat Audio/Blue Cat's PatchWork/Presets` plus (2); (4) Macro Recorder clicks as last resort.

## 5. Design: SNAP PATCH, the second magnet

Reuse from `app/Snap.swift` (SnapRemote, 15 Hz-free, AXObserver based): everything. `findWindow` by bundle id, `attach`, the
AXObserver on moved/resized/destroyed, the expected-frame echo guard (`near`, `expectedOurs/Remote`), `flip` (AX top-left to AppKit
bottom-left), `placeRemote` (our window leads) and `placeOurs` (companion leads), `restore()`, `tell/clear` text ownership (v28 lesson,
LESSONS 39), the Accessibility prompt text. Refactor `SnapRemote` into a `SnapCompanion` taking a config (bundle id, app path,
side, default key name, UserDefaults key); keep `SnapRemote` as the Sony instance. Because Marko wants a change in `app/*.swift` made
by one worker, this research does not touch them.

What is different:

| Item | Sony Imaging Edge Remote | PatchWork |
|---|---|---|
| Bundle id / path | `com.sony.Remote`, `/Applications/Imaging Edge/Remote.app` | `com.bluecataudio.blue-cat-s-patchwork`, `/Applications/Blue Cat's PatchWork.app` |
| Side | right (remembered by where it was; first snap uses the side of its midX) | **the other side**: Sony on one side, PatchWork on the opposite. Marko's words: video control on the left, Sony and PatchWork on the sides. Put PatchWork on the left, Sony stays right (or whichever the first snap finds free; never both on one side). |
| Window | tall control panel 302 x 809 (later a short camera list 800 x 353) | one fixed-title standard window 620 x 480 (current), AXStandardWindow. Its zoom button exists; resizability and minimum size are not readable without trying a resize, so the first snap measures: set our height, read back what it kept (the existing "remote refuses that height" branch already handles a fixed or limited height). |
| Title | none needed | title is "Blue Cat's PatchWork" (apostrophe); find by bundle id, never by title |
| Opening | opens the app when missing | the same, `NSWorkspace.openApplication`; the first run shows the audio setup dialog for a new user, but Marko's setup exists, so it opens the window straight |
| Replacement windows | list <-> control panel swap (`remoteWindowGone`) | none expected; a plug-in window or the Audio/MIDI Preferences window are extra windows: keep choosing the standard window with the largest height among AXStandardWindow only |
| API | `POST /snap {"on"}` | `POST /snap {"which":"sony"|"patch","on":...}` (default `sony` keeps old callers) |

**Two companions at once and screen-space.** Our window is the middle piece; widths add: PatchWork 620 + recorder (min 420) + Sony 302
= 1342 pt. The MacBook's built-in screen is 3024 x 1964 Retina, i.e. about 1512 x 982 points: all three fit, with ~170 pt to spare.
The BenQ (2560 x 1440) is Marko's screen: **never test there**, and Marko currently has all three windows on it (win-list:
Remote 146,216; Webcam Recorder 448,216 911 x 809; PatchWork 1360,211 620 x 480). Test on the MacBook only (`macro win-snap ... MacBook` for
the helper windows, our own window's frame set from the app). Rules to implement: (1) placement is in AX/global coordinates; `flip`
uses `NSScreen.screens.first` (main screen) height, which is correct for any display only while the main display is the origin: keep
using the main screen's height for the flip, and clamp the combined group into the `visibleFrame` of the screen that holds our window;
(2) when both companions are snapped, the group is `[PatchWork][recorder][Sony]`; moving or resizing any one moves the others;
(3) the group's height is the recorder's height, limited by the tallest minimum among the three (Sony 809 is the tallest: a short
recorder window makes both companions refuse the height and the existing fallback grows the recorder to the height they kept: with two
companions, take the maximum of the kept heights and place both again, once); (4) the PatchWork window is shorter than the Sony panel:
top edges level, bottom edges left uneven, never stretched; (5) if the group no longer fits the screen, the companion that overflows
snaps back to the other side of the recorder only if free, otherwise the text "Not enough room beside the window for PatchWork" is
shown through `tell/clear` and nothing is moved.

**The button (Ten-point check item 7: every control an NSButton with an AX title, nothing cut at min width, one title).** Bar order
from the right: PERMISSIONS (when needed), F, S (snap Sony), **P (snap PatchWork)**, full screen, X. Same 30 x 30 icon-only style as
S: SF Symbol `slider.horizontal.3` (off) / `slider.horizontal.3` green (on). AX title/label: "Snap PatchWork" / "Unsnap PatchWork",
identifier `snap-patch`, tooltip "Snap Blue Cat's PatchWork beside this window ...". The bar's minimum width is 420 pt (`window.minSize`):
one more 30 pt key plus 4 pt gap needs 34 pt; at 420 pt the right group (PERMISSIONS only when needed, F, S, P, full, X = 5 x 34 = 170 pt)
still leaves the camera and sound menus 250 pt; if the left items would clip, hide F before P (LESSONS: "the stats key on the bar is clipped when
narrow"). One title only: the companion buttons have no visible text, so nothing is duplicated. The recorder's centre text label is shared;
`tell/clear` stays owner-based so that "Opening PatchWork..." never stays (LESSONS 39). Persist `snappedPatch` in UserDefaults and
restore only when PatchWork is already open (never opens it by itself, same as Sony).

## 6. Control from the recorder: concrete API

Route 2 (standalone through MIDI) and route 1 (hosted AU) share one small protocol in the recorder, `PatchControl`:

- `GET /patch/status`: running (standalone) or hosted, current preset name, chain latency in samples, mapped Controls with names and values.
- `POST /patch/preset {name}`: hosted: load the preset file into the AU; standalone: Bank Select + Program Change on the channel chosen in
  PatchWork's "MIDI Program Change" menu (Marko sets this once, by hand: it is saved per instance, not in presets).
- `POST /patch/control {n: 1..40, value: 0..1}`: AU parameter, or CC / 14-bit CC / NRPN on the learned channel (CC numbers are free to assign in
  PatchWork's MIDI settings; the recorder proposes CC 20 + n on channel 1).
- `POST /patch/bypass {on}`: the Mix control mapped to a Control.
- `POST /snap {"which":"patch","on":true}`.

## 7. Build plan (GitHub-built, small versions, never compiled on the Mac)

Each version: bump `VERSION`, push to main, the workflow builds and releases Latest, install only by `gh release download`; test takes
ZZTEST_ and the Ten-point check every time Recorder.swift changes.

1. **v+1: SNAP PATCH.** Refactor `SnapRemote` to `SnapCompanion` (two instances), button P, API `which`, two-companion maths,
   persisted state. Tested on the MacBook with both companions moved by `macro win-move` (BenQ untouched), screenshots via
   `macro capture-window`. No audio change. Smallest, visible, what he asked for first.
2. **v+2: settings helper (no audio code).** `GET /patch/status` reads the Audio/MIDI setup XML and preset folder (read only); button or
   menu to open the PatchWork presets folder; text that tells which input and output PatchWork uses today (BlackHole 2ch -> ADAM).
3. **v+3: MIDI control of the standalone.** A CoreMIDI virtual source "Mantra Recorder" in the recorder, `/patch/preset`, `/patch/control`;
   Marko once restarts PatchWork and enables MIDI Program Change (section 8). Proven with a read-back by reading the AX/OCR title of the
   preset LCD, or by the control's audible/analyser effect.
4. **v+4: host the AU, UI only.** Instantiate `aumf 1kh1 Bcau`, show its view in a recorder-owned window, no audio through it yet; measure
   `latency`; confirm the OpenGL UI draws and that saved `fullState` reloads.
5. **v+5: audio through the AU** (switch default OFF): capture buffers -> `AVAudioEngine` with the AU -> existing FIFO; a take check
   (`tools/check_take.py`: audio length equals video, max lag <= 1 s) on the 8 s, LOW, 60 s, 240 s slice+HIGH and hard-kill runs; add the AU's
   latency to the A/V sync offset of the Sony-scratch-track work.
6. **v+6: Mantra VirtualCam** (video/audio outputs for Zoom) follows from here; separate research.

## 8. What Marko must do by hand

- **Nothing for v+1 and v+2.**
- For the interim route B (only if he wants it before v+4): in PatchWork Edit > Audio Setup choose his microphone as input and BlackHole 2ch as
  output, and in the recorder choose BlackHole 2ch as sound. This replaces what PatchWork does today (BlackHole in, ADAM out), so it was
  not changed here; to hear it as well he would need a Multi-Output device in Audio MIDI Setup.
- For MIDI preset change (v+3): in PatchWork's presets menu, set "MIDI Program Change" to the channel the recorder uses (once per instance).
- Accessibility for the recorder (already needed for SNAP REMOTE) covers SNAP PATCH.

## 9. Not done / not verified

- `auval -v aumf 1kh1 Bcau` was not run (it instantiates the plug-in; the research stayed passive). Hosting the AU is therefore proven only by its
  registration, architectures and the manual, not by an instantiation test; v+4 does that.
- PatchWork's minimum window size and whether the window is resizable were not measured (a resize would touch his open window).
- No change in `app/*.swift`; no screenshots (windows are on the BenQ, which stays untouched).
