#!/usr/bin/env python3
"""Generate the deterministic video fixtures used by FrameStackMediaTests.

Requires: python3, numpy, ffmpeg (with libx264 and libx265).

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


def encode(name, frames, fps, extra_input=None, extra_output=None, transfer=None):
    """Pipe RGB24 frames into ffmpeg and write an H.264 MP4.

    `transfer` overrides the transfer-characteristics tag only (the pixels are
    encoded exactly as for BT.709): e.g. "log100" writes a clip that says it
    is logarithmic, which AVFoundation reports as "TransferFunction#9".
    """
    h, w, _ = frames[0].shape
    path = os.path.join(OUT, name)
    cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error"]
    cmd += extra_input or []
    vf = "scale=out_color_matrix=bt709:out_range=tv:flags=neighbor"
    tags = list(BT709_TAGS)
    if transfer:
        vf += f",setparams=color_primaries=bt709:color_trc={transfer}:colorspace=bt709:range=tv"
        tags[tags.index("-color_trc") + 1] = transfer
    cmd += [
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{w}x{h}",
        "-r", str(fps), "-i", "-",
        "-vf", vf,
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-profile:v", "high",
    ]
    cmd += extra_output or []
    cmd += tags + ["-movflags", "+faststart", "-an", path]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    for f in frames:
        proc.stdin.write(np.ascontiguousarray(f, dtype=np.uint8).tobytes())
    proc.stdin.close()
    if proc.wait() != 0:
        sys.exit(f"ffmpeg failed for {name}")
    print(f"wrote {path} ({os.path.getsize(path)} bytes)")


def encode_10bit(name, y_planes, fps, lossless=True):
    """Pipe 10-bit 4:2:0 (yuv420p10le) gray frames into ffmpeg and write an
    HEVC Main10 MP4 (libx265, Apple-compatible hvc1 tag)."""
    h, w = y_planes[0].shape
    path = os.path.join(OUT, name)
    chroma = np.full((h // 2, w // 2), 512, dtype=np.uint16)
    params = "lossless=1" if lossless else "qp=4"
    cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
           "-f", "rawvideo", "-pix_fmt", "yuv420p10le", "-s", f"{w}x{h}",
           "-r", str(fps), "-i", "-",
           "-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-profile:v", "main10",
           "-x265-params", params + ":log-level=error", "-tag:v", "hvc1"]
    cmd += BT709_TAGS + ["-movflags", "+faststart", "-an", path]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    for y in y_planes:
        proc.stdin.write(np.ascontiguousarray(y, dtype=np.uint16).tobytes())
        proc.stdin.write(chroma.tobytes())
        proc.stdin.write(chroma.tobytes())
    proc.stdin.close()
    if proc.wait() != 0:
        sys.exit(f"ffmpeg failed for {name}")
    print(f"wrote {path} ({os.path.getsize(path)} bytes)")


def ten_bit_ramp():
    """10 frames, 320x180, HEVC Main10: a horizontal luma ramp from code 64
    (black) to 940 (white) in 10-bit limited range — 876 steps over 320
    columns, i.e. every column has its own code. An 8-bit decode can only
    show 219 distinct values, so the number of distinct column values proves
    which decode path was used (D-009 revisit in M4)."""
    w, h = 320, 180
    codes = np.round(64 + (940 - 64) * np.arange(w) / (w - 1)).astype(np.uint16)
    y = np.tile(codes, (h, 1))
    encode_10bit("tenbit_ramp_10f.mp4", [y] * 10, 30)


def png_sequence():
    """12 PNG stills, 160x90, in Fixtures/sequence_png_12f/, named frame_0.png …
    frame_11.png (unpadded, so natural sort must place frame_10 after frame_9
    and lexicographic sort would not). Top 40 rows carry the frame index in
    8 binary blocks (20 px wide, white = bit set), rows 60–80 a gray bar at
    sRGB 128; the rest black. Mirrors the count clip so the same tests prove
    frame identity, order and the linear-light average."""
    w, h = 160, 90
    folder = os.path.join(OUT, "sequence_png_12f")
    os.makedirs(folder, exist_ok=True)
    for i in range(12):
        f = np.zeros((h, w, 3), dtype=np.uint8)
        for b in range(8):
            if (i >> (7 - b)) & 1:
                f[0:40, b * 20:(b + 1) * 20] = 255
        f[60:80, :] = 128
        path = os.path.join(folder, f"frame_{i}.png")
        cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
               "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{w}x{h}", "-i", "-",
               "-frames:v", "1", "-pix_fmt", "rgb24", path]
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
        proc.stdin.write(np.ascontiguousarray(f).tobytes())
        proc.stdin.close()
        if proc.wait() != 0:
            sys.exit(f"ffmpeg failed for {path}")
    # A stray non-image file that importers must skip, not choke on.
    with open(os.path.join(folder, "notes.txt"), "w") as fh:
        fh.write("not an image\n")
    print(f"wrote {folder} (12 PNGs + notes.txt)")


HANDHELD_OFFSETS = [(0, 0), (6, -4), (-9, 3), (12, 8), (3, 1), (-5, -10), (8, -2), (-11, 6)]


def handheld_frames():
    """8 frames, 320x180, cut from one static 400x260 textured scene at the
    integer offsets HANDHELD_OFFSETS (frame i shows the scene shifted by
    (-dx, -dy): a camera that drifts by (dx, dy)). Frame 4 (the middle one,
    the default alignment reference) is at (3, 1). The scene is a seeded
    random texture plus a bright disc and a dark bar so registration has
    structure everywhere and no periodic pattern."""
    rng = np.random.default_rng(20261106)
    # 4x4-pixel random blocks: plenty of structure for registration, and the
    # PNGs stay small (per-pixel noise compressed to ~110 KB a frame).
    coarse = rng.integers(40, 200, size=(65, 100, 3), dtype=np.uint8)
    big = np.repeat(np.repeat(coarse, 4, axis=0), 4, axis=1)
    yy, xx = np.mgrid[0:260, 0:400]
    disc = (xx - 230) ** 2 + (yy - 120) ** 2 < 30 ** 2
    big[disc] = (240, 240, 240)
    big[150:160, 80:300] = (10, 10, 10)
    frames = []
    for dx, dy in HANDHELD_OFFSETS:
        x0, y0 = 40 + dx, 40 + dy
        frames.append(big[y0:y0 + 180, x0:x0 + 320].copy())
    return frames


def handheld_sequence():
    """Fixtures/handheld_png_8f/ (lossless) and handheld_8f.mp4 (H.264 crf 12)."""
    frames = handheld_frames()
    folder = os.path.join(OUT, "handheld_png_8f")
    os.makedirs(folder, exist_ok=True)
    for i, f in enumerate(frames):
        path = os.path.join(folder, f"hand_{i}.png")
        cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
               "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "320x180", "-i", "-",
               "-frames:v", "1", "-pix_fmt", "rgb24", path]
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
        proc.stdin.write(np.ascontiguousarray(f).tobytes())
        proc.stdin.close()
        if proc.wait() != 0:
            sys.exit(f"ffmpeg failed for {path}")
    print(f"wrote {folder} (8 PNGs)")
    encode("handheld_8f.mp4", frames, 30, extra_output=["-crf", "12", "-g", "4", "-bf", "0"])


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


def bright_point():
    """24 frames at 30 fps, 320x180, black: a small light crossing the dark.

    A white 8x8 point at x = 16 + 8*i, y = 88 (frame i): every column in
    [16, 208) is lit by exactly one frame, nothing else ever is. Lighten
    keeps the whole trail at white; Average leaves it at 1/24; Darken and
    Median keep black. All-intra.
    """
    w, h = 320, 180
    frames = []
    for i in range(24):
        f = np.zeros((h, w, 3), dtype=np.uint8)
        x = 16 + 8 * i
        f[88:96, x:x + 8, :] = 255
        frames.append(f)
    encode("bright_point_24f.mp4", frames, 30,
           extra_output=["-crf", "8", "-g", "1", "-bf", "0"])


def silhouette():
    """24 frames at 30 fps, 320x180: a dark shape crossing a light wall.

    Background sRGB 200. A dark (sRGB 16) 24x96 rectangle at x = 16 + 8*i,
    y in [40, 136) (frame i): every column in [32, 208) is covered by exactly
    three consecutive frames. Darken keeps the dark band [16, 224); Lighten
    and Median keep the clean wall; Average is 3/24 dark in linear light.
    All-intra.
    """
    w, h = 320, 180
    frames = []
    for i in range(24):
        f = np.full((h, w, 3), 200, dtype=np.uint8)
        x = 16 + 8 * i
        f[40:136, x:x + 24, :] = 16
        frames.append(f)
    encode("silhouette_24f.mp4", frames, 30,
           extra_output=["-crf", "8", "-g", "1", "-bf", "0"])


def log_tagged():
    """8 frames at 30 fps, 160x96 mid gray, whose transfer tag says
    "logarithmic (100:1)" (H.273 value 9). The pixels are ordinary; only the
    tag differs. Used to check that a log-tagged clip is warned about."""
    frames = [np.full((96, 160, 3), 128, dtype=np.uint8) for _ in range(8)]
    encode("log_tagged_8f.mp4", frames, 30,
           extra_output=["-crf", "12", "-g", "1", "-bf", "0"], transfer="log100")


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
    if only == ["tenbit"]:
        ten_bit_ramp()
        sys.exit(0)
    if only == ["sequence"]:
        png_sequence()
        sys.exit(0)
    if only == ["handheld"]:
        handheld_sequence()
        sys.exit(0)
    if only == ["regression"]:
        bright_point()
        silhouette()
        log_tagged()
        sys.exit(0)
    count_clip()
    trimmed_edit_list()
    moving_square()
    black_white()
    portrait()
    corrupt_frame()
    ten_bit_ramp()
    png_sequence()
    handheld_sequence()
    bright_point()
    silhouette()
    log_tagged()
