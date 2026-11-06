# FrameStack — Product Requirements Document

**Status:** Working specification for an AI coding agent 
**Version:** 1.0 | **Date:** 2026-11-06 
**Working name:** FrameStack (renameable) 
**Product:** Native, local-first macOS photographic compositing application 
**Intended user:** One photographer/artist initially; possible public release later 
**Guiding principle:** Minimal interface; sophisticated, correct, non-destructive controls

---

## 0. Instructions on how to use this document

This is the source of truth for product behavior, not a demand to implement every feature immediately. The coding agent should read this with `AGENTS.md`, audit the repository/environment, produce a dependency-aware milestone plan, then implement and verify the app incrementally. The agent may make reasonable implementation choices, but must track deviations from this PRD, provide testable milestones, and avoid silently dropping advanced features. Do not treat a green build as proof that photographic results are correct.

The owner wants a **personal creative tool first**. Prioritize usable photo-making workflows over app-store onboarding, analytics, accounts, collaboration features, monetization, or marketing. Keep the architecture modular enough that distribution could be added later, but do not spend early development time on it.

**Ambiguities requiring confirmation only if they block implementation:** exact macOS and processor of the owner's target Mac, Xcode version, and whether source/output examples can be provided. Otherwise make documented, reversible defaults and proceed.

## 1. Product vision

Transform time into a still image. The user imports a video—or eventually a folder/sequence of photographs—selects which moments to include, chooses how those moments are combined, previews the image, refines it through optional alignment/masking/weighting/color/crop controls, and exports a high-quality photograph. The app is a **still-image creation tool**, not a video editor.

### Core example

A **5-second constant-frame-rate video at 30 fps** has **150 frames** with frame timestamps from approximately 0 to 4.966… seconds. The user can stack all 150, take every 2nd (75), take every 3rd (50), or select an exact count evenly distributed over a chosen interval. Selecting **[2.0, 5.0) seconds** yields about 90 eligible frames and selecting every 3rd yields 30. Variable-frame-rate footage and timestamp boundaries require actual stream metadata/decoding rather than assuming `duration × nominalFPS` is an exact frame count.

### Use cases

- Long-exposure-like average composites, ghost trails, and temporal softening.
- Light painting/night lights with Lighten or Additive modes.
- Chronophotography: visible multiple positions of a moving subject.
- Abstract images via Difference, Screen, Multiply, and temporal selection.
- Sharp stationary background with selected moving foreground elements.
- High-resolution capture sequences from dedicated still cameras.

### Non-goals (initial development)

Video editing, transitions, audio processing, subscriptions, accounts, sharing platforms, public release engineering, cross-platform parity, collaborative editing, and automatic generative AI content. Automatic semantic object segmentation is optional research, **not** required for the core engine.

## 2. Principles and priorities

1. **Correctness:** frame identity, order, color and blend mathematics, alignment/masks, and exports must be verifiable.
2. **Creative control:** no unnecessary artistic restrictions; preserve source-independent parameters and make choices reversible.
3. **Local-only:** no upload or online service; ideally no runtime network dependencies.
4. **Performance with bounded resources:** process large sources without loading thousands of full-resolution frames into RAM.
5. **Visual simplicity:** quick basic workflow, progressive disclosure for advanced controls.
6. **Resumable implementation:** phase-by-phase development with tests, notes, and explicit completion criteria.

**Priority tiers**: `P0` required for a first useful prototype; `P1` central to a solid personal creative tool; `P2` advanced artistic expansion; `P3` future experiments. No P2/P3 feature may prevent completion of a working P0 baseline.

## 3. End-to-end user journeys

### Journey A — Quick stack (P0)

1. Drag a `.mov` or `.mp4` into the window (or choose File > Open).
2. See filename, dimensions, duration, frame-rate information, and a preview.
3. Keep entire time range; choose All Frames or Every Nth or Exact Count.
4. Choose Average; see preview and actual selected frame count.
5. Choose Export, see a progress indicator, save full-resolution PNG.
6. Continue editing without re-importing.

