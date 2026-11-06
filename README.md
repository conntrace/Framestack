# FrameStack

A native, local-first macOS app that turns time into a still image: import a video, choose exactly which frames to use, and combine them into one photograph — starting with a true equal-weight, linear-light **Average** (a "long exposure" from video).

Personal creative tool, offline, no accounts. Spec: [`PRD.md`](PRD.md) · agent rules: [`AGENTS.md`](AGENTS.md) · plan & status: [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) · decisions: [`DECISIONS.md`](DECISIONS.md).

## Status

**M1 (first useful slice):** open a MOV/MP4 (drag & drop or ⌘O) → see metadata and the scanned frame count → pick a `[start, end)` range and **All / Every Nth / Exact Count** → live preview of the **Average** → export a **full-resolution 8- or 16-bit sRGB PNG**. Rendering runs off the main thread with progress and cancel.

Not yet: other blend modes (M2), filmstrip scrubbing/zoom/compare (M3), project files and JPEG/TIFF (M4), image sequences and alignment (M5), weighting/masks/motion/color/batches (M6). See the plan.

## Requirements

- macOS 14 Sonoma or later
- Xcode 15 or later (Swift 5.9+). Nothing else — no third-party dependencies.

## Run it

```bash
git clone https://github.com/conntrace/Framestack.git
cd Framestack
swift run -c release FrameStack
```

Or build a double-clickable app (ad-hoc signed, for this Mac only):

```bash
scripts/make_app_bundle.sh
open .build/FrameStack.app
```

Or in Xcode: `open Package.swift`, choose the **FrameStack** scheme and **My Mac**, then Run. For long clips switch the scheme's Run configuration to **Release** (Product › Scheme › Edit Scheme…) — debug builds are much slower at pixel work.

## Test it

```bash
swift test
# also write the rendered composites as PNGs you can look at:
FRAMESTACK_ARTIFACTS_DIR=/tmp/framestack-renders swift test
```

The tests use small deterministic clips in `Tests/FrameStackMediaTests/Fixtures` (regenerate with `python3 scripts/make_fixtures.py`, needs numpy + ffmpeg):

| Fixture | What it proves |
|---|---|
| `count_5s_30fps.mp4` — 150 frames, B-frames, frame index drawn in binary | 5 s/30 fps → exactly 150 timestamps; All=150, N2=75, N3=50, [2,5)=90, [2,5) N3=30; each timestamp decodes to *that* frame; Average of all 150 matches fixed per-block reference values |
| `moving_square_24f.mp4` — white square moving over black, static gray bar | Average is computed in linear light (trail = 2/24 → 82/255, not 21/255); static content is reproduced; preview ≈ full-res export |
| `black_white_30f.mp4` — alternating black/white frames | Linear 0.5 → 188/255; every-2nd = only black frames |
| `portrait_rot90cw.mp4` — 90° display matrix | Portrait clips render upright with correct dimensions |
| `trimmed_editlist.mp4` — stream-copied cut with an MP4 edit list | Only frames inside the edit are counted/used (45…106); fast scan = decoder timestamps |

## Manual verification (GUI — please run once on your Mac)

1. Launch, drop any phone clip on the window. Inspector shows file name, pixels (and rotation for portrait clips), duration, nominal fps, codec, color tags; "Frames" first shows `≈ … (estimate)` then the scanned count.
2. Preview appears within a moment; bottom bar shows `N frames in range → N selected` and the timeline strip shows ticks.
3. Set Start = 1, End = 2 (Return to commit). The count and ticks update; the old preview dims with "Preview outdated" until the new one arrives.
4. Switch to **Every Nth** = 3, then **Exact Count** = 20; check the ticks; try Exact Count larger than the range to see the clamping notice.
5. While a preview renders on a long clip, click **Cancel** (or ⌘.) — the app stays responsive.
6. **Export PNG…** (⌘E), 16-bit. When finished the inspector shows the verified size/bit depth/profile; **Show in Finder**; open the file in Preview and compare with the on-screen preview.
7. Change settings and export again without re-importing.

Please report anything off — especially colors versus QuickTime Player, and any "frames could not be decoded" warnings on real footage.

## How the math works (short)

- Frames are identified by exact presentation timestamps (rational, like `CMTime`); ranges are start-inclusive/end-exclusive.
- Each frame is converted by Core Image from its own color tags to **linear light** (extended sRGB primaries, 32-bit float), oriented upright, then added to **64-bit accumulators**. Average = sum ÷ count. Memory depends on output size, not frame count.
- Export clamps to [0, 1], applies the sRGB curve once, rounds, and writes an sRGB-tagged PNG, then re-reads the file to verify it.

Details and trade-offs: `DECISIONS.md` D-004 to D-009.

## Layout

```
Package.swift
Sources/FrameStackCore/    time model, sampler, accumulator, color math, orientation (pure Swift)
Sources/FrameStackMedia/   AVFoundation scan/decode, Core Image conversion, PNG export
Sources/FrameStack/        SwiftUI app
Tests/FrameStackCoreTests/ unit tests
Tests/FrameStackMediaTests/ end-to-end tests + fixtures
scripts/                   fixture generator, app bundle builder
.github/workflows/ci.yml   macOS build + test + app bundle
```
