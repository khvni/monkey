# Monkeybot — Hackathon Self-Assessment

Base repo: forked from github.com/farzaa/clicky (tagged v0.1.0-clicky-base).
Monkeybot additions = v0.2.0. This rubric covers only what was built today.

---

## 1. Technical Execution

### What we deliver

**End-to-end agentic loop in native Swift/macOS, zero Python glue.**
The observe-act-verify loop (MonkeyAgentLoop.swift) runs entirely on-device as an
@MainActor Swift concurrency task. Each turn: capture an AX tree + screenshot via
cua-driver (GetWindowState with capture_mode=som), pass both to Claude through the
existing Cloudflare Worker proxy, parse one strict JSON MonkeyAction, execute it via
the cua-driver CLI (click / type_text / set_value / scroll / press_key / hotkey), then
unconditionally re-snapshot before the next turn (element_index is snapshot-scoped so
staleness is not possible).

Key technical choices and why they hold up:
- **Strict JSON schema (MonkeyAction.swift)**: one action per turn, per-kind field
  validation, safe observe-fallback on double parse failure. Claude cannot produce a
  multi-step blob that races itself.
- **Cooperative cancellation**: speaking again mid-run calls monkeyAgentLoop.stop(),
  cancels + awaits the previous Swift Task, terminates the cua-driver subprocess via
  ProcessRunGuard. No leaked processes, no interleaved runs.
- **Pipe-drain on separate threads + 30s watchdog (CuaDriverClient.runProcess)**:
  avoids the classic 64 KB pipe-buffer deadlock when cua-driver produces large AX trees.
- **Trace recorder (MonkeyTraceRecorder.swift)**: every run writes
  ~/Documents/Monkeybot/runs/<ts>-<slug>/ with task.txt, transcript.txt, steps.jsonl,
  per-step observation markdown, and PNG screenshots. Reproducible post-mortems.
- **ClaudeAgentRuntime re-uses the existing claudeAPI instance**: no second auth path,
  no second Worker connection. The agent brain is just another call to /chat.

**What typechecks clean**: the entire new Swift module (MonkeyAction, AgentRuntime,
ClaudeAgentRuntime, CuaDriverClient, MonkeyAgentLoop, MonkeyTraceRecorder,
MonkeybotHUDView) typechecks via swiftc -typecheck. xcodebuild is never run from
terminal (would invalidate TCC).

### Honest limitations

- **Cloudflare Worker URL is still the base-Clicky placeholder** — one-line edit
  required before any network call succeeds. Not a code bug, but it will break a
  cold-start demo if overlooked.
- **20-step ceiling** (configurable, defaulted conservatively): mapping 6 Clay fields
  each needing open-dropdown + select is realistically 12-20+ actions. May not
  complete all six in one run.
- **No AX-settle delay after actions**: re-observe fires immediately after each driver
  call. Async UI (Clay table redraws) may not have settled, so the next snapshot could
  reflect a transitional state.
- **Observation truncated at 12,000 chars**: a wide Clay sheet with many columns may
  put the needed element_index past the cut. The model is instructed to scroll/narrow
  but this adds turns.
- **set_value silently no-ops on web inputs**: the system prompt steers Claude toward
  type_text for web fields, but nothing enforces it. A misrouted set_value burns a
  turn with no visible progress.

Score band (self-assessed): **strong** — production-quality concurrency and error
handling, genuine novelty in the approach, non-trivial integration surface. Held back
from "exceptional" by the step-ceiling risk and the one config blocker.

---

## 2. Originality

### What we deliver

Voice-commanded, vision-guided computer-use on macOS without a remote VM or a Python
orchestrator. The key combination that hasn't been done this way before:

1. **Hold-or-toggle push-to-talk inside a menu-bar app** feeds directly into an
   agentic loop — the same shortcut (Ctrl+Option) and the new hands-free toggle
   (Ctrl+Option+Space) that were already in Clicky now route to the agent when
   Monkeybot mode is on. There is no separate CLI, no chat window.
2. **Native AX tree + screenshot as joint context per turn**: cua-driver's SOM mode
   walks the live Accessibility tree into markdown and simultaneously captures a
   screenshot to a temp file; both land in the same AgentContext. Claude gets both the
   semantic structure (stable element_index) and the visual rendering.
3. **Re-observe every turn without caching**: instead of trusting that the tree is
   stable between actions, the loop re-snapshots unconditionally. This is slower but
   makes the index-staleness problem structurally impossible rather than probabilistic.
4. **Trace artifacts as a first-class feature, not debugging scaffolding**: every run
   produces a reproducible audit trail on disk with human-readable markdown per step.

### Honest limitations

- **cua-driver 0.5.3 does the heavy lifting of AX introspection** — the originality
  claim is in how it is orchestrated (native Swift, voice-first, tight re-observe loop)
  not in the AX primitives themselves.
- The forked Clicky base provides AssemblyAI transcription, ElevenLabs TTS, the
  Cloudflare Worker proxy, ScreenCaptureKit capture, and the push-to-talk pipeline.
  Those are not original to today.
- The agent brain is standard prompt-then-parse; no RL, no memory between tasks, no
  learned action policies.

Score band: **good to strong** — the voice-first native-macOS framing with per-turn
re-observe is a genuine combination not commonly seen; the components individually are
not novel.