### Journey B — Experiment with time and blend (P1)

1. Trim to an interval on a filmstrip/timeline with numerical time fields.
2. Sample exactly 20 frames distributed across the interval; inspect sample markers.
3. Switch Average → Lighten → Difference, compare visual results.
4. Modify opacity or temporal weighting where relevant.
5. Export multiple looks, preserving project settings.

### Journey C — Refined movement study (P2)

1. Import a handheld clip or image sequence; enable alignment.
2. View/correct the safe crop and choose a background reference.
3. Enable motion mask with threshold/feather, invert or paint mask corrections.
4. Tune temporal weighting and motion-accumulation options.
5. Export 16-bit TIFF with documented color settings.

### Journey D — Repeatable artwork (P1/P2)

1. Save editable project referencing source files rather than duplicating media.
2. Close/reopen; all settings and output appearance are preserved.
3. If media moved, locate/relink it; never silently replace with a different file.
4. Optionally batch-export named variations/presets.

## 4. Sources, import, and metadata

### 4.1 Video import (P0)

- Local file chooser, drag-and-drop, Recent Files as a convenience (P1).
- Support formats/codecs **actually supported by the host's AVFoundation stack**, prioritizing H.264/H.265 within MOV/MP4. Surface unsupported-codec errors clearly; container extension alone does not guarantee decoding.
- Show filename, duration, pixel dimensions, orientation/display transform, nominal FPS if known, and estimated/actual selected frame count.
- Respect video track transforms, sample aspect ratio if relevant, and color metadata.
- Ignore audio for compositing.
- Import should not copy the entire video into the project.
- Frame count may be unknown/estimated until scanned. Label estimates honestly and update once known; avoid displaying a fabricated exact count.

### 4.2 Image sequence import (P1 architecture; P2 complete UI)

- Select multiple images or a folder; support JPEG, PNG, TIFF, HEIF where decodable.
- Sort files naturally by filename by default; allow reverse order and manual sort/reordering later.
- Use a synthetic time axis derived from ordered frame index and user-defined interval/FPS when timestamps are absent; **label this as sequence time**, not recorded video timestamps.
- Define and show a consistent policy for differing dimensions, orientation, alpha, color spaces, and aspect ratios: normalize each to canvas via fit/fill, alignment anchor, or error. Do not silently stretch sources.
- RAW still support (including Sony RAW formats as supported by macOS) is a later P2 exploration; test carefully with image decode costs and color management. Never promise universal RAW compatibility.

### 4.3 Timing/selection model (P0)

- Represent time with precise timestamps/rational time types (e.g., `CMTime`), not accumulated floating-point frames.
- Define selected range as **start inclusive, end exclusive** `[start, end)` to avoid off-by-one at clip end. User-facing timeline may show an inclusive-looking end handle, but internal behavior must be documented.
- Source samples are selected by their actual presentation timestamps. Address variable frame rate, repeated timestamps, edit lists, and dropped/corrupt frames deterministically.
- Frame selection modes (mutually exclusive):
  - **All:** every available frame in the selected interval.
  - **Interval:** every Nth *eligible decoded frame*, starting with the first (N >= 1).
  - **Exact Count:** K distinct eligible frames evenly distributed across the interval. For K>1 include first and last eligible frames, using a deterministic index distribution; for K=1 select the midpoint. If K > eligible count, clamp with notice or prevent invalid input; never silently duplicate frames.
- Show number of source frames where known, number selected, range duration, and a marker/filmstrip representation (markers P1).
- Numeric entry for start/end, frame interval, and exact target count; drag handles on timeline (timeline refinement P1).
- Ability to scrub source video to see the original frame at cursor (P1).
- P2: manually include/exclude specific frames and choose custom sampling patterns.

## 5. Compositing math and semantics

### 5.1 Mandatory shared behavior

