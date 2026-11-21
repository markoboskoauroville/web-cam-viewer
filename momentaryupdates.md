# Web Cam Viewer (Mantra): the requests, word for word

**1.11.2026:** Marko: *"now we're going to develop a different kind of monitor, a new application in my Start menu. We call it Web Cam Viewer (Mantra). Web Cam Viewer is a simple client for macOS, of course in Swift, which simply shows anything that can be viewed on any webcam. It just displays the picture. It has only a drop-down menu at the top, an X for closing, and at the top I just choose any webcam the system sees, and you show me the picture. Very simple"*

**1.11.2026 (while v1 was being built):** Marko: *"please make the semi-transparent choosing the inputs be overlaid over the picture, and the button should be in the top middle of the screen. But don't sacrifice the viewing area. This part can be over the picture"*

**1.11.2026 (v2):** Marko: *"Now, in the same style, next to the cam input, you also need to bring in audio input. Same as in my manual camera, you make a boom meter on the left side edge screen, jumping, showing there is audio. I also need a record button, which records a file in the movie with just the file name, mb_ and then timestamp. The format will be H.265, 10 megabits per second, 1080p. This is how we are recording the screen automatically. Please look at how my manual camera has time code. While we start recording, the time code appears, and inside the file, we write this in a manifest. We always do this when we make an application for recording cameras, etc., like this. Also, the viewer of web pages has time code. If the file format doesn't support time code, we switch the format. Time code must be there, which is exactly the real-time clock. That's it."*

**1.11.2026 (v2, during the build):** Marko: *"now, also add the full-screen button in the system of any of my apps. In the upper right corner, there will be this rectangle, which looks like full screen with gaps between. When I'm in full screen, it's a totally clean view. There is nothing except the image. If I want to go back, I press the Escape shortcut key. The shortcut key for full screen is Command-F, and Escape is going back"*

**1.11.2026 (v2, during the build):** Marko: *"in this app, we can also publish in domain. We can call it Webcam Recorder (Mantra)"*

**1.11.2026 (v2):** Marko: *"in the repository itself, we need to put Cloudflare secrets. Look how this is done, and open the page for me, please"*

**1.11.2026 (v2):** Marko: *"build worker to update web page automatically. Cloudflare is set now"*

**1.11.2026 (v3):** Marko: *"for 2 meters, I need actually two hairlines, hairline size 2 meters, for the left and right channels, please"*

**1.11.2026 (v3, during the build):** Marko: *"please, hovering over the record button puts the red in the middle, but not full red. Just a little bit of transparent red, so I know if I press it, it will become full and start recording"*

**1.11.2026 (v4):** Marko: *"since we already have the code, and you develop it, if something is missing, you need to put it on. It's about Sony controlling the Sony cameras. I have an Alpha 75, so there is still space at the top for camera control, and that camera control should be record this time. Just everything in letters: LEC. Next to LEC, you need to give me the status of the camera battery level and focus. If focus is green or not, his focus is not green. I can press on the focus until it becomes green. It's like focusing, forcing after focus. Then you need to give me all three parameters for exposure. Everything will feed there. Just you need to now push camera choice and microphone choice to the left side. Three values are aperture, shutter speed, and ISO. Read everything from the camera and display here, and also the camera name. The last thing is putting pipes in between. If there is no space, actually we can... Choosing the camera and microphone, you can shorten how many characters it can show. It can show 1, 2, 3, 4, 5, 6, 7, 8 characters, and that's enough. No, not the full name. We're going to save some space"*

**1.11.2026 (v4):** Marko: *"also, while Sony is connected, if I click with the mouse, it's like a touch on the Sony screen. It will focus on that pixel inside my camera"*

**1.11.2026 (v4):** Marko: *"and you do this automatically without any user interface. When the camera is connected to the computer, its time code gets jammed to the local clock"*

**1.11.2026 (v4, his answer on the picture):** Marko: *"Since. I didn't know that cable will stop control. That means we need to find a way how to utilize its Wi-Fi for streaming and get picture through Wi-Fi. So we can connect directly to Wi-Fi on this camera or camera can control to my home network and then stream to home network and we can use USB only for controlling, understand only for controlling or vice versa, we can use Wi-Fi for controlling and USB for streaming or even we can use Bluetooth for controlling. So we have three connections. You let me know how to keep USB cable on the phone. I think that's the best speed for streaming and take control over Wi-Fi or Bluetooth."*

