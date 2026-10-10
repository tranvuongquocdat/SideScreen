#!/usr/bin/env python3
"""Encode the looping clip played by the Android app's demo mode.

The source is a screen recording of a real SideScreen extended display
(1680x1050, 16:10) captured on the Mac while connected, so the demo shows
exactly what a user sees on the tablet. Record the extended display with e.g.
    ffmpeg -f avfoundation -capture_cursor 1 -framerate 30 -i "<screen>:none" -t 16 rec.mp4
choreographing motion that ends where it started, then pick the loop window.

Output: AndroidClient/app/src/main/assets/demo.h264 — raw Annex-B H.264
(Main profile, level 4.0, no B-frames, AUD before every access unit, SPS/PPS
repeated on every IDR) so DemoPlayer can split frames on AUD NALs and every
keyframe is independently decodable. 1680x1050 stays under level 4.0's
8192-macroblock frame limit, so even 1080p-capped decoders accept it.

Usage:
    python3 scripts/make_demo_clip.py <recording> <loop start seconds> [duration=14]
"""

import os
import subprocess
import sys

W, H = 1680, 1050  # must match DemoPlayer.WIDTH / HEIGHT
FPS = 30

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "AndroidClient/app/src/main/assets/demo.h264")


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    src, start = sys.argv[1], sys.argv[2]
    duration = sys.argv[3] if len(sys.argv) > 3 else "14"
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    cmd = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-ss", start, "-t", duration, "-i", src,
        "-vf", f"fps={FPS},scale={W}:{H}:flags=lanczos", "-an",
        "-c:v", "libx264", "-profile:v", "main", "-level", "4.0", "-pix_fmt", "yuv420p",
        "-preset", "slow", "-crf", "23", "-tune", "stillimage",
        "-x264-params", f"keyint={FPS}:min-keyint={FPS}:scenecut=0:bframes=0:aud=1:repeat-headers=1",
        "-f", "h264", OUT,
    ]
    if subprocess.run(cmd).returncode != 0:
        sys.exit("ffmpeg failed")
    print(f"{OUT}: {os.path.getsize(OUT) / 1024:.0f} KB")


if __name__ == "__main__":
    main()