- Operate on aligned, orientation-normalized images in a documented **working color space**. Use floating-point intermediates sufficient for large stacks; avoid 8-bit repeated round-off.
- Define alpha and transparent-pixel behavior. Opaque video sources are typical, but still sequences may include alpha.
- Keep **equal-weight Average** distinct from alpha-over stacking; they are not the same algorithm.
- Declare whether blend math is computed in linear light or in an encoded RGB space. Default recommendation: **linear-light working space for physically meaningful Average/Additive**, with an optional/display-oriented legacy/creative mode later; whichever is implemented must match preview and export and be regression-tested. Preserve source color profile or explicitly convert to export space.
- Operations that depend on order use chronological order (oldest to newest) unless Reversed is selected (P2).
- Do not hold all decoded full-res frames simultaneously. Stream one decoded frame (or a bounded tile/batch) through the operation; maintain accumulators only as necessary. Some modes may require a second pass or staging cache.
- Verify each blend mode against tiny known input arrays plus real test clips. Document clamping, weights, and alpha policy.

### 5.2 Blending modes

| Mode | Priority | Expected behavior | Key caveat |
|---|---|---|---|
| **Average** | P0 | Each selected sample contributes equal weight; final pixel equals channel-wise sum divided by count, unless alpha-specific policy is used. | Distinguish equal temporal averaging from sequential opacity. |
| **Lighten (per-channel max)** | P1 | Channel-wise maximum across selected frames. | May yield colors absent from any individual source pixel. |
| **Darken (per-channel min)** | P1 | Channel-wise minimum across frames. | Same per-channel caveat. |
| **Screen** | P1 | Sequential screen blend of the selected frames; define precise starting frame and treatment of opacity. | Not mathematically the same as max/lighten; more frames can wash out image. |
| **Multiply** | P1 | Sequential multiplication of normalized channels. | Many frames may approach black. |
| **Additive** | P1 | Accumulate light contributions; configurable normalization/exposure later. | Must explicitly handle highlight clipping/overflow and color-space choice. |
| **Difference** | P1 | Sequential absolute difference of incoming frame and current composite. | Result is order-dependent; not equivalent to a variance image. |
| **Normal/Opacity Stack** | P1 | Chronological Porter–Duff source-over with uniform opacity parameter. | At 100% opacity for opaque frames, only the last selected frame is visible. |
| **Median** | P2 | Per-pixel statistical median across time. | Streaming exact median requires more memory, tiled multi-pass, or alternate algorithm; must not present approximation as exact. |
| **Maximum/minimum luminance** | P2 | At each pixel choose complete RGB color from frame with greatest/least calculated luminance. | Distinct from per-channel Lighten/Darken. |
| **Motion accumulation / chronophotography** | P2 | Isolate motion and composite foreground positions against a chosen background frame/composite. | Requires robust background model/masks and artifact handling. |

**Mathematical transparency:** Surface mode descriptions in small info/help text; clearly distinguish equal-weight blend vs layered compositing vs movement extraction.

### 5.3 Temporal weighting (P2)

- Select Flat (default), Favor Early, Favor Late, Favor Middle, or Custom Curve.
- Define a continuous nonnegative weight function across normalized timeline 0–1. Normalize weights for weighted Average unless intentionally using exposure accumulation. Prevent zero-total-weight errors.
- Provide a simple editable curve with presets; advanced curve editing should not clutter the basic view.
- Preview visualizes weighting distribution/selected samples; weights are based on selected frame timestamps (not assumptions about constant FPS).
- P2: reverse sequence; ping-pong duplication only by explicit user choice; temporal range segmentation.

## 6. Geometry, alignment, crop, and masks

### 6.1 Alignment/stabilization (P2)

