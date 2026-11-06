# FrameStack

A native, local-first macOS app that turns time into a still image: import a video or a folder of stills, choose exactly which frames to use, and combine them into one photograph — starting with a true equal-weight, linear-light **Average** (a "long exposure" from video).

Personal creative tool, offline, no accounts. Spec: [`PRD.md`](PRD.md) · agent rules: [`AGENTS.md`](AGENTS.md) · plan & status: [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) · decisions: [`DECISIONS.md`](DECISIONS.md).

## Status

**M1 (first useful slice) — verified on the owner's Mac (macOS 27, Apple M4 Pro, Xcode 27):** open a MOV/MP4 (drag & drop, ⌘O, Finder "Open With", drop on the Dock icon, or `open -a FrameStack clip.mov`) → see metadata and the scanned frame count → pick a `[start, end)` range and **All / Every Nth / Exact Count** → live preview of the **Average** → export a **full-resolution 8- or 16-bit sRGB PNG**. Rendering runs off the main thread with progress and cancel. Damaged frames are skipped and reported (never replaced by a neighbour); iCloud files that are not downloaded are refused with a clear message.

**M2 (creative blending):** a **Blend** menu with **Average, Lighten, Darken, Screen, Multiply, Additive, Difference, Normal (opacity stack)** and an opacity slider for the modes that use it; each mode's exact formula is shown under the menu. All modes share the linear-light pipeline, preview matches export, and every mode has fixed-value reference tests and fixture renders (`DECISIONS.md` D-017).

**M3 (artist workflow):** a filmstrip with draggable in/out handles and a playhead; frame-accurate First/Last frame fields; **Original / Composite / Side by Side** views of the exact source frame under the playhead; zoom to fit, 100 %, zoom in/out, pinch and pan; undo/redo of every setting; collapsible inspector sections; File › Open Recent.

**M4 (robust output and state):** **`.framestack` projects** (⌘S / ⇧⌘S) — one JSON file holding a reference to the video (bookmark + path + size/fingerprint), the time range, sampling, blend, export settings and the playhead; reopening rescans the clip and restores everything. A moved or renamed video is found again; a missing or changed video stops at a **relink** screen (Locate… / Use This File Anyway / Cancel) and is never swapped in silently. **Export** as PNG (8/16-bit), JPEG (quality) or TIFF (8/16-bit), at native size, a long-edge cap or a percentage, in sRGB or Display P3 — every file is read back and its size, depth and profile verified. 10-bit (HEVC Main10 / HDR) clips are decoded to half-float so their precision reaches the composite.

**M5a (image sequences):** open a **folder of JPEG/PNG/TIFF/HEIF stills** (or several chosen files, or one image for its folder) — natural name order, a **sequence rate** field and **Reverse order** toggle, times labelled as *sequence time* because stills have no recorded timestamps; EXIF orientation and embedded profiles (Display P3 phone JPEGs) are honoured; transparent PNGs keep their alpha in PNG/TIFF exports. Mixed sizes are refused with the offending files named; sequences save into projects and relink like videos.

**M5b (alignment):** an **Alignment** section registers every frame to a reference (middle frame or the playhead frame) with Vision before blending — *Shift only* or guarded *Perspective* — so a drifting handheld camera does not blur the background. The inspector reports how many frames aligned, were left out because they could not be registered, or fell back to a plain shift, and the largest shift; a yellow dashed **safe area** on the preview shows where every frame still has pixels, and exports keep the uncovered edges transparent. Transforms are computed once at ≤ 2048 px, so preview and export align identically and an export reuses the preview's work.

**M5c (crop, straighten, canvas):** a **Crop & Straighten** section with a straighten slider, a crop in canvas pixels, **Crop to Safe Area** (the largest rectangle every aligned frame covers after the angle) and an **Edges** choice (transparent / black / white) — all applied once to the finished composite, so preview and export match exactly. A folder of **mixed-size stills** can be opened with **Fit** (transparent bars) or **Fill** (overflow cropped) instead of being refused; the choice is saved with the project.

