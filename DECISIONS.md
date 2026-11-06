# FrameStack — Decision Log

Format: date · decision · alternatives · reason · revisit when. PRD deviations are marked **[PRD deviation]**.

---

### D-001 · 2026-11-06 · Development and verification environment
- **Decision:** The first session ran in a Linux cloud container (Ubuntu 24.04, x86_64) with **no macOS, no Xcode, and no Swift toolchain** (the swift.org download host is blocked by the container's network policy). Code is written there; **all compilation and tests run on GitHub Actions `macos-15` runners** (`.github/workflows/ci.yml`), and only CI results are reported as verified.
- **Alternatives:** Scaffold without any build (rejected: the kickoff forbids claiming unverified work); install Swift for Linux (blocked; would not cover AVFoundation/Core Image/SwiftUI anyway).
- **Reason:** CI runs the real Apple frameworks (AVFoundation decode, Core Image, ImageIO) end-to-end on fixtures. It cannot exercise interactive GUI behavior — that needs the owner's manual checks (README "Manual verification").
- **Revisit when:** The owner builds on their own Mac, or a session has direct macOS access.

### D-002 · 2026-11-06 · Swift Package instead of an `.xcodeproj`
- **Decision:** A SwiftPM package with three modules — `FrameStackCore` (pure engine), `FrameStackMedia` (AVFoundation/Core Image/ImageIO), `FrameStack` (SwiftUI app) — plus two test targets. Opens directly in Xcode (`open Package.swift`); `scripts/make_app_bundle.sh` wraps the release binary in a local `.app`.
- **Alternatives:** Hand-written `.xcodeproj` (unreviewable, cannot be generated reliably without Xcode); XcodeGen/Tuist (extra dependency).
- **Reason:** Text-only, diffable, builds headless in CI, no third-party tooling, and Xcode supports it natively.
- **Revisit when:** We need bundle features SwiftPM executables lack: document types for `.framestack` projects (M4), sandbox/entitlements/icons (M7). Then add an Xcode app target that depends on the same packages.

### D-003 · 2026-11-06 · Deployment target macOS 14 (confirmed on the owner's Mac)
- **Decision:** `platforms: [.macOS(.v14)]`, Swift tools 5.9 (Swift 5 language mode). Unchanged after inspecting the real machine.
- **Owner's Mac (inspected 2026-11-06, second session):** macOS **27.0** (build 26A428), **Apple M4 Pro** (arm64, 12 CPU cores, 16-core GPU, Metal 4), 24 GB RAM, 59 GB free on a 460 GB disk, 3024×1964 Retina display. Full **Xcode 27.0** (27A266a) at `/Applications/Xcode.app` is the selected toolchain; **Swift 6.4**. Homebrew ffmpeg/ffprobe and Python 3 with numpy 2.4.2 are present, so `scripts/make_fixtures.py` can run locally.
- **Alternatives:** macOS 13 (loses nothing essential yet, but 14 gives `NSApp.activate()`, newer SwiftUI); macOS 15/26/27 as the floor (would only remove compatibility; nothing in the code needs newer APIs).
- **Reason:** The code builds and the tests run with both Xcode 16.4 (CI, macOS 15) and Xcode 27.0 (owner's Mac) against the macOS 14 target, so there is no fact that forces a change. Keeping 14 keeps CI's macOS 15 runners valid. Building with Xcode 15 itself is still untested.
- **Revisit when:** A feature needs a newer API (e.g. newer SwiftUI or AVFoundation calls), or CI runners move past what the target supports.

### D-004 · 2026-11-06 · Working color space and Average math
- **Decision:** Each decoded frame is interpreted by **Core Image using the buffer's own color tags** (YCbCr matrix, primaries, transfer function), orientation-corrected, and rendered to **extended linear sRGB (Rec.709 primaries, D65), Float32 RGBA, premultiplied**. Average = per-channel `sum / N` with **Float64 accumulators** (vDSP), so N identical frames reproduce the frame bit-exactly and no 8-bit rounding happens between frames. Preview and export run the identical pipeline; preview only adds a Lanczos downscale in linear light before accumulation (linear ops commute with averaging).
- **Alternatives:** Averaging gamma-encoded values (what naive tools do; visibly darker trails — e.g. a 2-of-24 white trail becomes 21/255 instead of 82/255). May be offered later as an explicit creative "display-referred" option (PRD §5.1).
- **Reason:** PRD §5.1/§14 default; physically meaningful long-exposure look.
- **Notes:** For BT.709-tagged video, the linearization curve is whatever Core Image/ColorSync assigns to that tag — the same interpretation QuickTime Player uses for display. Tests are written to be independent of that choice (black/white, relative and same-pipeline comparisons). HDR (HLG/PQ) sources are flagged with a warning; highlights above SDR white are clipped at export.
- **Memory:** accumulator = `W × H × 4 × 8` bytes (4K ≈ 265 MB) + one Float32 frame (≈ 133 MB), independent of frame count.
- **Revisit when:** M4 color-management work (Display P3 export, 10-bit decode), M6 HDR handling, or the owner asks for a gamma-space look.

### D-005 · 2026-11-06 · M1 export: PNG, sRGB, 8- or 16-bit RGB
- **Decision:** Linear → clamp each channel to [0,1] → IEC 61966-2-1 sRGB transfer (Float64) → round to nearest → 8- or 16-bit RGB PNG tagged sRGB. Default **16-bit** (smooth averages band in 8-bit). No dithering, no alpha channel. A composite with any alpha < 0.999 is **rejected** rather than silently flattened. Files are written to a temp file and atomically moved into place, then **read back** to verify dimensions and bit depth.
- **Alternatives:** Embedding the linear data in a float TIFF/EXR (later, M4/M6); Display P3 output (M4).
- **Reason:** PRD §14 (native-size PNG in M1) and §7 (never claim a bit depth not verified by reading the file).
- **Revisit when:** M4 (JPEG/TIFF, wide gamut, alpha), M6 (16-bit TIFF with profiles).

### D-006 · 2026-11-06 · Frame identity, scanning and ranges (revised after first CI run)
- **Decision:** A frame **is** the presentation timestamp the **decoder** reports (`FrameTime`, exact rational, 128-bit cross-multiplied comparisons). On import, the track's compressed samples are read with `AVAssetReader` passthrough (no decode) and **mapped through the track's edit list** (`AVAssetTrack.segments`): a sample at media time *m* inside a segment's source range is presented at `m − source.start + target.start`; samples outside every segment are not presented. If any segment changes speed, an edit starts mid-frame, or the CMTime arithmetic would round, the scan **falls back to decoding every frame** and uses the decoder's timestamps. Samples flagged *DoNotDisplay* are skipped; duplicate timestamps keep the first sample. Until the scan finishes the UI shows `duration × fps` labeled "estimate". Ranges are `[start, end)`. Rendering decodes only `[first selected, last selected]`, matches decoded frames by exact timestamp, and **reports** any selected timestamp that never decodes (`missingFrames`) instead of substituting another frame.
- **Evidence:** The first CI run showed passthrough sample timestamps are in *media* time while decoded frames are in *presentation* time: on the B-frame fixture (ffmpeg writes an edit list with a 2-frame offset) timestamp *k* decoded frame *k + 2* and the last two timestamps were reported missing. The frame-index fixture and missing-frame reporting caught it. A test now requires the fast scan to equal the decode scan on every fixture, including a stream-copied trim (`trimmed_editlist.mp4`, frames 30–44 stored but outside the edit).
- **Alternatives:** Always decode during scan (exact but slow on long clips — kept as the fallback and as the test reference); `AVSampleCursor` (media timeline, same problem).
- **Reason:** PRD §4.3 — actual timestamps, edit lists and VFR handled deterministically, no fabricated counts.
- **Revisit when:** A real clip triggers the decode fallback often enough to make import slow, or reports missing frames.

### D-007 · 2026-11-06 · Exact Count distribution
- **Decision:** Over M eligible frames, position_i = round_half_up(i·(M−1)/(K−1)) for i in 0..<K (exact integer arithmetic). K = 1 picks index ⌊(M−1)/2⌋ (lower middle for even M). K > M selects all M frames and shows a notice. Distribution is **by index**, not by time (identical for constant frame rate; for VFR footage this means "every k-th frame", not "every k seconds").
- **Reason:** PRD §4.3 ("deterministic index distribution", endpoints included, never duplicate).
- **Revisit when:** Custom/time-uniform sampling patterns (P2).

### D-008 · 2026-11-06 · Preview scheduling
- **Decision:** Any settings change bumps a revision, recomputes the selection synchronously, and schedules a preview render after a 250 ms debounce, cancelling the previous one. Snapshots carry the revision they were rendered for; an older snapshot is dimmed and labeled "Preview outdated". Preview resolution: 1080 px long edge (default), 2160 px, or full. Export always renders at native resolution and cancels any in-flight preview first (one heavy render at a time).
- **Reason:** PRD §8.2, §10.1.

### D-009 · 2026-11-06 · Decode pixel format 32BGRA (8-bit per frame)
- **Decision:** Frames are decoded to 32BGRA. Each frame is quantized once by the decoder (8-bit sources lose nothing meaningful); accumulation is in Float64.
- **Alternatives:** 10-bit YCbCr or half-float RGBA output.
- **Reason:** Most robust decoder output across codecs and Macs for the first slice.
- **Limitation:** 10-bit (e.g. HEVC Main10/HDR) sources lose precision per frame. **Revisit in M4.**

### D-010 · 2026-11-06 · Test fixtures
- **Decision:** Small deterministic H.264 clips generated by `scripts/make_fixtures.py` (numpy + ffmpeg/libx264), committed under `Tests/FrameStackMediaTests/Fixtures`. Content is neutral black/white/gray (+ one red marker) so expected values do not depend on chroma handling. The 5 s/30 fps clip encodes each frame's index in binary so tests verify *which* frame was decoded for a timestamp.
- **Reason:** Tests must not depend on an encoder being present on the test Mac (CI VMs may lack hardware encoders).

### D-011 · 2026-11-06 · Spec documents imported from Google Drive
- `PRD.md`, `AGENTS.md` and `docs/CODEX_KICKOFF.md` were copied from the owner's Drive folder "FrameStack". `AGENTS.md` and the kickoff match the originals byte-for-byte in size; `PRD.md` differs by 3 bytes of whitespace inside the §8.1 ASCII layout diagram (Drive's text view collapses spaces). No wording was changed.

### D-012 · 2026-11-06 · Blend-mode control deferred to M2 **[PRD deviation: none — sequencing]**
- **Decision:** M1 shows the blend mode as a label (Average + explanation) rather than a one-item picker, to avoid a no-op control. M2 turns it into a picker as modes land.

### D-013 · 2026-11-06 · Damaged files: undecodable frames are missing frames, not a failed render
- **Decision:** When `AVAssetReader` fails mid-stream (status `.failed`, e.g. "Cannot Decode" on an invalid NAL unit), `CompositeRenderer` creates a new reader starting at the next *selected* frame after the last frame the decoder delivered and continues. Frames that never decode are listed in `CompositeResult.missingFrames`, the reasons in `decodeFailures`, and the UI shows "N selected frames could not be decoded: <reason> after <time>" in the bottom bar and in the export report. No frame is ever substituted for a missing one. Every restart strictly advances (so it terminates) and is capped at `maxDecoderRestarts = 256`; past the cap the summary says the renderer gave up and the file is badly damaged. If nothing at all decodes the render still throws.
- **Evidence:** The owner's `Sexy Spelling Song.m4v` (a 2010 podcast download; ffmpeg reports "Invalid NAL unit size" on most access units) imported and scanned fine (first frame decodes) but every render aborted with a bare "Cannot Decode". With this policy it yields a 73-frame composite and an honest warning; the frame count varies by one or two between runs because the hardware decoder's failure point is not deterministic on that file. A deterministic fixture, `corrupt_frame_75.mp4` (count clip with one NAL length overwritten), loses frames 73–91 on macOS 27 / M4 Pro: the two B-frames presented before the damaged P-frame reference it, and recovery needs the next keyframe plus the reorder delay. Tests assert the decoder-independent guarantee (loss confined to the damaged GOP and its neighbour; everything else decodes; frame identity preserved after the damage).
- **Alternatives:** Fail the whole render (previous behavior — useless on a long clip with one bad frame); jump to the next keyframe (faster recovery, but needs sync-sample info the scanner does not record yet — worth adding when M3 scrubbing needs keyframes anyway); software decoding fallback (AVFoundation offers no switch).
- **Limitation:** The scanner's *decode* fallback path (used only when an edit list cannot be mapped) still aborts on a damaged sample; such a file then fails at import with the reader's message.
- **Revisit when:** keyframe positions are recorded (M3), or a real file shows the one-frame-at-a-time restart being too slow.

### D-014 · 2026-11-06 · Opening files: Finder "Open With", Dock drop, `open -a`, launch argument
- **Decision:** The app bundle declares `CFBundleDocumentTypes` for `public.movie` (role Viewer, rank Alternate) and `AppDelegate` implements `application(_:open:)`; `applicationDidFinishLaunching` also accepts a path as the last non-flag command-line argument. The URL is handed to the window via a published property on the delegate. The open panel and drag & drop remain. Opening a file replaces the current source; settings (range reset to the full clip; sampling/blend/quality kept) behave as before.
- **Reason:** Standard Mac behavior the owner would expect, and it let this session verify the GUI without an open panel (see D-015). Not a sandbox/entitlement change (none exist yet, D-002).

### D-015 · 2026-11-06 · GUI verification without the owner at the keyboard
- **Decision:** Two layers. (1) `Tests/FrameStackAppTests/AppModelTests.swift` drives `AppModel` — the window's entire state — through the README checklist (import, counts, range/sampling edits, outdated/current preview, cancel, export, repeat, cancel-loading, missing/corrupt files) and runs in `swift test`. (2) The window itself was exercised on the owner's Mac by the agent with macOS accessibility scripting (`osascript` + System Events, window screenshots via `screencapture -l`), which needs no third-party tooling and no computer-use grant; keystrokes are sent only after checking FrameStack is the frontmost process, and buttons/fields are addressed by accessibility role. Results are in IMPLEMENTATION_PLAN.md's verification log.
- **Notes:** SwiftUI's formatted `TextField` does not commit a value set through the accessibility `AXValue` + `AXConfirm` path; typing with the app frontmost does. The README checklist stays as the owner's own acceptance pass.
- **Alternatives:** XCUITest (needs an Xcode project and a UI-test bundle; D-002 defers that); the desktop computer-use tools (the owner declined the grant).

### D-017 · 2026-11-06 · M2 blend-mode mathematics
- **Decision:** All modes operate on the same working-space frames as Average (linear light, Rec.709/sRGB primaries, premultiplied Float32 RGBA, oriented, optionally Lanczos-downscaled for preview) through a `FrameReducer` protocol (`add(frame)`, `result()`; output-sized state only). Per mode:
  - **Average** — `Σ/N`, Float64 (unchanged, D-004).
  - **Lighten / Darken** — per-channel running max / min, Float32, exact; alpha reduced the same way. Order-independent; opacity ignored.
  - **Additive** — `Σ frame × opacity`, Float64. Values above 1 are kept and clipped only by the export encoder (D-005). Alpha sums too (an opaque N-stack has alpha N·opacity; the exporter treats alpha ≥ 1 as opaque). Order-independent. Normalisation/exposure control is M6.
  - **Screen / Multiply / Difference / Normal** — sequential, oldest to newest. The **first selected frame initialises the composite unchanged** (at any opacity). Every later frame F updates each colour channel of the composite C as `C' = C + opacity × (B(C, F) − C)` with B = `C + F − C·F` (screen), `C·F` (multiply), `|C − F|` (difference), `F` (normal). Alpha always uses the normal rule, so opaque video stays opaque. Normal at opacity 1 is therefore exactly the last selected frame; at opacity a the k-th-from-last frame has weight a(1−a)^k (geometric), which is *not* an equal-weight average (PRD §5.1). Screen/Multiply are computed in **linear light**, not display-encoded values as Photoshop does, so they are brighter/darker than the Photoshop look; this is deliberate (same physical space as Average) and documented in the mode's info text. Float32 state; 1000 sequential multiplies of 0.999 match the Double reference within 2e-4.
  - **Opacity** is clamped to 0…1 and only re-renders modes where `usesOpacity` is true.
- **Order guarantee:** the renderer decodes in presentation order (AVAssetReader output, including after a decoder restart, D-013) and reports `deliveredInPresentationOrder`. Reversed/ping-pong order is M6.
- **Verification:** `BlendModeTests` (1×1 fixed references per mode, two-frame and large-count, opacity, random-data vs scalar Double reference for all 8 modes, bounded footprint); `BlendModeRenderTests` (black/white and moving-square fixtures per mode, "Normal 100 % = last *selected* frame", Lighten/Darken bit patterns on the count clip, preview = export for every mode); `AppModelTests` (mode/opacity changes re-render, Average ignores opacity, export file names).
- **Alternatives:** display-encoded (gamma) blending for Screen/Multiply (may be added as an explicit creative option, cf. D-004); Float64 state for sequential modes (unnecessary at these counts); SIMD/vDSP kernels for the sequential loop (not needed yet — see timings in the plan's log; optimise after measuring, PRD §10.2).
- **Revisit when:** Median / luminance modes (M6, need different data structures), reversed order, or a gamma-space creative mode is requested.

### D-016 · 2026-11-06 · iCloud placeholders are refused at import
- **Decision:** `VideoSourceLoader.load` checks `ubiquitousItemDownloadingStatus`; a `.notDownloaded` file fails immediately with "stored in iCloud and has not been downloaded to this Mac". The loading state also has a Cancel button (`AppModel.cancelLoading`).
- **Evidence:** The owner dropped a Desktop clip that was an iCloud placeholder; AVFoundation's metadata load waited on a download that never completed and the window sat on "Reading metadata…" with no way out. `brctl download` could not fetch those files in this session either.
- **Alternatives:** Trigger the download and show progress (`NSFileCoordinator`/`startDownloadingUbiquitousItem`) — deferred; a video can be many gigabytes and the user should choose.