- Optional off by default; compensate for handheld camera drift before blending.
- Start with global translation (potentially Vision image registration), then consider affine/homography for perspective/rotation if robust. Avoid claim of perfect alignment for parallax, moving backgrounds, rolling shutter, etc.
- Let user choose reference frame or use a documented automatic reference (e.g., middle frame).
- Prefer static features and ignore obvious moving subjects where possible; track failures and offer an informative fallback.
- Provide before/after and on/off comparison. Preserve frame transforms non-destructively.

### 6.2 Crop and edges (P2)

- Support Fit, Fill, and manual crop/straighten. Preserve image aspect ratio unless user intentionally changes it.
- For post-alignment gaps: `crop-to-common-valid-area` and `transparent/solid edge fill` as explicit options; content-aware fill later only if warranted.
- Show safe crop overlay. Avoid exporting accidental black borders without the user's informed choice.

### 6.3 Motion masking (P2)

- Start with a simple, transparent method: build or choose a background reference (single frame or temporal median where practical), calculate per-pixel difference, threshold, feather, and optionally morphologically clean mask. Support sensitivity and invert.
- Composite moving regions over a background, optionally showing a mask preview. **Do not promise semantic recognition** in the MVP.
- Masking should be optional and non-destructive. State limits for complex camera motion or lighting changes.
- Eventually allow different blend modes for foreground/background or regions.

### 6.4 Manual masks (P2)

- Paint/erase a mask on the final canvas; brush size, softness, undo/redo, mask overlay, and inversion.
- Specify whether mask applies to contribution of the time composite vs background, or per-frame/region (latter is P3); keep initial mental model simple.
- Store mask vector strokes or a resolution-appropriate raster mask in project file. Avoid silently losing it on reopen.

## 7. Color and finish (P1/P2)

- Prefer reliable ICC/ColorSync/Core Image pipeline and proper source metadata handling (P1 engineering).
- Preview and full export should use same working space/mathematics; reduced preview may differ by resampling, but not algorithm.
- P2 adjustments: exposure, contrast, saturation, white balance/tint, optional curves. Explicitly identify before-composite vs after-composite adjustments and define stacking order. Start with **post-composite** adjustments for consistency and performance.
- Optional per-frame preprocessing later, clearly labeled and possibly more expensive.
- P2 export: 16-bit TIFF (proper channel depth), embedded profiles, intended handling of wide-gamut/HDR/video log sources. Standard SDR first; warn when source is HDR/log or preserve/convert via a defined path.
- Avoid misleading output naming: PNG/JPEG may be 8-bit; do not claim otherwise until tested by reading exported file metadata.

## 8. UX and visual design

### 8.1 Main window

Proposed default layout:

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ File  Edit  View  Project                    [Preview quality] [Export…]     │
├───────────────────────────────────────────────┬──────────────────────────────┤
│                                               │ Source                       │
│          LARGE COMPOSITE PREVIEW              │   [video info / relink]      │
│                                               │ Time Range                   │
│     zoom / pan / compare / mask view          │   [start]  [end]             │
│                                               │ Sampling                     │
│                                               │   [All|Nth|Exact] [value]    │
│                                               │ Blend                        │
│                                               │   [mode] [opacity if used]   │
│                                               │ ▸ Alignment [advanced]       │
│                                               │ ▸ Temporal Weighting         │
│                                               │ ▸ Mask / Crop / Color        │
├───────────────────────────────────────────────┴──────────────────────────────┤
│ video filmstrip / range handles / sampled frame markers                      │
│ [scrub] [in-out]   150 eligible → 50 selected        [Render] [status]       │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 8.2 Interaction requirements

- SwiftUI-first, native macOS look; standard menu commands, undo/redo for edit operations (P1), accessible labels, keyboard focus, and keyboard shortcuts where natural.
- Avoid modal busywork. Source import, settings changes, and rendering must not block UI.
- Inspector sections collapsible, with progressive disclosure. Keep Average, range, and sampling quickly accessible.
- Zoom to fit, 100%, pan, and background checkerboard for alpha (P1).
- Original/composite toggle and side-by-side comparison (P1); optional two-mode compare later.
- Throttled/debounced preview refresh on slider drag; cancel stale work; explicit Render/Export for expensive full-resolution processing.
- Human-readable progress (e.g., frames processed/total where knowable), cancellation, recoverable error descriptions, and state when preview is outdated.
- No false progress or fabricated timing estimates.