**M6a (temporal weighting):** a **Weighting** section — Flat, Favor Early, Favor Late, Favor Middle or a Custom curve with draggable points — weights every selected frame by its real timestamp inside the selection. Average becomes a normalised weighted mean, Additive an exposure accumulation, the sequential modes scale opacity per frame; Lighten/Darken say they have no weights. The curve is drawn with one tick per selected frame and the "effective frame count" the weighting is worth.

**M6b (median, luminance):** **Median** is an exact per-pixel median of every selected frame, computed in horizontal bands within a memory budget (the clip is decoded once per band; the Blend section tells you how many passes the preview and the export will take and the bottom bar counts them) — moving subjects vanish, the static scene stays. **Max Luminance** / **Min Luminance** keep, per pixel, the whole colour of the brightest / darkest frame, unlike Lighten/Darken's per-channel extremes.

**M6c (motion mask):** a **Motion Mask** section keeps only the pixels that differ from a background (the Median of the selection, or the playhead frame): threshold, feather, clean-up and invert, with a **mask coverage** view. The masked frames feed whichever blend you chose and the result is laid over the background — Normal + mask is chronophotography, Average + mask a ghost of the motion, Invert keeps only what stood still.

**M6d (painted mask):** a **Painted Mask** section — paint on the preview with a sized, soft brush (or erase), invert, clear — limits the blend to the painted region; everything else shows the background. Strokes are stored as resolution-independent vectors in the project and each stroke is one undo step.

| Keys | |
|---|---|
| ⌘O · Open Recent · drop | open a clip, a folder of stills, several stills, or a `.framestack` project |
| ⌘S · ⇧⌘S | save the project · save as |
| ⌘E | export an image (format, size and color space in the Export section) |
| ⌘Z / ⇧⌘Z | undo / redo settings |
| ⌥← ⌥→ (⌥⇧ ×10) | step the playhead; with the timeline focused, plain ← → ⇧ Home End also work |
| ⌥I / ⌥O | set in / out point at the playhead (I / O when the timeline is focused) |
| ⌥⌘← ⌥⌘→ · ⌥⌘F | playhead to range start / end · full clip |
| ⌥⌘1 / 2 / 3 | Composite / Original / Side by Side |
| ⌘0 · ⌘1 · ⌘= · ⌘− | zoom to fit · actual size · in · out |
| ⌘R · ⌘. | render preview now · cancel |

Not yet: colour adjustments, presets and batches (rest of M6), crop handles on the preview, RAW stills, HDR tone mapping. See the plan.

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

To run the engine on your own footage and get frame counts, timings, memory use and a color cross-check against Apple's decoder:

```bash
FRAMESTACK_REAL_CLIPS="/path/a.mov:/path/b.mp4" FRAMESTACK_ARTIFACTS_DIR=/tmp/framestack-renders swift test --filter RealClipTests
```

`FrameStackAppTests` drives the app's model through the manual checklist below, so the checklist is covered by `swift test` too.

The tests use small deterministic clips in `Tests/FrameStackMediaTests/Fixtures` (regenerate with `python3 scripts/make_fixtures.py`, needs numpy + ffmpeg with libx264 and libx265):

| Fixture | What it proves |
|---|---|
| `count_5s_30fps.mp4` — 150 frames, B-frames, frame index drawn in binary | 5 s/30 fps → exactly 150 timestamps; All=150, N2=75, N3=50, [2,5)=90, [2,5) N3=30; each timestamp decodes to *that* frame; Average of all 150 matches fixed per-block reference values |
| `moving_square_24f.mp4` — white square moving over black, static gray bar | Average is computed in linear light (trail = 2/24 → 82/255, not 21/255); static content is reproduced; preview ≈ full-res export |
| `black_white_30f.mp4` — alternating black/white frames | Linear 0.5 → 188/255; every-2nd = only black frames |
| `portrait_rot90cw.mp4` — 90° display matrix | Portrait clips render upright with correct dimensions |
| `trimmed_editlist.mp4` — stream-copied cut with an MP4 edit list | Only frames inside the edit are counted/used (45…106); fast scan = decoder timestamps |
| `corrupt_frame_75.mp4` — count clip with one damaged NAL unit | The decoder failure is skipped; the damaged GOP is reported missing, every other frame is composited and keeps its identity |
| `tenbit_ramp_10f.mp4` — HEVC Main10 (lossless), a 10-bit luma ramp | 10-bit sources are identified and decoded to half-float: 320 distinct ramp values survive (8-bit decode: 205) and a 16-bit PNG keeps them |
| `sequence_png_12f/` — 12 PNG stills `frame_0…11.png` (+ a stray text file), index in binary blocks, gray bar | Natural sort (frame_10 after frame_9), non-images skipped, sequence time i/rate, every still decodes to itself, Average matches fixed values, reverse order, EXIF orientation and alpha (variants written by the tests) |
| `handheld_png_8f/` and `handheld_8f.mp4` — one static block-noise scene cut at 8 known offsets (a drifting camera) | Alignment recovers every shift (0.5 px lossless, 1 px H.264), the aligned Average equals the reference inside the safe area while the unaligned one blurs, preview and export share transforms, implausible warps fall back to the shift |

