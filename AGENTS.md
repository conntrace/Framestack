# FrameStack — persistent coding-agent instructions

This file is intended to live at the **repository root** as `AGENTS.md` so coding agents carry forward the same requirements across sessions. Read the root `PRD.md` for complete functional requirements. The PRD wins on product behavior; this file wins on day-to-day implementation workflow unless the owner explicitly changes the rules.

## Mission
Build a **native, offline macOS photographic compositing app for a single creative user**. Beautiful simple SwiftUI UX; precise temporal frame sampling; mathematically correct compositing; reliable export and non-destructive editing. Future public release is possible, but not current scope.

## Working style

1. At the beginning of a new session, read `PRD.md`, `AGENTS.md`, `IMPLEMENTATION_PLAN.md` (if present), and `DECISIONS.md` (if present); inspect actual repository state before proposing changes.
2. Maintain `IMPLEMENTATION_PLAN.md` as a living checklist of milestones and tasks with status, dependencies, validation commands, and next actions. Create it during setup if missing.
3. Maintain `DECISIONS.md` for meaningful choices (date, decision, alternative, reason, revisit trigger). Document any PRD deviations rather than silently editing scope.
4. Work in coherent, reviewable, testable increments. Complete a vertical slice before advanced features. Each increment should compile, have appropriately scoped tests, and be demonstrable.
5. Do not pause after every small change for permission. Make reversible implementation decisions autonomously. Ask the owner only for a blocking unknown, material tradeoff, or creative choice where multiple outcomes are substantially different. Mention assumptions clearly.
6. When a milestone completes, report what runs, which tests passed, how to try it, known limitations, and what comes next. Commit when it is safe and the repository supports git, but do not overwrite or discard user changes.
7. On session end or interruption, leave repo in a recoverable state and update `IMPLEMENTATION_PLAN.md` with exact next task, current status, and blockers.

## Technical preferences

- Swift, SwiftUI, AVFoundation, Core Image, ImageIO, ColorSync, Accelerate, Metal/Vision when justified. Prefer Apple native frameworks; minimize third-party dependencies.
- First inspect host macOS, CPU/GPU, Xcode and available tools before selecting deployment target; do not invent hardware/platform constraints.
- Separate source/decode/sampling/compositing/preview/export/document responsibilities without speculative overengineering.
- Use precise timestamps and deterministic frame selection; preserve range semantics `[start,end)`.
- Average must be a **true equal-weight average**, not repeatedly drawing semi-transparent images. Use adequate numerical precision and documented color-space math.
- Process long sequences incrementally or in bounded batches/tiles. Never require all full-res decoded frames resident in RAM.
- Keep expensive processing cancellable and off main UI thread. Preview and export must share mathematical meaning.
- Preserve orientation, image geometry, color metadata, file failures, and errors. No fabricated frame counts or timing guarantees.
- No cloud services, accounts, telemetry, tracking, or public-release engineering unless explicitly requested.

## Verification obligations

- Do not mark a task done because Swift compiles. Build and run real/deterministic media processing where feasible.
- Maintain unit tests for sample selection and each blend mode, plus end-to-end output checks for import and export. Include a 5-second/30fps test case and a moving-object synthetic video.
- Check preview vs export, cancellation, project persistence/relinking, color fidelity, and memory bounds as features are added.
- Record actual test commands and results, including known failures; never claim unexecuted tests passed.
- If GUI interaction cannot be executed in the environment, report limitation and provide explicit manual verification steps to owner.

## Priority order

M0 environment/setup → M1 real video-to-average-to-PNG vertical slice → M2 blend modes → M3 polished interactive UI → M4 export/projects/performance → M5 sequences/alignment/crop → M6 temporal curves/masks/motion/color/batches → M7 distribution **only if requested**.

You may improve phase order with a documented justification. Never quietly delete planned advanced features.
