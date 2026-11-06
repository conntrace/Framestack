#!/usr/bin/env python3
"""Generate the deterministic video fixtures used by FrameStackMediaTests.

Requires: python3, numpy, ffmpeg (with libx264).

    python3 scripts/make_fixtures.py

The generated files are committed under Tests/FrameStackMediaTests/Fixtures so
tests do not depend on an encoder being available on the test machine. Rerun
only when fixture *content* needs to change, then update the tests and
docs/FIXTURES.md accordingly.

All clips are 8-bit 4:2:0 H.264 tagged BT.709 (primaries/transfer/matrix,
limited range), which is what a typical camera/phone SDR clip looks like.
Content is restricted to neutral black/white/gray (and one pure red marker) so
that expectations do not depend on chroma subsampling details.
"""

import os
import subprocess
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Tests", "FrameStackMediaTests", "Fixtures")

BT709_TAGS = [
    "-color_primaries", "bt709",
    "-color_trc", "bt709",
    "-colorspace", "bt709",
    "-color_range", "tv",
]


def encode(name, frames, fps, extra_input=None, extra_output=None):
    """Pipe RGB24 frames into ffmpeg and write an H.264 MP4."""
    h, w, _ = frames[0].shape
    path = os.path.join(OUT, name)
    cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error"]
    cmd += extra_input or []
    cmd += [
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{w}x{h}",
        "-r", str(fps), "-i", "-",
        "-vf", "scale=out_color_matrix=bt709:out_range=tv:flags=neighbor",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-profile:v", "high",
    ]
    cmd += extra_output or []
    cmd += BT709_TAGS + ["-movflags", "+faststart", "-an", path]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    for f in frames:
        proc.stdin.write(np.ascontiguousarray(f, dtype=np.uint8).tobytes())
    proc.stdin.close()
    if proc.wait() != 0:
        sys.exit(f"ffmpeg failed for {name}")
    print(f"wrote {path} ({os.path.getsize(path)} bytes)")


def count_clip():
    """5 s at 30 fps = 150 frames, 320x180.

    The frame index is written as an 8-bit binary code in eight 40x40 blocks
    along the top row (block b, from left, is white when bit (7-b) is set,
    i.e. MSB first). The rest of the frame is mid gray. Encoded with B-frames
    (frame reordering) so decode order != presentation order, exercising
    timestamp sorting and the MP4 edit list ffmpeg writes for B-frame delay.
    """
    w, h = 320, 180
    frames = []
    for i in range(150):
        f = np.full((h, w, 3), 128, dtype=np.uint8)
        for b in range(8):
            bit = (i >> (7 - b)) & 1
            f[0:40, b * 40:(b + 1) * 40, :] = 255 if bit else 0
        frames.append(f)
    encode("count_5s_30fps.mp4", frames, 30,
           extra_output=["-crf", "12", "-bf", "3", "-g", "30"])


def moving_square():
    """24 frames at 30 fps, 480x272, black background.

    A white 32x32 square at x = 16 + 16*i, y = 80 (frame i), so each column in
    [32, 384) is covered by exactly two consecutive frames. A stationary
    mid-gray (sRGB 128) bar spans y in [200, 240) on every frame.
    All-intra so every frame is coded independently at high quality.
    """
    w, h = 480, 272
    frames = []
    for i in range(24):
        f = np.zeros((h, w, 3), dtype=np.uint8)
        x = 16 + 16 * i
        f[80:112, x:x + 32, :] = 255
        f[200:240, :, :] = 128
        frames.append(f)
    encode("moving_square_24f.mp4", frames, 30,
           extra_output=["-crf", "8", "-g", "1", "-bf", "0"])


def black_white():
    """30 frames at 30 fps, 160x96: even frames black, odd frames white."""
    w, h = 160, 96
    frames = []
    for i in range(30):
        v = 0 if i % 2 == 0 else 255
        frames.append(np.full((h, w, 3), v, dtype=np.uint8))
    encode("black_white_30f.mp4", frames, 30,
           extra_output=["-crf", "8", "-g", "1", "-bf", "0"])


def portrait():
    """10 frames, encoded 320x180 landscape, with a display matrix rotating
    90 degrees clockwise (ffprobe reports "rotation of -90.00 degrees"), as
    an iPhone shooting in portrait would produce. The *encoded* top-left
    64x64 block is pure red; the rest is mid gray. When displayed upright
    (320 wide -> 180 wide, 180 tall -> 320 tall) the red block must be in the
    top-right corner.
    """
    w, h = 320, 180
    frames = []
    for _ in range(10):
        f = np.full((h, w, 3), 128, dtype=np.uint8)
        f[0:64, 0:64, :] = (255, 0, 0)
        frames.append(f)
    encode("portrait_rot90cw.mp4", frames, 30,
           extra_input=["-display_rotation", "-90", "-noautorotate"],
           extra_output=["-crf", "8", "-g", "1", "-bf", "0"])


def trimmed_edit_list():
    """Stream-copy 1.5 s … 3.5 s of the count clip without re-encoding.

    ffmpeg keeps the packets from the preceding keyframe (frame 30) and writes
    an MP4 edit list (media_time = 0.5 s) so playback starts at frame 45.
    The presented clip is frames 45 … 106 (62 frames); frames 30 … 44 are
    stored but outside the edit. Exercises edit-list mapping in the scanner.
    """
    src = os.path.join(OUT, "count_5s_30fps.mp4")
    dst = os.path.join(OUT, "trimmed_editlist.mp4")
    subprocess.run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
                    "-ss", "1.5", "-i", src, "-t", "2", "-c", "copy", "-an", dst],
                   check=True)
    print(f"wrote {dst} ({os.path.getsize(dst)} bytes)")


def corrupt_frame():
    """Copy of the count clip with frame 75 (pts 2.5 s) made undecodable.

    The first four bytes of that sample — the AVC NAL length prefix — are
    overwritten with 0xFFFFFFFF, which is what a damaged file looks like in
    practice (ffmpeg: "Invalid NAL unit size"). AVFoundation's reader fails
    at that sample; FrameStack must report the frame as missing, keep the
    other 149, and not substitute another frame. Derived from the committed
    count clip so it does not depend on the local encoder.
    """
    import json
    src = os.path.join(OUT, "count_5s_30fps.mp4")
    dst = os.path.join(OUT, "corrupt_frame_75.mp4")
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "packet=pts_time,pos,size", "-of", "json", src],
        check=True, capture_output=True, text=True)
    packets = json.loads(probe.stdout)["packets"]
    target = [k for k in packets if abs(float(k["pts_time"]) - 2.5) < 1e-6]
    assert len(target) == 1, target
    pos, size = int(target[0]["pos"]), int(target[0]["size"])
    data = bytearray(open(src, "rb").read())
    assert size > 8
    data[pos:pos + 4] = b"\xff\xff\xff\xff"
    open(dst, "wb").write(data)
    print(f"wrote {dst} ({len(data)} bytes; sample at {pos} corrupted)")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    only = sys.argv[1:]
    if only == ["corrupt"]:
        corrupt_frame()
        sys.exit(0)
    count_clip()
    trimmed_edit_list()
    moving_square()
    black_white()
    portrait()
    corrupt_frame()
