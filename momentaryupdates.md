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
