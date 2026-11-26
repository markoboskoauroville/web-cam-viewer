#!/usr/bin/env python3
"""Create a deterministic Resolve-vs-Webcam-Recorder waveform benchmark."""
import math
import os
import random
import subprocess
import wave

RATE = 48_000
SECONDS = 10
FPS = 25
DELAY_SAMPLES = 6578
OUT = "/tmp"


def wav(path, values):
    with wave.open(path, "wb") as stream:
        stream.setnchannels(1)
        stream.setsampwidth(3)
        stream.setframerate(RATE)
        data = bytearray()
        for value in values:
            pcm = int(max(-1, min(1, value)) * 8_388_607)
            data += pcm.to_bytes(3, "little", signed=True)
        stream.writeframes(data)


rng = random.Random(73_026)
count = RATE * SECONDS
reference = [0.0] * count
for t in [0.45, 1.18, 2.03, 2.71, 3.44, 4.18, 5.07, 5.96, 6.62, 7.41, 8.33, 9.04]:
    start = int(t * RATE)
    length = 720
    for i in range(length):
        envelope = math.sin(math.pi * i / length) ** 2
        frequency = 420 + ((i % 240) / 240) * 2800
        reference[start + i] = (
            math.sin(2 * math.pi * frequency * i / RATE) * 0.65
            + rng.uniform(-0.35, 0.35)
        ) * envelope

selected = [0.0] * DELAY_SAMPLES + reference[:-DELAY_SAMPLES]
reference_path = os.path.join(OUT, "wcr-benchmark-reference.wav")
selected_path = os.path.join(OUT, "wcr-benchmark-selected.wav")
camera_path = os.path.join(OUT, "wcr-benchmark-camera.mov")
combined_path = os.path.join(OUT, "wcr-benchmark-combined.mkv")
wav(reference_path, reference)
wav(selected_path, selected)

subprocess.run([
    "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
    "-f", "lavfi", "-i", f"color=c=black:s=640x360:r={FPS}:d={SECONDS}",
    "-i", reference_path, "-map", "0:v", "-map", "1:a",
    "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "pcm_s24le",
    camera_path,
], check=True)
subprocess.run([
    "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
    "-f", "lavfi", "-i", f"color=c=black:s=640x360:r={FPS}:d={SECONDS}",
    "-i", selected_path, "-i", reference_path,
    "-map", "0:v", "-map", "1:a", "-map", "2:a",
    "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "pcm_s24le",
    combined_path,
], check=True)

print("delay_samples:", DELAY_SAMPLES)
print("delay_ms:", f"{DELAY_SAMPLES / RATE * 1000:.6f}")
print("camera:", camera_path)
print("selected:", selected_path)
print("combined:", combined_path)