---

## 3. Demo Impact

### What we deliver

- **Single spoken sentence kicks off a 6-field Clay mapping task** entirely hands-free.
  The audience hears the voice trigger, watches the HUD light up with step count, and
  sees Chrome + Clay respond in real time.
- **Floating HUD (MonkeybotHUDView)** gives live feedback: Listening / Running (step
  N of 20) / Idle, last action summary, trace directory path. The audience can follow
  what the agent is doing without looking at a terminal.
- **ask_user escalation path**: if the agent is genuinely blocked it surfaces a
  question to the user rather than looping silently, which is a natural demo moment.
- **Trace directory shown in HUD**: at run end the audience can see the artifacts were
  written — tangible proof the system ran.

### Honest limitations

- **Demo depends on a pre-authenticated Clay workspace in Chrome** — if the tab is not
  open and frontmost at demo time, locateFrontmostChromeWindow falls back to the
  largest Chrome window (which may not be Clay).
- **Window title must contain 'Clay'**: if the active tab shows a workspace name
  instead, the heuristic degrades to largest-window fallback.
- **Stray Space keystroke on toggle**: the Ctrl+Option+Space event tap is listen-only
  and cannot consume the event, so Chrome may also receive the Space (scroll or focus).
  Cosmetic but visible to an audience.
- **No live narration of what Claude is thinking**: the HUD shows the last action
  summary but not Claude's internal reasoning, so a slow step looks like a freeze
  rather than deliberation.
- **20-step limit visible to audience**: if the task hits the ceiling mid-way the HUD
  says "Reached the step limit" — an incomplete demo is worse than a slow one.

Score band: **good** — the voice-to-autonomous-action arc is visually compelling; demo
reliability is the primary risk, not the concept.

---

## 4. Usefulness

### What we deliver

- **Hands-free automation of repetitive point-and-click tasks** in any macOS app
  accessible via the Accessibility API — not just Clay. The architecture is
  app-agnostic; the demo target is illustrative.
- **Zero setup for the end-user beyond the Worker URL**: no Python env, no separate
  daemon UI, no config file to write. cua-driver is auto-located from standard paths;
  preflight reports status in the panel.
- **Cooperative with existing workflow**: Monkeybot mode is a toggle in the same panel
  as base Clicky. Turning it off reverts to the original pointing/TTS assistant. The
  two modes do not conflict.
- **Trace artifacts are genuinely useful beyond the demo**: steps.jsonl + per-step
  screenshots let a user or developer post-mortem any run without reproducing it.

### Honest limitations

- **Requires cua-driver 0.5.3 installed** (scripts/install_cua.sh provided, but it is
  an external dependency the user must have run, and the TCC grants must be current).
- **Agent makes real clicks and keystrokes** — there is no dry-run or preview mode.
  A misidentified element_index produces a real misclick in the live app.
- **Single re-prompt fallback then observe**: persistent Claude JSON issues (bad model
  config, token limits) degrade silently to observe loops rather than surfacing a clear
  error to the user.
- **No persistent task memory**: each run starts fresh from the spoken transcript.
  Multi-session or resumable tasks are not supported.
- **Only one app at a time**: the loop targets a single Chrome window; multi-app
  workflows (e.g., copy from a spreadsheet, paste into Clay) are not handled.

Score band: **good** — genuinely reduces repetitive UI work; limited to supervised
single-app tasks for now, and requires explicit TCC setup.

---

## 5. Polish

### What we deliver

- **HUD integrates visually with the existing Clicky design system** (DS tokens):
  colors, corner radii, and typography are consistent.
- **MenuBarPanelManager wires HUD show/hide cleanly**: appears when a run starts or
  hands-free listening begins; hides 4 seconds after returning to idle (guarded — never
  hides an active run).
- **Preflight status row in the panel**: shows daemon/permission status with a colored
  dot; auto-refreshes on Monkeybot mode enable.
- **Graceful degradation on every error path**: binaryNotFound, permissionDenied,
  stepLimitReached, and runtime failures all resolve to a final HUD state rather than a
  crash or silent hang.
- **Trace directories are human-readable**: slug derived from the transcript, ISO8601
  timestamp prefix, markdown observation files.

### Honest limitations

- **"leanring-buddy" project name typo is a known legacy artifact** — visible in the
  Xcode scheme name and file paths.
- **No onboarding for first-time Monkeybot setup**: if cua-driver is missing, the
  preflight row says "cua-driver not installed" but does not link to install
  instructions from the panel.
- **HUD hide timer uses DispatchQueue.asyncAfter without cancellation**: rapid
  Listening → Running → Idle transitions stack multiple timers (each re-checked at fire
  time, so no visible bug, but slightly wasteful).
- **ask_user question is published to HUD state but not rendered as a modal or
  actionable prompt** — the user must notice the pendingUserQuestion text in the HUD
  and respond verbally. Easy to miss in a demo.
- **No progress indicator between steps** (e.g., spinner while waiting for Claude or
  cua-driver): the HUD step counter only updates after a step completes, so the
  inter-step gap looks like inactivity.

Score band: **good** — coherent visual integration and solid error surfaces; a few
rough edges in the HUD interaction model that would matter in a shipping product but
are acceptable for a hackathon build.
