# FrameStack — Implementation Plan

Living checklist (AGENTS.md §2). Status keys: `[x]` done and verified · `[~]` implemented, verification pending or partial · `[ ]` not started.
"Verified" means the stated validation actually ran (CI run or owner's Mac) — see the log at the bottom.

## Current status (update every session)

- **Milestone:** **M1, M2 and M3 done and verified on the owner's Mac** (macOS 27.0, Apple M4 Pro, Xcode 27.0, Swift 6.4 — D-003). M4 (robust output and state) is next.
- **Last local run (2026-11-06):** `swift build` OK; `swift test` **100 tests, 0 failures, 1 skipped** (52 core, 33 media incl. the opt-in real-clip test, 15 app-model); release `.app` built; GUI checklist steps 1–7 pass; blend modes, timeline handles, playhead keys, view modes, zoom, undo/redo and Open Recent all driven in the window.
- **Last CI:** run 42248417651 on commit 8126110 (macOS 15.8.2, Xcode 16.4) — 56/56. The commits from this session have not been through CI yet at the time of writing; check the Actions tab for the push of this branch (the `onKeyPress`/`MagnifyGesture` APIs need macOS 14, which the target already requires).
- **Next task:** M4 — `.framestack` project document (JSON in a package: source bookmark + size/fingerprint, `CompositeSettings`, export settings, schema version; Save / Save As / Open; relink flow that never silently swaps media), then JPEG/TIFF export + output sizing, then the 150/1,000/10,000-frame performance measurements (a 1,200-frame 4K clip already renders at ≈ 90 fps at 1080 px and ≈ 60 fps full-res Average on this Mac).
- **Blockers / open questions for owner (non-blocking):** whether to create a `main` branch so work can go through pull requests (the repo has only `claude/determined-planck-58a6hw`); a 10-bit/HDR clip and the 6.7 GB Sony `C0036.MP4` (iCloud placeholder, could not be downloaded in-session) for M4 stress/color work.

## Architecture (summary)

```
FrameStackCore  (pure Swift + Accelerate; no media frameworks)
  FrameTime / FrameTimeRange   exact rational time, [start,end)
  FrameTimeline / FrameSampler scanned timestamps → eligible → selected (All / Nth / Exact)
  LinearImage, PixelSize       working-space image (linear, extended sRGB, Float32 RGBA)
  AverageAccumulator           streaming Float64 reducer (future: one reducer per blend mode)
  SRGBTransfer / PixelEncoder  export encoding (clamp, sRGB OETF, quantize)
  ImageOrientation             track transform → EXIF orientation

FrameStackMedia (AVFoundation, Core Image, ImageIO)
  VideoSourceLoader            metadata + decode probe → VideoSourceInfo
  FrameScanner                 passthrough read → exact presentation timestamps
  CompositeRenderer            decode selected span → CI linearize/orient/resample → reduce
  ImageExporter                CGImage (preview & export), atomic PNG write + read-back verify

FrameStack (SwiftUI app)
  AppModel                     settings revisions, selection, debounced cancellable preview, export
  ContentView / InspectorView  preview, inspector (source, range, sampling, blend, export), timeline strip
```
PRD §10.3 module mapping: SourceImporter→`VideoSourceLoader`; FrameTimeline/FrameSampler→Core; FrameDecoder+Compositor→`CompositeRenderer`+reducers; PreviewCoordinator→`AppModel` (extract when it grows); ExportService→`ImageExporter`. RegistrationEngine, MaskEngine, ColorPipeline, ProjectStore arrive in M4–M6.

## Validation commands

```bash
swift build                       # debug build of everything
swift test                        # all unit + end-to-end media tests
swift test --filter FrameStackCoreTests
FRAMESTACK_ARTIFACTS_DIR=/tmp/fs-renders swift test   # also writes rendered PNGs for inspection
swift run -c release FrameStack   # launch the app
scripts/make_app_bundle.sh && open .build/FrameStack.app
python3 scripts/make_fixtures.py  # regenerate fixtures (needs numpy + ffmpeg with libx264)
python3 scripts/make_fixtures.py corrupt   # only the corrupt-frame fixture (derived from the committed count clip)
swift test --filter FrameStackAppTests     # the README checklist, driven through AppModel
FRAMESTACK_REAL_CLIPS="/path/a.mov:/path/b.mp4" FRAMESTACK_ARTIFACTS_DIR=/tmp/fs swift test --filter RealClipTests  # owner's footage
open -a .build/FrameStack.app /path/clip.mov   # open a clip without the panel
```
CI: `.github/workflows/ci.yml` runs build, tests, release app bundle; uploads test output + rendered PNGs + zipped app.

---

## M0 — Environment and architecture
- [x] Inspect environment (Linux container, no Swift/Xcode; repo empty) — D-001
- [x] Import PRD.md / AGENTS.md / kickoff from Drive — D-011
- [x] Package layout, modules, test targets — D-002
- [x] Deployment target chosen with stated assumption — D-003
- [x] Deterministic fixtures + generator script — D-010
- [x] CI on macOS runner (build, test, app bundle, artifacts)
- [x] README, IMPLEMENTATION_PLAN.md, DECISIONS.md
- [x] **Exit:** native app builds and tests execute — CI run 42248417651

## M1 — Core vertical slice (P0)
Engine (verified by automated tests on macOS CI):
- [x] Import metadata (pixels, orientation, duration, nominal fps, codec, color tags, HDR/PAR warnings) + decode probe; missing/corrupt files fail with clear errors
- [x] Timestamp scan mapped through the edit list (decode fallback); equals decoder timestamps on every fixture; 5 s/30 fps → exactly 150 timestamps i/30
- [x] `[start, end)` exact rational ranges; All / Every Nth / Exact Count with clamping notice (PRD §11.1 sampler list)
- [x] Selected frames decoded by exact timestamp (frame identity verified across B-frames and a trimming edit list); missing frames reported
- [x] Equal-weight Average in linear light, Float64 accumulation, memory bounded by output size; fixed reference values on real decoded clips
- [x] Reduced-resolution preview path matches full resolution within tolerance
- [x] Cancellation mid-render; renderer reusable afterwards
- [x] PNG export 8/16-bit sRGB: full resolution, atomic write, bit depth + profile verified by read-back, pixel values match
- [x] Portrait (90° display matrix) renders upright

- [x] Damaged files: decoder failures skipped, missing frames + reason reported, never substituted (D-013; `corrupt_frame_75.mp4` fixture + real damaged m4v)
- [x] iCloud placeholders refused with a clear message; loading cancellable (D-016)

App UI (verified on the owner's Mac — `AppModelTests` + accessibility-driven GUI pass, D-015):
- [x] Open panel, drag & drop, Finder "Open With" / Dock drop / `open -a` / launch argument (D-014); inspector source info; estimate → scanned count
- [x] Range fields (µs precision) + Full Clip; sampling controls; "N in range → K selected"; timeline strip with sample ticks
- [x] Debounced (250 ms) cancellable preview, "Preview outdated" indicator, progress + Cancel (button, ⌘., Render menu), 1080/2160/Full quality
- [x] Export panel, progress + Cancel, verified result summary, Show in Finder (button present; not clicked in the automated pass), missing-frame warning with reason
- [x] GUI checklist steps 1–7 (owner confirmed 1–3 by eye; all 7 driven and read back via accessibility on 2026-11-06)
- **Exit:** real 5 s/30 fps clip + synthetic tests incl. actual file export, GUI pass — **met on the owner's Mac**.
- Known limitations carried forward: 8-bit decode (D-009); HDR clipped (D-004); scanner decode-fallback not damage-tolerant (D-013); bottom-bar warning truncates to one line (full text in the export report / tooltip).

## M2 — Essential creative blending (P1) — D-017
- [x] `FrameReducer` protocol (`add(frame)`, `result()`, output-sized state); renderer picks the reducer from `BlendMode.makeReducer`; frames delivered oldest → newest (`deliveredInPresentationOrder` reported)
- [x] Lighten / Darken (per-channel max/min, vDSP, streaming)
- [x] Screen, Multiply (sequential from the first selected frame; `C' = C + α(B − C)`; linear light — documented)
- [x] Additive (Float64 sum × opacity; overflow kept in float, clipped only at export). Exposure/normalisation control → M6
- [x] Difference (sequential |C − F|, order-dependent)
- [x] Normal / Opacity stack (source-over with uniform opacity; 100 % → last selected frame)
- [x] Blend picker (menu) + per-mode info text + order note + opacity slider for modes that use it; export file name carries mode and opacity
- [x] Tests: `BlendModeTests` (1×1 fixed references per mode, two-frame + 1 000/100 000-frame precision, opacity, random data vs scalar reference, bounded footprint), `BlendModeRenderTests` (black/white + moving-square fixtures per mode, "Normal 100 % = last *selected* frame, Average ≠ last", Lighten = all bits / Darken = no bits on the count clip, preview = export per mode), `AppModelTests` (mode/opacity re-render, Average ignores opacity, names)
- [x] GUI: every mode switched in the window, opacity slider driven, timings logged
- **Exit:** numerical reference cases + visual fixture renders per mode — **met on the owner's Mac (2026-11-06)**.
- Not in M2 (planned): Median and luminance max/min (M6, need different state), reversed order (M6), gamma-space creative variant of Screen/Multiply (optional, D-017), Additive exposure (M6).

## M3 — Minimal, polished artist workflow (P1) — D-018
- [x] Filmstrip thumbnails (32, display-oriented), draggable in/out handles snapped to frame boundaries, sample markers, dimmed out-of-range film
- [x] Playhead: click/drag, ← → ⇧ Home End when focused, Frame menu (⌥←/→, ⌥⇧ ×10, ⌥I/⌥O in/out, ⌥⌘←/→ range ends, ⌥⌘F full clip), frame field in the bottom bar
- [x] Original frame under the playhead (exact decode), Composite / Original / Side by Side (toolbar + View menu ⌥⌘1/2/3)
- [x] Zoom to Fit ⌘0, Actual Size ⌘1, Zoom In/Out ⌘=/⌘−, pinch, scroll to pan, checkerboard
- [x] Collapsible inspector sections with remembered state
- [x] Undo/redo (Edit menu, ⌘Z/⇧⌘Z) for range/sampling/blend/opacity with action names; drags and slider grouped
- [x] Recent Files (File › Open Recent, persisted, Dock menu)
- [x] Frame-accurate entry: First/Last frame fields (inclusive) next to the time fields; prev/next frame buttons
- [x] Tests: `TimelineNavigationTests`, `SourceFramesTests`, `AppModelTests` (frame range entry, playhead, in/out, snapped drags, undo/redo/grouping, thumbnails, original view, zoom, recents)
- **Exit:** create and export images entirely interactively — **met on the owner's Mac (2026-11-06)**: the GUI pass set a range by dragging, stepped frames, compared original vs composite, zoomed, undid, and exported, all without the command line.
- Deferred: scrubbing with the mouse while the composite updates live (preview is debounced 250 ms by design); linked panning in side-by-side; keyboard-only focus traversal polish.

## M4 — Robust output and state (P1)
- [ ] `.framestack` versioned project (JSON in package): source bookmark + size/fingerprint, range, sampling, blend, export settings, schema version; Save/Save As/Open; relink flow that never silently swaps media
- [ ] JPEG / TIFF export; output resizing; Display P3 / embedded profile choices
- [ ] 10-bit / half-float decode path (D-009); HDR/log handling policy
- [ ] Performance: measure 150 / 1,000 / 10,000 frames at 1080p/4K; memory high-water mark; Metal/tiling only if measurements warrant
- [ ] Error handling polish, memory-pressure handling
- **Exit:** reproducible projects, bounded-memory exports with tested metadata.

## M5 — Source and geometry expansion (P2)
- [ ] Image sequences (JPEG/PNG/TIFF/HEIF), natural sort, reverse, sequence time axis labeled as such, canvas policy for mixed sizes
- [ ] RAW stills exploration (macOS-supported formats only, documented)
- [ ] Alignment (Vision translation → affine/homography), reference frame choice, failure reporting, on/off compare
- [ ] Crop / straighten, Fit/Fill, crop-to-common-valid-area, edge fill options, safe-crop overlay
- **Exit:** mixed sources + alignment example working, limits documented.

## M6 — Advanced creative controls (P2)
- [ ] Temporal weighting: Flat / Early / Late / Middle / Custom curve (timestamp-based, normalized, zero-weight guard), curve editor
- [ ] Median (exact, tiled/multi-pass or bounded disk cache), max/min luminance modes
- [ ] Motion mask (background reference, threshold, feather, morphology, invert, mask preview)
- [ ] Manual mask painting (brush, softness, undo, overlay, persisted)
- [ ] Motion accumulation / chronophotography over chosen background
- [ ] Post-composite color: exposure, contrast, saturation, WB/tint, curves (cached composite reused)
- [ ] 16-bit TIFF with profiles; reverse order; ping-pong (explicit)
- [ ] Presets (source-independent) and batch variants (collision-safe names, cancellation, per-output status)
- **Exit:** each feature independently testable, non-destructive, reproducible.

## M7 — Release preparation (deferred; only if requested)
- [ ] Signing/notarization, sandbox, onboarding, accessibility audit, wider hardware.

---

## Verification log

| Date | Where | Command | Result |
|---|---|---|---|
| 2026-11-06 | Linux container | `python3 scripts/make_fixtures.py` + ffmpeg decode check | 150/150 frame-index codes decode correctly; moving-square linear avg → 81.5/255 (gamma avg 21.2); black/white linear avg → 187.5/255; portrait display matrix (0,1,−1,0) |
| 2026-11-06 | GitHub Actions macos-15, run 42247670128 (commit e26f890) | `swift build`, `swift test` | Build OK. 54 tests ran; 4 tests failed (166 assertion failures), all from one bug: sample-table timestamps were in media time, decoder timestamps in presentation time (edit list ignored) → timestamp k decoded frame k+2 on the B-frame clip. Fixed in the next commit (D-006). |
| 2026-11-06 | GitHub Actions macos-15 (macOS 15.8.2, Xcode 16.4, Swift 6.1.2, Apple M1 virtual), run 42248417651 (commit 8126110) | `swift build`, `swift test`, `scripts/make_app_bundle.sh` | Build OK; **56 tests, 0 failures** (8.5 s); release app bundle built and Info.plist lints OK. Rendered PNGs uploaded as artifact `framestack-ci-2`. |
| 2026-11-06 | Owner's Mac (macOS 27.0, Apple M4 Pro, 24 GB, Xcode 27.0, Swift 6.4) | `swift build` | Build complete, 8.5 s (debug), no errors. |
| 2026-11-06 | Owner's Mac | `FRAMESTACK_ARTIFACTS_DIR=/tmp/framestack-renders swift test` | **56 tests, 0 failures** (FrameStackMediaTests 22 in 1.8 s; FrameStackCoreTests 34 in 0.14 s). Rendered PNGs inspected: `count_all150_average.png` shows the 8 bit-blocks at increasing brightness (bit 7 set in 22/150 frames → darkest, bit 0 in 75/150 → brightest) over uniform gray; `moving_square_all24_average.png` shows the 2-of-24 trail and the untouched gray bar; `portrait_upright.png` is 180×320 with the red marker top-right; `moving_square_preview_240.png` matches the full-res render at 240 px. |
| 2026-11-06 | Owner's Mac | `scripts/make_app_bundle.sh && open .build/FrameStack.app` | Release build 8.5 s; ad-hoc signed bundle launched (process alive). GUI checklist in progress with the owner. |
| 2026-11-06 | Owner's Mac | `FRAMESTACK_REAL_CLIPS=… FRAMESTACK_ARTIFACTS_DIR=/tmp/framestack-renders/real swift test --filter RealClipTests` (new opt-in test, debug build) | 4 local clips, **0 missing frames, 0 warnings**, all renders upright, 16-bit sRGB PNGs verified by read-back. Color cross-check of one frame vs `AVAssetImageGenerator`: mean \|Δ\| ≤ 0.03/255, max 1/255 on every clip. Per clip (scan method · frames · 1080 preview · full Average · export · process footprint peak above baseline): **IMG_9656.MOV** iPhone H.264 1920×1080 rotated 90° CW, 59.97 fps VFR (intervals 16.7–18.3 ms): sampleTable · 624 (= ffprobe) · 1.85 s · 2.66 s (235 fps) · 0.92 s · 315 MB. **fireworks-preview-4k.mov** HEVC 2160×3840 untagged color, 15 fps: sampleTable · 180 (container est. 181) · 1.49 s · 2.98 s (60 fps) · 3.50 s · 848 MB. **fireworks-preview-original.mov** HEVC 1080×1920 rotated 90° CCW, VFR 33–133 ms, edit list starts mid-frame → **decode fallback** (0.20 s) · 183 frames (ffmpeg with edit list: 182, without: 188, stored: 191 — FrameStack counts exactly what the AVFoundation decoder delivers) · 0.61 s · 0.80 s · 0.90 s · 174 MB. **file 960x540 …m4v** H.264 29.97 fps CFR: sampleTable · 309 (= ffprobe) · 0.38 s · 0.39 s (802 fps) · 0.23 s · 173 MB. iCloud-only (dataless) Desktop clips could not be downloaded (`brctl download` made no progress), so the Sony 6.7 GB C0036.MP4 stress case is still untested. |
| 2026-11-06 | Owner's Mac, GUI (release bundle) | README checklist, steps 1–3 by the owner's eye; all 7 driven by the agent via `osascript`/System Events + `screencapture -l` (D-015) | **1** IMG_9656.MOV opened via `open -a`: inspector shows name, 1080×1920 (Rotated 90° clockwise), 10.403 s, 59.971 fps (nominal), 624 (scanned), avc1, 31.1 MB, color tags (the "≈ 624 (estimate)" label is visible only until the 0.02 s scan ends). **2** Preview 608×1080 in 3.00 s; bar "624 frames in range → 624 selected"; dense tick band. **3** Start=1 → 564 in range + "Preview outdated" + "Preview pending…" immediately; End=2 → 60; new preview 0.31 s; caption "· 1.000 s"; screenshots show the dimmed/badged old preview then the new one. **4** Every Nth default 2 → 30; N=3 → 20 (0.13 s); Exact Count 20 → 20; 5000 → orange notice "Requested 5000 frames but only 60 are in range; using all 60." **5** synthetic 3840×2160 30 fps 1200-frame clip (ffmpeg testsrc2): Rendering 157/1,200 → Cancel button → idle within 0.2 s; ⌘. and Render › Cancel Rendering likewise; new render accepted at once; RSS ≈ 200 MB, 0 % CPU after cancel. **6** Export PNG… → Save window (standalone panel, not a sheet) → 400-frame 4K export finished in 7 s, inspector "Saved 3,840×2,160, 16-bit, sRGB IEC61966-2.1", file verified with sips. **7** switched to Exact Count (clamped to all 1200) and exported again without re-import: 19 s, verified. **Bugs found and fixed in the same session:** iCloud placeholder hang (D-016); whole render aborting on a damaged frame (D-013); re-committing an untouched time field re-rendered the same selection. |
| 2026-11-06 | Owner's Mac | `swift test` after fixes | **67 tests, 0 failures, 1 skipped** (RealClipTests skips without `FRAMESTACK_REAL_CLIPS`); `corrupt_frame_75.mp4`: 131 composited + 19 missing (frames 73–91), identity of frames 100/149 verified. Damaged real m4v in the GUI: "4911 selected frames could not be decoded: Cannot Decode after 3.003 s (+256 more); gave up after 257 decoder restarts — the file is badly damaged", 73-frame composite shown. |
| 2026-11-06 | Owner's Mac | `swift test --filter FrameStackAppTests` | 8/8 pass in 3.2 s: import/metadata/preview, range edit → outdated preview, sampling modes + clamping notice, cancel preview then render again, cancel loading, missing file message, export → change settings → export again (16-bit then 8-bit, verified), corrupt file reports missing frames in preview and export. |
| 2026-11-06 | Owner's Mac | M2: `FRAMESTACK_ARTIFACTS_DIR=/tmp/framestack-renders swift test` | **85 tests, 0 failures, 1 skipped** (47 core incl. 13 `BlendModeTests`; 29 media incl. 4 `BlendModeRenderTests`; 9 app). Two expectation mistakes fixed while writing (XCTest autoclosures cannot `await`; the moving-square normal-50 % values are 0.5 / 0.75 / 0.375 because each column is covered by two consecutive frames). Fixture renders inspected: `moving_square_lighten` full white trail, `_darken` trail gone + bar intact, `_screen` white trail + bar pushed to ≈ 1 − (1−g)^24, `_multiply` bar g^24, `_normal50` geometric fade toward the last position, `_additive` trail = 2.0 before clipping, `_difference` only the first and last square positions survive. Black/white clip per mode: Average 0.5, Lighten 1, Darken 0, Screen 1, Multiply 0, Difference 1 (0 after 29 frames), Normal = last frame, Normal 50 % = 2/3, Additive 15 (1.5 at 10 %). Count clip: Normal → frame 149 (and frame 120 for a subset ending at 120), Lighten → code 255, Darken → 0. Preview = export for all 8 modes within 0.02. |
| 2026-11-06 | Owner's Mac | M3: `swift test` | **100 tests, 0 failures, 1 skipped** (52 core incl. `TimelineNavigationTests`; 33 media incl. `SourceFramesTests` — exact frame identity for frames 0/1/2/74/75/149 via AVAssetImageGenerator, bounded + oriented, thumbnails distinct/ascending/upright; 15 app incl. frame-range entry, playhead, in/out, snapped drags, undo/redo/grouping, thumbnails, original view, zoom, recents). Fixed while writing: thumbnails with unlimited tolerance collapsed onto keyframes (now half-bin tolerance before the request); preview-quality change did not mark the preview outdated; undo closure must apply synchronously for redo to register; `registerUndo` needs an explicit group when the manager does not group by event. |
| 2026-11-06 | Owner's Mac, GUI (release bundle) | M3 driven with real pointer events (CGEvent helper), keys and menus on IMG_9656.MOV | Drag start handle 235→500 px → Start 2.135 s / First frame 128 / 496 in range; drag end handle → End 6.153 s / Last 368 (a drag started 1 px outside the strip is ignored); click → playhead 273 (4.552 s); → ×3 → 276; I → First frame 276; ⇧← → 266; O → range 266…266 (out before in moves both); Edit › Undo ×2 / Redo restore each step with re-render; Frame › Next Frame → 267. Original view: caption "Original · frame 273 · 4.552 s · 35 %"; Side by Side at Actual Size 100 %, Zoom In ×2 → 200 %, Zoom to Fit → 35 %, Composite. Open Recent lists both opened clips (most recent first) and opens them; Clear Menu present. Collapsing Source via its disclosure triangle hides its 14 texts, `inspector.source.expanded = 0` persists and the section is still collapsed after relaunch. Found and fixed: an `accessibilityLabel` on the disclosure groups made every row read "Source section" to assistive tech. |
| 2026-11-06 | Owner's Mac, GUI (release bundle) | Blend menu driven via accessibility on IMG_9656.MOV (624 frames, 1080 px preview) | Average 2.90 s · Lighten 2.48 s · Darken 2.51 s · Screen 2.94 s · Multiply 2.79 s · Additive 2.92 s · Difference 2.95 s · Normal 2.84 s — all decode-bound, no mode measurably slower than Average (the scalar sequential loop costs < 1 ms/frame at 608×1080). Opacity slider appears for Normal/Screen/Multiply/Additive/Difference only (0 sliders for Average); arrow keys 100 % → 95 % → 75 % each triggered a re-render; Normal 100 % preview is visibly the last frame, 75 % shows the fade. Setting the slider's AX value directly does not reach the SwiftUI binding (same as the text fields, D-015) — keyboard/mouse do. |