## 9. Project saving, presets, batch processing

### 9.1 Non-destructive document (P1)

- Versioned local project format (`.framestack` package or JSON/plist-based document, exact format agent to propose).
- Store source file references/bookmarks, source fingerprint/hash/size as practical, selected time range, sampling mode, selected frame IDs/timestamps (or deterministic policy), blend mode, temporal weights, transforms, mask strokes/data, crop/color settings, export settings, schema version, and UI state if useful.
- No video duplication by default. On reopen, validate source and offer relinking when missing/changed. Warn rather than quietly using new content.
- Store only information sufficient to reproduce same image and user-editable choices; make format migration plan as schema evolves.
- Allow Save, Save As, Open; auto-save later if useful.

### 9.2 Presets (P2)

- User-defined creative presets containing reusable settings without hardcoding source file identity or an absolute timeline.
- Apply to new source with clear behavior for incompatible parameters (e.g., range beyond duration).

### 9.3 Batch variants (P2)

- Export multiple blending methods/parameter presets for same source/range to chosen folder, with deterministic, collision-safe filenames.
- Reuse decoded data/cache where safe; process within bounded memory.
- Batch cancellation and per-output status.

## 10. Preview, performance, architecture

### 10.1 Preview (P0/P1)

- Low-resolution working preview (e.g., 1080-ish long edge by default; adaptive) for quick feedback; switch quality deliberately.
- Image processing results are immutable snapshots keyed by a settings revision; never display a stale preview as current without indication.
- Cache only bounded decode/intermediate data; define invalidation for changed source, trim, sampling, blend, color, or geometry.
- Avoid rebuilding every frame when only post-composite color changes if cached composite exists.

### 10.2 Full render (P0/P1)

- Native output dimensions by default, output resizing selectable, progressive feedback, cancellability, and a resource-safe processing path.
- Prefer streaming reduction and bounded Metal textures/buffers for Average/Lighten/Darken. Screen/Multiply/Difference/Over process sequentially; median and certain masks may require tiles, repeated passes, or bounded disk cache.
- Optimize after measuring. Metal acceleration may help; **do not require** a custom Metal kernel before a correct CPU/Core Image prototype exists.
- Work must be asynchronous (Swift concurrency or appropriate queues); UI updates on main actor.
- Handle GPU/device loss/memory pressure and file read errors gracefully.

### 10.3 Proposed modules (names indicative)

- `SourceDocument` / `SourceImporter`: media loading, validation, metadata, relink.
- `FrameTimeline` / `FrameSampler`: precise selected indices and timestamps.
- `FrameDecoder`: lazy sample delivery; AVFoundation for video, ImageIO/Core Image for stills.
- `PixelPipeline` / `Compositor`: mathematically defined blending; stateful reducer and image tiles.
- `RegistrationEngine`: image alignment and transforms.
- `MaskEngine`: background/motion/manual masks.
- `ColorPipeline`: transforms and adjustments.
- `PreviewCoordinator`: cancellation, debounce, caching, revision state.
- `ExportService`: image format conversion, metadata, file saving, progress.
- `ProjectStore`: versioned document and presets.
- `AppUI`: SwiftUI window, inspector, filmstrip, keyboard commands.

Do not over-abstract during P0; add clean interfaces to support future features.

### 10.4 Deployment assumptions

- Native macOS via Swift/Xcode/SwiftUI; AVFoundation, Core Image, ImageIO, ColorSync, Accelerate, Metal, and Vision where appropriate.
- Focus on the owner's development Mac. Agent should inspect actual macOS/Xcode/CPU and select a reasonable deployment target based on facts; **do not invent hardware specifications**. Apple Silicon acceleration is desirable but app should not silently depend on a specific GPU without verification.
- Local/direct launch from Xcode is sufficient early. Signing, notarization, sandbox restrictions, installer, crash reporting, and App Store compatibility are possible later release work; keep file access behavior explicit.
- No network dependency, user account, cloud sync, tracking, or telemetry.

