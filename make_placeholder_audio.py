#!/usr/bin/env python3
"""One-time helper: generate a TEMPORARY chime for the word "momo".

The real audio will be family recordings dropped into
backend/app/static/audio/nepal-v1/. This script just makes a pleasant
two-tone chime so the speaker button in the app has something to play
while we wait for those recordings.

Run from ~/Desktop/Ghar:
    python3 make_placeholder_audio.py

How it works (teaching notes):
- `wave` + `math` (Python stdlib only): we synthesize two sine-wave tones
  (880 Hz then 659 Hz) with fade in/out envelopes so there are no clicks.
- `afconvert` (ships with macOS): converts our .wav into .m4a, matching
  the audio_url path the app already expects:
      /audio/nepal-v1/food_momo_np.m4a
"""
import math
import os
import struct
import subprocess
import sys
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
DEST = os.path.join(HERE, "backend", "app", "static", "audio",
                    "nepal-v1", "food_momo_np.m4a")
WAV = "/tmp/ghar_momo_placeholder.wav"
RATE = 44100


def tone(freq: float, seconds: float, volume: float = 0.5) -> bytes:
    n = int(seconds * RATE)
    frames = []
    for i in range(n):
        t = i / RATE
        # fade in/out envelopes avoid clicks at the edges
        env = min(1.0, i / (RATE * 0.02), (n - i) / (RATE * 0.05))
        frames.append(int(volume * env * math.sin(2 * math.pi * freq * t) * 32767))
    return struct.pack("<%dh" % n, *frames)


with wave.open(WAV, "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(RATE)
    w.writeframes(tone(880.0, 0.30) + tone(659.25, 0.45))

os.makedirs(os.path.dirname(DEST), exist_ok=True)
r = subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", WAV, DEST],
                   capture_output=True, text=True)
if r.returncode != 0:
    sys.exit("afconvert failed (is this a Mac?): " + r.stderr.strip())

print(f"Wrote {DEST} ({os.path.getsize(DEST)} bytes)")
print("TEMPORARY chime only — replace it with a family recording of 'momo'.")