## Manual verification (GUI — all 7 steps passed on the owner's Mac on 2026-11-06)

1. Launch, drop any phone clip on the window. Inspector shows file name, pixels (and rotation for portrait clips), duration, nominal fps, codec, color tags; "Frames" first shows `≈ … (estimate)` then the scanned count.
2. Preview appears within a moment; bottom bar shows `N frames in range → N selected` and the timeline strip shows ticks.
3. Set Start = 1, End = 2 (Return to commit). The count and ticks update; the old preview dims with "Preview outdated" until the new one arrives.
4. Switch to **Every Nth** = 3, then **Exact Count** = 20; check the ticks; try Exact Count larger than the range to see the clamping notice.
5. While a preview renders on a long clip, click **Cancel** (or ⌘.) — the app stays responsive.
6. **Export PNG…** (⌘E), 16-bit. When finished the inspector shows the verified size/bit depth/profile; **Show in Finder**; open the file in Preview and compare with the on-screen preview.
7. Change settings and export again without re-importing.
8. (M3) Drag the right handle of the filmstrip to the middle; "Last frame" and the count follow, the film outside dims. Click the strip to place the playhead, press → a few times, then I: "First frame" jumps to the playhead. ⌘Z twice restores the range; ⇧⌘Z redoes.
9. (M3) Switch the toolbar to **Original**, then **Side by Side**; ⌘1 shows 100 %, ⌘= zooms in, scroll pans, ⌘0 fits. Collapse the Source section; it stays collapsed after a relaunch. File › Open Recent lists the clips you opened.
10. (M4) Change a few settings, ⇧⌘S, save `demo.framestack` next to the clip. The title becomes "demo – clip.mov"; the Project section says Saved. Change the blend: the subtitle shows "Edited"; ⌘Q asks Save / Don't Save / Cancel. Quit with Save, double-click the project in Finder (or ⌘O it): the same settings, selection and preview come back.
11. (M4) Rename the clip in Finder and open the project: it opens anyway (Project shows "Unsaved changes" for the new location). Move the clip to another disk or delete it and open the project: "Video not found" with Locate…; pick the clip. Put a *different* video under the old name: "Video has changed" lists size/fingerprint differences; Use This File Anyway loads it with an orange notice describing what differs.
12. (M4) In Export choose JPEG + Percent 50 and export; the inspector reports "Saved 540×960, 8-bit JPEG, sRGB IEC61966-2.1" and Finder agrees. Choose TIFF 16-bit + Display P3; the report says Display P3 and the image looks the same as the sRGB one in Preview (color-managed).
13. (M5a) Drop a folder of same-size photos (or choose several in ⌘O). Source shows "N (JPEG ×N)", the pixel size after rotation, a Sequence rate field and Reverse order; the Time Range caption says "sequence time". Type 10 in the rate field, Return: End becomes N/10 s and the frames stay selected. Tick Reverse order: the filmstrip flips. Save as a project, quit, reopen: rate and order come back. A folder mixing portrait and landscape shots is refused with the file names.
14. (M5b) Open a handheld clip, narrow the range to ~10 frames, turn on **Align frames before blending**: the preview re-renders sharper, the caption says "aligned", the Alignment section reports "N aligned to frame at … · max shift … px" and a yellow dashed safe area appears. Click the strip to move the playhead and **Use Playhead Frame**; ⌘Z restores the middle reference. Export: the inspector says "with alpha" because the moved edges are transparent.
15. (M5c) With alignment on, drag **Straighten** a few degrees: the corners show the checkerboard. **Crop to Safe Area**: the preview shrinks to a clean rectangle and "Output W×H of the canvas" updates; type a Width in the crop fields, Return, and the preview follows; **Edges → Black** fills any remaining transparency (the export report no longer says "with alpha"). ⌘Z steps back through Change Crop / Straighten.
16. (M5c) Open a folder of photos that mix portrait and landscape: the refusal names the files and offers **Fit** and **Fill**; Fit shows letterboxed stills, the Source section says how many were scaled, and the Canvas menu switches between the three policies.
17. (M6a) In Weighting choose **Favor Late**: the curve rises, the ticks follow the selected frames, the caption reports the raw range and the effective frame count, and the preview re-renders favouring the end of the range. Choose **Custom** and drag a point: one undo step. Switch Blend to Lighten: the note says the curve is ignored.
18. (M6b) Choose Blend → **Median** on a clip with a moving subject: the caption says how many passes the preview needs, the bar counts "pass p of P" on long clips, and the subject disappears from the result while the background stays sharp. **Max Luminance** keeps the brightest frame's whole colour per pixel.
19. (M6c) Blend → **Normal**, then turn on **Keep only what moves**: the subject appears at every position over a clean background (chronophotography); the section reports the background used and the moving-pixel share. Tick **Show mask coverage**: white where motion was. Raise the threshold until noise disappears; **Invert** shows the still scene only; **Use Playhead Frame** swaps the background for a frame.
20. (M6d) In Painted Mask turn on **Paint on the preview** and drag a stroke across part of the image: a red stroke appears, the blend applies only inside it and the background shows elsewhere; ⌘Z removes the stroke ("Undo Paint Mask"). Switch the brush to Erase and cross the stroke; **Invert** flips the region.