## 11. Validation strategy and quality bar

### 11.1 Tests that must exist

**Pure sampler tests:** Given known list of presentation times, assert range filtering, All, Nth, exact target K, K=1, K>M handling, exact boundaries, VFR intervals, and absence of duplicate frames.

**Blend-unit tests:** 1×1 and small synthetic RGB/alpha arrays with known results for Average, Lighten, Darken, Screen, Multiply, Additive, Difference, Normal; include two-frame and large-frame-count precision tests. Store expected outcomes as fixed reference values independent of rendering implementation.

**Color tests:** Distinguish average in linear vs gamma-encoded space with fixed expected values; check color-profile conversions, alpha semantics, 8/16-bit outputs where supported.

**Import/geometry tests:** Portrait rotation, varying dimensions, short/corrupt clips, invalid ranges, missing source, canceled processing, PNG/TIFF output dimensions and bit depth.

**Visual regression/smoke tests:** Render a few deterministic generated clips (moving square, stationary background, bright point moving on dark background, moving silhouette) to reference composites and compare pixels or explain tolerances. Visually inspect actual photographic examples too.

**Performance/stress tests:** 150, 1,000, and larger frames at useful resolutions; record memory high-water mark, render time, and UI responsiveness. Do not impose arbitrary guarantees on unknown hardware; track baseline and prevent obvious regressions. Assert cancellation and no unbounded memory growth.

### 11.2 Manual acceptance scenarios

- 5 s / 30 fps CFR => about 150 source frames, All=150, N=2 => 75, N=3 => 50. [2,5) => about 90 and N=3 => 30. Confirm with decoded sample timestamps (exact count may differ for real videos).
- Selecting 20 frames over selected interval includes endpoints (when there are at least 20 frames) with evenly spaced indices; no repeated frames.
- Average of repeated identical frames reproduces the source frame apart from predictable color/export rounding.
- Lighten preserves bright trails; Darken preserves dark trails in controlled synthetic test.
- Normal at 100% opacity yields last selected opaque frame; Average yields a mix, not last frame.
- Changing sampling/blending leads to updated preview matching the eventual export within documented preview resolution/color tolerances.
- Cancel render and continue using app without forced quit.
- Save project, quit, reopen; source references/settings restored and image reproduced.
- Import hundreds or thousands of frames without memory proportional to storing all full-res decoded frames simultaneously.

## 12. Milestones and required exit criteria

Plan milestones by dependencies, not calendar estimates. Each milestone must end with: a runnable app or testable module, compilation/test results, a brief demo or screenshot where feasible, explicit known limitations, updated plan, and a git commit if repository permits. It is acceptable to spread milestones over several coding-agent sessions.

### M0 — Environment and architecture

Confirm toolchain, target Mac, available repo, source media/test-fixture availability. Initialize native macOS project, README, directory layout, tests, and issue/plan tracker. Document key choices and unresolved risks. **Exit:** clean native app builds and tests execute.

### M1 — Core vertical slice (P0, mandatory before any ambitious features)

Import a video; display metadata; choose `[start,end)` and All/Nth/Exact; extract actual frames; produce correct equal-weight Average preview; export full-resolution PNG; render asynchronously with progress/cancel. **Exit:** real 5 s/30 fps clip and synthetic tests pass, including actual file export.

### M2 — Essential creative blending (P1)

Lighten, Darken, Screen, Multiply, Additive, Difference, Normal/Opacity; consistency of preview/export; mode info text; tests. **Exit:** verified numerical reference cases and visual fixture renders for each mode.

### M3 — Minimal, polished artist workflow (P1)

