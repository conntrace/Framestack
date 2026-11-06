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

### D-003 · 2026-11-06 · Deployment target macOS 14
- **Decision:** `platforms: [.macOS(.v14)]`, Swift tools 5.9 (Swift 5 language mode).
- **Alternatives:** macOS 13 (loses nothing essential yet, but 14 gives `NSApp.activate()`, newer SwiftUI); macOS 15 (unnecessarily excludes Sonoma).
- **Reason:** The owner's Mac/Xcode version is **unknown** (PRD §0 says not to invent it). CI uses macOS 15 / Xcode 16. macOS 14 is a conservative modern floor that needs Xcode 15+.
- **Revisit when:** The owner reports their macOS and Xcode versions.

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