Please report anything off — especially colors versus QuickTime Player, and any "frames could not be decoded" warnings on real footage.

## How the math works (short)

- Frames are identified by exact presentation timestamps (rational, like `CMTime`); ranges are start-inclusive/end-exclusive.
- Each frame is converted by Core Image from its own color tags to **linear light** (extended sRGB primaries, 32-bit float), oriented upright, then added to **64-bit accumulators**. Average = sum ÷ count. Memory depends on output size, not frame count.
- Export clamps to [0, 1], applies the sRGB curve once, rounds, and writes an sRGB-tagged file (PNG/JPEG/TIFF), then re-reads the file to verify it. Display P3 output first converts the linear values with the sRGB→P3 primaries matrix. Downscaled exports resample each frame with Lanczos in linear light before accumulation — the same path the preview uses.
- Other modes use the same frames: Lighten/Darken are per-channel max/min; Additive is the plain sum (× opacity, kept above 1 until export); Screen, Multiply, Difference and Normal run oldest-to-newest from the first selected frame with `C' = C + opacity × (blend(C, F) − C)`. Normal at 100 % is exactly the last selected frame. Median is the exact per-channel median (mean of the two middle values for an even count), computed band by band so memory stays bounded; Max/Min Luminance pick the whole pixel of the frame with the extreme linear luminance.

Details and trade-offs: `DECISIONS.md` D-004 to D-009 and D-013 to D-021.

## Layout

```
Package.swift
Sources/FrameStackCore/    time model, sampler, accumulator, color math, orientation (pure Swift)
Sources/FrameStackMedia/   AVFoundation scan/decode, Core Image conversion, image export, project file
Sources/FrameStack/        SwiftUI app
Tests/FrameStackCoreTests/ unit tests
Tests/FrameStackMediaTests/ end-to-end tests + fixtures
scripts/                   fixture generator, app bundle builder
.github/workflows/ci.yml   macOS build + test + app bundle
```