**1.11.2026 (v4):** Marko: *"Yes, you can put HDMI dongle, but now I don't have it. So what can we do without USB dongle for HDMI?How can we control and what we can control? So whatever we can control can be green, what we cannot control can be grey out. We have Bluetooth, we have Wi-Fi and the picture must go through USB cable because I want that quality. I'm having online now lesson and I want to be in good picture. I cannot work with small preview. We are streaming now from the USB. HDMI next step added to my basket."*

**1.11.2026 (v4):** Marko: *"And now my USB streaming from my phone is in standby. How is that happening? Who switch it into standby? Is that camera or you are controlling through USB? How this switching mode is happening? I don't know. Can on my recorder be also mode switcher so I can push it to streaming or to some other modes? So that can be solution for using one cable for everything. I switch modes from streaming to controlling mode. So press streaming, press controlling. In between changing modes you just need to freeze the screen so it's not black screen. and then if I want to focus I click on frozen picture. That's also fine. That can be workaround.Using one cable and switching the modes between streaming and controlling."*

**1.11.2026:** Marko: *"And let me know how can I in my camera put a button if streaming is stopped to push it again. One hotkey button. I know how to get in hotkey menu but I don't know how to find it in the menu of hotkey that command which is pausing or pushing streaming."*

Found (Help Guide p.415, PTP 3 Reference pp.682–683): USB Streaming has no start key: Standby until an app on the computer opens the camera, Output while one does; it ends only by unplugging. The only USB mode the computer may request is MSC (0xF012, value 0x0001), so the Mac cannot switch the camera into streaming or out of it.

**1.11.2026 (v4):** Marko: *"Please make my application activate this camera streaming always even if it's not selected."*

**1.11.2026 (v4):** Marko: *"I just opened the, the, in the different application, this camera. Look at, take a screenshot and you will understand everything. It's too much talking, talking, talking, talking, talking."* (Riverside showed the Sony, Webcam Recorder was black: the keeper and the picture held the Sony at once. Fixed: the keeper lets go first, a watchdog reopens a camera that sends no frames for 3 s.)

**1.11.2026:** Marko: *"The streaming size can be configured inside the application. Inside the camera actually. Let me know how in camera I can adjust streaming. Let me know where in menu is that. What quality is it?"*

**1.11.2026 (v4):** Marko: *"In the full screen, please show me VU meter. And both VU meters, full screen, not full screen, should be hairline on the left side without any gap between two VU meters, left and right. Also in the full screen, you need to show me recording, running recording time. So these two things are staying in full screen."*

**Status at closing (1.11.2026):** all requests above are built and released up to v4, except: the Sony controls are greyed while the camera streams (cannot be controlled over USB Streaming; tested when the HDMI capture card arrives), and the one-cable mode switcher was offered, not built.

