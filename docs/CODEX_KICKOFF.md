# FrameStack — kickoff prompt for Codex / coding agent

Copy and paste the text below into a coding agent **after placing `PRD.md` and `AGENTS.md` in the intended repository**, or attach both files and tell the agent to place `AGENTS.md` at the repository root.

---

I want you to build **FrameStack**, a native, local-first macOS creative photography app. Its full specification is attached/in the repository as `PRD.md`. Read the entire `PRD.md` and `AGENTS.md` first. Treat them as the product requirements and persistent working instructions.

**My intent:** This is initially a personal creative tool, not a public product. Focus on a genuinely usable, photographically accurate application that turns selected video frames (and later still-image sequences) into a single composite photograph. I care about minimal Apple-like UI, unusually fine control over frame selection/time/blending, correctness, performance, and advanced artistic features. Do not add accounts, cloud services, subscriptions, or app-store packaging now.

**Your job is to own the implementation process over multiple stages, not write a one-shot prototype.**

1. Inspect the repository and actual local toolchain (macOS/Xcode/Swift/hardware). Do not assume these facts. Identify missing prerequisites, if any.
2. Read the requirements thoroughly, map dependencies, and create an actionable `IMPLEMENTATION_PLAN.md` with milestones, tasks, validation steps, and checkboxes. Create a `DECISIONS.md` log for architectural choices, risks, and deviations. Keep both updated throughout the project.
3. Propose a concise technical architecture and milestone order. Choose reasonable reversible defaults, and ask me only about decisions that materially block development or affect the creative outcome.
4. **Then start implementing M0 and M1 immediately**: a real native macOS app that imports a video, selects an exact time range and All/Nth/Exact Count frame sampling, performs **true equal-weight Average** with correct frame decoding, shows a preview, and exports full-resolution PNG. No placeholder compositing, fake previews, or no-op controls.
5. Use automated tests and deterministic media fixtures to verify sampling and blend mathematics; actually validate exported image files. Do not treat compilation alone as sufficient. Keep memory bounded and keep rendering off the UI thread.
6. Continue through the PRD's later milestones in sensible increments: blending, usable UI, export/project persistence, image sequences, alignment/crop, temporal weighting, motion/manual masking, motion accumulation, color controls, and batch variations. Preserve the ambitious features in the plan even if they take many iterations. Do not silently cut scope.
7. At the end of each meaningful milestone, tell me what works, how to run/test it, which tests you executed, limitations/blockers, and the next milestone. Commit safely when appropriate. Update the plan so another coding session can resume without repeating the discussion.

If you cannot access a macOS/Xcode environment, do **not** pretend you built or verified a working macOS app. You may scaffold source code/tests and provide exact steps for me to build on my Mac, but clearly disclose the limitation.

Aim for a tool I can actually use to make art, rather than a feature checklist or elaborate architecture without a working app. Please begin with repository/toolchain inspection and the implementation plan, then proceed with the first real functional slice.
