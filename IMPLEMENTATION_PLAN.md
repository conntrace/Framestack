# FrameStack — Implementation Plan

Living checklist (AGENTS.md §2). Status keys: `[x]` done and verified · `[~]` implemented, verification pending or partial · `[ ]` not started.
"Verified" means the stated validation actually ran (CI run or owner's Mac) — see the log at the bottom.

## Current status (update every session)

- **Milestone:** M1 — core vertical slice. **Engine verified on macOS CI; GUI awaiting the owner's manual pass.**
- **Last CI:** run 42248417651 on commit 8126110 — macOS 15.8.2, Xcode 16.4, Swift 6.1.2, Apple M1 (virtual): debug build OK, **56/56 tests passed**, release `.app` bundle built.
- **Next task:** Owner runs the README "Manual verification" checklist on their Mac and reports issues → fix → mark M1 done. Then M2: generalize the reducer in `FrameStackCore/Compositing.swift` and add Lighten/Darken first (streaming, simplest), with 1×1 reference tests and fixture renders.
- **Blockers / open questions for owner (non-blocking):** target Mac model + macOS + Xcode version (D-003); a few real clips (phone + camera; one portrait; one 10-bit/HDR) for photographic acceptance; whether to create a `main` branch so work can go through pull requests (the repo currently has only `claude/determined-planck-58a6hw`).

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

App UI (compiles; not exercisable in CI — owner manual pass):
- [~] Open panel + drag & drop; inspector source info; estimate → scanned count
- [~] Range fields (µs precision) + Full Clip; sampling controls; "N in range → K selected"; timeline strip with sample ticks
- [~] Debounced (250 ms) cancellable preview, "Preview outdated" indicator, progress + Cancel, 1080/2160/Full quality
- [~] Export panel, progress + Cancel, verified result summary, Show in Finder
- [ ] Owner manual GUI pass (README checklist)
- **Exit:** real 5 s/30 fps clip + synthetic tests incl. actual file export — **met on CI**; GUI pass by owner pending.

## M2 — Essential creative blending (P1)
- [ ] Generalize reducer protocol (`accumulate(frame)`, `finish()`), chronological-order guarantee (renderer already reports `deliveredInPresentationOrder`; enforce for order-dependent modes)
- [ ] Lighten / Darken (per-channel max/min; streaming)
- [ ] Screen, Multiply (sequential, defined start frame, opacity semantics documented)
- [ ] Additive (sum; exposure/normalization parameter; overflow kept in float, clipped only at export)
- [ ] Difference (sequential |frame − composite|, order-dependent)
- [ ] Normal / Opacity stack (Porter–Duff source-over with uniform opacity; 100% → last frame)
- [ ] Blend picker + per-mode info text + opacity control where meaningful
- [ ] Tests: 1×1/small-array references for every mode (two-frame + large-count), fixture renders per mode (moving square, bright point on dark), "Normal 100% = last frame, Average ≠ last"
- **Exit:** numerical reference cases + visual fixture renders per mode.

## M3 — Minimal, polished artist workflow (P1)
- [ ] Filmstrip thumbnails, draggable in/out handles, sample markers (strip exists; add interaction)
- [ ] Scrub source frame at cursor; original/composite toggle; side-by-side compare
- [ ] Zoom to fit / 100% / pan; checkerboard for alpha
- [ ] Collapsible inspector sections, progressive disclosure
- [ ] Undo/redo for settings; keyboard shortcuts; Recent Files
- [ ] Frame-accurate entry (frame number ↔ time), step to prev/next frame
- **Exit:** create and export images entirely interactively.

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
| — | — | GUI | Not executed anywhere yet (no display in CI) — owner checklist in README. |
