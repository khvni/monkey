# Monkeybot

I forked Clicky and replaced its passive pointing behavior with a semantic computer-use loop. Monkeybot listens to a task, inspects the active SaaS UI, chooses structured actions, executes them through Cua, verifies progress, and saves the run as a reusable workflow trace.

## What Monkeybot is

Monkeybot is a voice-driven computer-use agent that lives inside a macOS menu-bar app. You speak a task in plain language ("Monkeybot, map these Clay fields to my Google Sheet: Company Domain, City, LinkedIn URL, Employee Count, Industry, and Email"). It then reads the live accessibility tree and a screenshot of the frontmost Chrome/SaaS window, decides one concrete action at a time, performs that action against the real UI through the Cua driver, re-inspects the result, and repeats until the task is done or it needs to ask you something.

It does **not** passively record your mouse and keyboard. There is no macro capture. Every action is chosen by the model from the current UI state, executed, then verified — and the resulting decision-by-decision log is written to disk as a trace you can read back and reuse.

## The observe–act–verify architecture

The agent loop (`MonkeyAgentLoop.swift`) runs a bounded cycle, max 20 steps, re-observing every single turn because element indices are snapshot-scoped:

1. **Locate & activate** — find the frontmost Chrome window (preferring a title containing "clay"), then raise it via `NSRunningApplication.activate`.
2. **Observe** — call `cua-driver get_window_state` to capture the accessibility tree (markdown) plus a screenshot to a temp PNG.
3. **Decide** — build an `AgentContext` (task, voice transcript, capped observation markdown, last 3 screenshots, prior steps, step number) and ask the Claude brain (`ClaudeAgentRuntime.swift`) for exactly **one** structured action this turn.
4. **Validate** — `MonkeyAction.validate()` enforces per-kind required fields. A malformed action is logged and skipped, not fatal — the loop just re-tries next turn.
5. **Act** — dispatch the action through `CuaDriverClient` (`click`, `type_text`, `set_value`, `scroll`, `press_key`, `hotkey`). Terminal kinds (`done`, `ask_user`, `wait`, `observe`) are handled inline.
6. **Verify** — unconditionally re-observe the window, compute a `verificationDelta` (element-count / tree-changed summary), and feed that fresh state into the next turn's context.
7. **Record & terminate** — append a step record to the trace, then end on `done`, `ask_user`, user Stop, the 20-step ceiling, or an error. Every terminal path finalizes the trace.

The brain emits one action per turn under a strict JSON schema. If Claude returns unusable JSON, the runtime re-prompts exactly once with the bad output; on a second failure it falls back to a safe `{action: observe}` rather than aborting.

## Kept from base Clicky vs. built today

This is a fork of [farzaa/clicky](https://github.com/farzaa/clicky). The base is tagged `v0.1.0-clicky-base`; the Monkeybot work is `v0.2.0`. The split is deliberate — most of the app shell predates today.

| Kept from base Clicky (NOT built today) | Built today (Monkeybot, v0.2.0) |
| --- | --- |
| SwiftUI / AppKit menu-bar app shell | `MonkeyAction.swift` — strict JSON action schema + validation |
| Push-to-talk (Ctrl+Option) pointing pipeline | `AgentRuntime.swift` — runtime protocol + `AgentContext` |
| AssemblyAI streaming transcription | `ClaudeAgentRuntime.swift` — Claude brain, one JSON action per turn |
| ScreenCaptureKit screenshots | `CuaDriverClient.swift` — `Process` wrapper over the cua-driver CLI |
| Claude API via Cloudflare Worker `/chat` (SSE) | `MonkeyAgentLoop.swift` — the observe-act-verify loop |
| ElevenLabs TTS | `MonkeyTraceRecorder.swift` — per-run trace artifacts on disk |
| Transparent cursor overlay | `MonkeybotHUDView.swift` — floating live-status HUD |
| PostHog analytics | Hands-free dictation (Ctrl+Option+Space toggle) |
| DesignSystem (DS) tokens | Monkeybot mode toggle + cua preflight wiring across CompanionManager / CompanionPanelView / MenuBarPanelManager / GlobalPushToTalkShortcutMonitor |
| | `scripts/install_cua.sh` |

Monkeybot reuses the existing `ClaudeAPI` instance for its brain — no second Cloudflare connection — and short-circuits the entire Clicky pointing/TTS path the moment Monkeybot mode is enabled.

## The cua-driver integration

Actions reach the OS through [cua-driver](https://github.com/) `0.5.3`, invoked as a subprocess: `cua-driver call <tool> <compact-json>` with a single positional JSON argument. `CuaDriverClient.swift` wraps it with real-process hygiene — both stdout/stderr pipes drained on separate threads to avoid the 64 KB buffer deadlock, a 30s watchdog, and termination on cancel so the subprocess never outlives a stopped run.

Tools used: `list_windows`, `get_window_state`, `click`, `type_text`, `set_value`, `scroll`, `press_key`, `hotkey`. Notes that shaped the design:

- `element_index` is **snapshot-scoped**, which is exactly why the loop re-observes every turn.
- `bring_to_front` is a macOS no-op, so window raising goes through `NSRunningApplication.activate`; the no-op error is swallowed by design.
- There is no `wait` tool — waiting is a client-side sleep.
- `set_value` is reserved for native dropdowns; web text inputs go through `type_text` (AXValue writes are ignored by WebKit).

A preflight check (`CuaDriverClient.preflight()`) reports binary presence (4 candidate paths), daemon status, and TCC Accessibility + Screen Recording grants, surfaced in the panel when Monkeybot mode is on. It is advisory and does not gate the run.

## The reusable trace artifact

Every run is recorded by `MonkeyTraceRecorder.swift` under `~/Documents/Monkeybot/runs/<ISO8601-timestamp>-<slug>/` (overridable via `MONKEYBOT_RUNS_DIR`):

- `task.txt` and `transcript.txt` — written immediately at run start
- `steps.jsonl` — one JSON line per turn (the action taken, the post-action observation, the verification delta)
- `observations/NN.md` — the accessibility tree captured each step
- `screenshots/NN.png` — the screenshot captured each step
- `final_summary.md` — the terminal outcome

The result is a durable, human-readable record of *how* a task was accomplished on a real SaaS UI — a workflow you can review, audit, and replay rather than a fragile click macro. All trace writes are best-effort and never throw into the loop, and the trace directory is published live into the HUD while the run is in progress.