Timeline/filmstrip, sampling markers, scrubbing, zoom/pan, original/processed comparison, collapsible inspector, undo-friendly non-destructive settings, keyboard/file UX. **Exit:** user can interactively create and export images without command-line work.

### M4 — Robust output and state (P1)

PNG/JPEG/TIFF, reliable color management, output sizing, project saving/reopening/relinking, crash/error handling, streaming stress tests. **Exit:** reproducible projects and bounded-memory exports with tested metadata.

### M5 — Source and geometry expansion (P2)

Image sequences, optional still RAW research, alignment, crop/edge handling; regression fixtures. **Exit:** mixed source types and alignment example demonstrably work, with limitations documented.

### M6 — Advanced creative controls (P2)

Temporal weighting and curve editor; motion detection/masking, manual masks, motion accumulation; post-composite color adjustments; 16-bit TIFF where feasible; presets, batch variants. This phase may be subdivided substantially. **Exit:** each feature independently testable, non-destructive, and reproducible.

### M7 — Optional release preparation (deferred)

Only if owner later decides to share publicly: distribution, packaging/signing/notarization, accessibility audit, onboarding, documentation, wider hardware compatibility. **Not a requirement for the current project.**

### Milestone ordering note

The agent may split/rearrange M3–M6 to honor dependencies, but must not skip or hide any requested P2 features. If a feature is infeasible with the selected approach, show evidence, propose a fallback, and record it as a decision requiring owner approval.

## 13. Definition of done

A feature is **done** only when: (1) implemented in the product, (2) demonstrated using real or deterministic generated media, (3) covered by meaningful automated tests when testable, (4) UI remains responsive during relevant processing, (5) errors/cancellation considered, (6) known limits documented, and (7) project plan updated. A feature is not done because the code compiles or a mock UI exists.

The **initial useful app** is achieved at M1; the **solid personal creative tool** at M4; the **advanced artistic vision** at M6. The owner should get a runnable build at each meaningful milestone, not wait for every feature.

## 14. Open decisions and sensible defaults

| Topic | Default for implementation | Revisit when |
|---|---|---|
| App name | FrameStack (placeholder) | Owner wants another name |
| Target machine / macOS | Detect actual target environment before deciding deployment target | Before Xcode project configuration |
| Source input | MOV/MP4 video first; still sequence architecture extensible | M5 |
| Range policy | `[start,end)` based on actual timestamps | If UI causes confusion |
| Sampling | All, every Nth, exact evenly distributed count | When custom selection is added |
| Blend default | Equal-weight Average, linear-light float accumulation | User requests another color/mathematical aesthetic |
| Frame order | Chronological | P2 order controls |
| Alignment | Off | User opts in for handheld sources |
| Masking | Off | User opts in and chooses background |
| Export | Native-size PNG in M1 | M4 JPG/TIFF, M6 higher bit depth |
| Project storage | References source media; versioned non-destructive settings | M4 implementation design |
| Distribution | Run from Xcode, local-only | Potential public launch |

## 15. What not to do

- Do **not** build an impressive UI around fake or hard-coded processing.
- Do **not** infer exact frame counts by multiplying duration and nominal FPS alone.
- Do **not** average successive sRGB 8-bit images with repeated rounding and call it accurate.
- Do **not** treat Average as normal opacity compositing.
- Do **not** silently cap frame counts, duplicate frames, downscale exports, or change color space.
- Do **not** hold every full-resolution frame in memory for large inputs.
- Do **not** ship a mode with mathematically undefined or undocumented behavior.
- Do **not** silently omit advanced capabilities because they are difficult; phase them and document status.
- Do **not** add cloud/auth/account/distribution infrastructure for this personal-use build.
- Do **not** optimize prematurely at the expense of verifiable output.

---

**One-sentence success criterion:** A photographer can reliably turn any supported video or image sequence into a precisely sampled, customizable, high-quality, reproducible still-image composite, with a simple initial experience and advanced controls available when needed.