## 13.11.2026: vertical slice, as in the classroom (for the MPA Lessons Analyzer shooting, MPA request 256)
Marko: "this is in the lesson recorder. Also, make the slice view the same as in my video Ninja in my classroom and on my website, so I can also slice. I want to have the horizontal camera as it is now and record it as vertical camera with a simple trick of slicing"
**Status (13.11.2026): built as v5, pushed, GitHub run and release below in TAKEOVER; not yet seen by Marko.** Saved first (read as: Webcam Recorder (Mantra) gets a "vertical slice" choice per camera like the MPA classroom (`sliceOf()` in MPA website/site/portal/room.html: the middle 9:16 at full height, e.g. 1215x2160 from the α7 V's 3840x2160, scaled in halves to 1080x1920); the preview shows the slice and the recording is written vertical. The Sony α7 V (ILCE-7M5) is on USB since 13.11.2026 10:0x.)

## 13.11.2026: v6, a local HTTP API (MPA_LESSONS_ANALYZER request "Beatrice guides the shooting")
Marko 13.11.2026: "Beatrice needs to guide me ... I say yes, and then it opens up the Sony webcam, and it records. I press stop"
**Status (13.11.2026):** built as v6, 127.0.0.1:8867 (/status /cameras /camera /record/start /record/stop /front); not yet run by Marko.

## 13.11.2026: camera and sound choice on a click; wait for the same camera
Marko: "Please upgrade the webcam recorder so that when it's in a full screen or any screen, when I click on the image, I want to see a choice of the camera and a choice of the sound. That's what I want with the web thing. If I unplug some camera, I don't want that. This goes to another camera. It waits, and if the same camera is plugged in again, it continues playing."
**Status (13.11.2026): built as v7 (not yet seen by Marko).** Saved first (read as: v7: a click on the picture (any size, full screen too) opens an overlay with the CAMERA list (each with its vertical slice) and the SOUND input list, like the classroom page's menu; an unplugged camera never falls over to another one: the picture shows "Waiting for <camera>…", and when the same camera (same unique id) comes back it continues by itself.)

## 20.11.2026: video-input statistics at the top
Marko: "Please update my application. We call it Webcam Recorder Mantra. I need at the top, when there is a video device and there is a sound device, to have also statistical info about the video input, and that is very simple: frame rate and current frame rate if there are drops and resolution and other data about the video feed."
**Status (20.11.2026): built as v9.** The live strip shows resolution, target FPS, live FPS when degraded, pixel format and
dropped frames only while camera and sound are both active; it remains at the top in full screen and is exposed through the
local `/status` API.

## 20.11.2026: statistics corrected into the dark top bar
Marko: "You need to move the status line and the top bar dark bar next to the record button. That was the original request."
**Status (20.11.2026): corrected in v10.** The statistics line is immediately after the record key inside the dark input
bar; the separate overlay below the bar is removed.

## 20.11.2026: remove Sony tether, control the capture device instead
Marko: "Please remove tethering to Sony camera 7M5. Now I cannot control remote shooting with it. Look at the screen right now. When I connect the camera, it reads the camera status, and I cannot control it in the official Sony app. Instead of that, I need to have controls of my capture device, please. Capture device control. If I click on the status line, I can change preferences of my capture device."
**Status (20.11.2026): built as v11.** All ImageCapture/PTP access and the unselected-Sony keeper are removed, including
the old Sony status controls. Clicking the live status line opens the selected capture device's supported format, frame-rate,
focus, exposure and white-balance controls, with format and rate remembered per device.

## 20.11.2026: test the UGREEN modes and keep only working settings
Marko: "Please test all the modes of the uGreen capturing device and check if they switch to that setting. If they do not switch, they need to go out. Only what's working should be in the menu.Also I need frame per second. I don't have 25. I don't have 24. If they're not supported, I can understand that, but please research on the internet what is supported."
**Status (20.11.2026): v12 uses exact device-reported fixed rates.** UGREEN 15389 on this Mac exposes 10, 20, 30, 50 and
60 FPS for 1080p-and-below formats and 10, 20, 30 for 2560×1440. It exposes no 24/25 FPS modes. UGREEN's product
documentation says 2K@30 and 1080p@60 output. Every menu format/rate is checked by active-format readback and delivered live
frames; unsupported focus, exposure and white-balance choices are omitted. The connected device passed 106/106 combinations
after the 14 initial rapid-transition misses were reset, retested in isolation and passed.

Marko: "Please change the color from orange to white."
**Status (20.11.2026): corrected for v12.** The video status line always uses white, including while it reports drops or a
reduced live frame rate.

## 20.11.2026: LOW / MID / HIGH H.264 MKV, disk minutes and crash-safe recording
Marko: "Now record next to the record button that must be a toggle button high, mid, low. Based on 1080p, find another bit rates for another resolution and frame rates. If we have 30 frame rates FPS at 1080p, 10 is low, 10 Mbps, 25 is mid, 50 is high. Then based on this, recalculate for all others and also record a file five seconds of each. Check codec should be H.264 in the file format MKV."

Marko: "Also, you need to open each file and assess its frame rate and pixel density, if it fits the proposed resolution and frame rate. You need to check what's written on the disk. Actually, is the application writing the exact format as UGREEN is offering? If not, fix the bugs."

Marko: "Also next to low, mid, high you need to in parentheses put available hard disk space in minutes."

Marko: "MKV is chosen because in the case of failure of my computer or any other issues that recording stops, the file is actually readable. Please test this feature."

Marko: "For writing MKV files, you need to take code from OBS. Copy the open-source code recorder from OBS."

**Status (20.11.2026): built and verified as v13.** A quality toggle beside Record cycles LOW / MID / HIGH and shows
available disk time as `(<minutes> min)`. Bitrate is scaled by pixels × delivered FPS from 1080p30: 10 / 25 / 50 Mb/s.
The installed UGREEN feed delivered 1080p20, so the targets were 6.67 / 16.67 / 33.33 Mb/s. Three five-second files were
written and opened from disk: each is Matroska, H.264 High, yuv420p, 1920×1080, nominal and actual 20.0 FPS, 48 kHz AAC,
fully decodable. Measured video plus overhead was about 5.84 / 14.83 / 29.87 Mb/s (VideoToolbox CBR with about 10% encoder
and container difference on this static scene). The OBS ffmpeg-mux helper architecture is used with an ISC attribution
to local OBS commit 48b876374: the final MKV exists from the start, one-second clusters are flushed, and VideoToolbox H.264
packets are copied without a remux. A hard kill of the app left a 1080p20 H.264/AAC MKV that decoded with exit 0.

## 21.11.2026: actual file bitrate and compact remaining time
Marko: "Is an upgraded display next to the mid high and etc. You need to add the actual bit rate of the file. Also, you
need to divide minutes into hours, minutes, and seconds. If there are zero hours, you remove hours. If there are zero
minutes, you remove minutes. We save on space. It's very simple."
**Status (21.11.2026): built as v14.** The key shows `MID <actual Mb/s> (<compact h m s>)`. During a buffered first
cluster it shows `— Mb/s`; after Stop it runs ffprobe on the final MKV, so the displayed bitrate exactly matches the disk
file's `format.bit_rate`. Remaining time omits zero-hour and zero-minute parts. The underlying width/height calculation
was also corrected to follow 720p and 1440p sources exactly instead of forcing a minimum 1920×1080 record size.

## 21.11.2026: SONY key, every camera control over the picture (v21)
Marko: "Now when you grabbing every possible control, please map it to my screen. I need to have button Sony control, and
all its icons and pop up menus you overlay over my image, live image in my web recorder, and I can change all the settings
inside my own window, not digging through the sub menus."
He chose our own PTP control (no Imaging Edge Remote window, no stolen mouse, instant changes) and wants PICTURE PROFILE
switchable between PP1 ("shooting") and the S-Log3 / S-Gamut3.Cine profile, its slot read from the camera, never guessed.
**Status (21.11.2026): built as v21, marker fix v22** (see TAKEOVER). Not yet run against the camera: it was not on the Mantra network.

## 21.11.2026: sound, Sony on Wi-Fi, remote control (v23)
Marko: "Continue developing our webcam recording app. It doesn't record the sound first. Bug 2: look at display. Capture the screen from the app. I open the menu in my Sony. It's on Wi-Fi, and the application says it's not on Wi-Fi. Please make it connect to the camera and remotely control it. Fix the bugs. Fable is writing the plan. Workers in the lower model are doing the work, and Fable is giving the score of the app. Until we get 10/10, the job is not finished. While Fable is correcting, you need to always write the skills and lessons learned. Next time the Claude will give 10 out of 10 immediately."

**Plan (Fable, 21.11.2026), in short.** A: reproduce the sound fault through the API in his real configurations, probe
every take (stream, first pts, level, packets), fix the real cause, and never record silently (a warning within 2 s when
no audio samples arrive). B: replace the one "not found" with a staged diagnosis (Mac LAN address, camera ping/ARP with IP
and MAC, SSDP, port 15740/22, camera on USB and who holds it) and name the exact α7 V menu line that opens remote control;
the same diagnosis on GET /sony/status. C: connect and control the real body: Wi-Fi PTP-IP first, USB PTP (ImageCaptureCore)
second behind the same SonyLink calls; never steal the USB session from Imaging Edge Remote silently (a TAKE CONTROL key).
Built as v23 by GitHub only; lessons, takeover, a webcam-recorder skill, the manifest and Queen's skill written back.

Marko: "This is the recording. There is a bit of sound at the beginning, maybe one third of the second, and then it's gone. /Volumes/EXT_1TB/WEBRECORDING/mb_2026-11-21_13-50-08.mkv"
**Measured by the master (21.11.2026, read only):** the sound of that take is not interleaved. A handful of audio packets
sit at the start of the file; the audio from 0.09 s to about 227 s sits in one block at byte 1.42 GB, written at Stop, behind
227 s of video. ffmpeg decodes it, but players that read in file order (IINA, DaVinci Resolve) run out of sound after a
fraction of a second, and a hard kill would have lost the sound completely. Audio track default flag was 0.
