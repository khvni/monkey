# Submission Checklist — Monkeybot v0.2.0

> For the product owner's review before the 4:30 pm deadline.
> Items marked **[OWNER ACTION]** require a manual step by the product owner.
> All other items are verified complete in the codebase.

---

## 1. Definition of Done — Status by Item

### Core agent loop

| Item | Status | Notes |
|------|--------|-------|
| MonkeyAction.swift — strict JSON action schema with per-kind validation | DONE | 199 lines; validate() enforces required fields per action kind; malformed actions are non-fatal (logged, loop retries). |
| AgentRuntime.swift — protocol + AgentContext | DONE | 60 lines. |
| ClaudeAgentRuntime.swift — one JSON action per turn | DONE | 312 lines; re-prompts once on bad JSON, falls back to {action:observe} on a second failure; reuses the existing ClaudeAPI instance (no second Cloudflare connection). |
| CuaDriverClient.swift — Process wrapper over cua-driver 0.5.3 | DONE | 605 lines; tools: list_windows, get_window_state, click, type_text, set_value, scroll, press_key, hotkey; 30s watchdog; both pipes drained on background threads; subprocess killed on Swift Task cancellation. |
| MonkeyAgentLoop.swift — observe-act-verify, re-observe every turn, max 20 steps | DONE | 667 lines; re-observes after every driver action (element indices are snapshot-scoped); cooperative stop on new utterance; all terminal paths (done / ask_user / stop / step-limit / failure) finalize the trace before setting isRunning=false. |
| MonkeyTraceRecorder.swift — per-run traces on disk | DONE | 288 lines; writes to ~/Documents/Monkeybot/runs/<ISO8601-timestamp>-<slug>/; artifacts: task.txt, transcript.txt, steps.jsonl, observations/NN.md, screenshots/NN.png, final_summary.md; overrideable via MONKEYBOT_RUNS_DIR env var; all writes best-effort, never throw into the loop. |
| MonkeybotHUDView.swift — floating HUD | DONE | 244 lines; shows Listening / Running / Idle, current step number, last action summary, trace directory path, pending user question, failure message. |

### Voice and routing

| Item | Status | Notes |
|------|--------|-------|
| Hands-free dictation — Ctrl+Option+Space toggle | DONE | GlobalPushToTalkShortcutMonitor fires handsFreeTogglePublisher only on keyDown + keyCode 49 (Space) + exactly Control+Option (no Shift/Command); double-start and double-stop are both guarded. |
| Transcript routing into agent loop | DONE | sendTranscriptToClaudeWithScreenshot routes to Monkeybot as its first statement when monkeybotModeEnabled; the entire Clicky TTS/pointing path is bypassed. |
| Monkeybot mode toggle + preflight wiring | DONE | Toggle persists to UserDefaults; preflight auto-runs on first enable; preflight row visible in CompanionPanelView only when Monkeybot mode is on. |
| cua-driver not racing the Clicky pointing pipeline | DONE | routeTranscriptToMonkeyAgentLoop cooperatively stops any prior agent run (monkeyAgentLoop.stop() + awaits previous task) before starting a new run. |

### Dependency and install

| Item | Status | Notes |
|------|--------|-------|
| scripts/install_cua.sh | DONE | Installs cua-driver CLI dependency. |
| cua-driver 0.5.3 binary detection (4 paths) | DONE | Checks ~/.local/bin, /opt/homebrew/bin, /usr/local/bin, then PATH via `which`. |

### Docs

| Item | Status | Notes |
|------|--------|-------|
| README separates base Clicky (NOT built today) from Monkeybot (built today) | DONE | README.md lines 168-205; base tagged v0.1.0-clicky-base; Monkeybot v0.2.0; explicit lists of kept vs new. |
| CLAUDE.md / AGENTS.md kept accurate | DONE | Symlinked; Key Files table includes all Monkeybot files. |

---

## 2. Pre-Submission Checklist (automated checks)

| Check | Status |
|-------|--------|
| No secrets committed — no .env / .dev.vars / hardcoded API keys in git tree | PASS — workerBaseURL is the placeholder string, not a real key; no .env or .dev.vars files found in the repo. |
| No xcodebuild in demo-prep scripts | PASS — `scripts/install_cua.sh` does not call xcodebuild. NOTE: `scripts/release.sh` (pre-existing base-Clicky notarized-release flow) intentionally calls `xcodebuild archive`/`-exportArchive` — it is a release-only script and must NOT be run during demo prep (it would invalidate TCC). |
| Git tag v0.1.0-clicky-base present (base Clicky boundary) | PASS |
| Latest commit is the v0.2.0 Monkeybot integration commit | PASS — HEAD is 69fed9c "feat: add Monkeybot voice-to-computer-use agent loop (v0.2.0)" |
| Docs clearly distinguish base Clicky from today's work | PASS — README lines 172-204 are explicit. |
| Demo recorded | **[OWNER ACTION]** — record a screen capture of the Clay field-mapping demo before submission. |

---

## 3. Owner Manual Actions Required Before Demo

These items cannot be completed by the agent and must be done by the product owner.

| # | Action | Where | Why It Is Required |
|---|--------|--------|--------------------|
| 1 | **Set the deployed Cloudflare Worker URL** | `leanring-buddy/CompanionManager.swift` line 73 — replace `"https://your-worker-name.your-subdomain.workers.dev"` with your deployed Worker URL | BLOCKER. Every decideNextAction call (the agent's Claude brain) routes through this URL. Without it the loop fails on step 1. Same one-line edit required for base Clicky. |
| 2 | **Deploy the Cloudflare Worker with API keys** | `cd worker && npx wrangler secret put ANTHROPIC_API_KEY` (+ ASSEMBLYAI_API_KEY, ELEVENLABS_API_KEY), then `npx wrangler deploy` | BLOCKER if not already done. The Worker is the proxy that holds all API keys. |
| 3 | **Verify the Anthropic model ID is served** | No code change needed — confirm your Anthropic account is entitled to `claude-sonnet-4-6` (the default at CompanionManager.swift line 166) | If the account only serves a different model ID the agent loop will fail on step 1 with an HTTP error from the Worker. |
| 4 | **Open Xcode and build/run** | `open leanring-buddy.xcodeproj`, select scheme `leanring-buddy`, set signing team, Cmd+R | NEVER use `xcodebuild` from terminal — it invalidates TCC permissions (Accessibility + Screen Recording) which cua-driver requires. |
| 5 | **Grant TCC permissions (Accessibility + Screen Recording)** | System Settings > Privacy & Security | BLOCKER for cua-driver. The first get_window_state call will throw permissionDenied if these are not granted to the running app. Confirm the preflight row in the Monkeybot panel shows "Accessibility: granted, Screen Recording: granted" before the demo. |
| 6 | **Run scripts/install_cua.sh to install cua-driver 0.5.3** | `bash scripts/install_cua.sh` | BLOCKER. Without the cua-driver binary, monkeyAgentLoop is never constructed and Monkeybot mode silently refuses every task. |
| 7 | **Pre-authenticate the Clay workspace in Chrome** | Open Chrome, navigate to the Clay workspace, and log in before the demo | The agent does NOT handle login flows. locateFrontmostChromeWindow prioritizes Chrome windows whose title contains "clay" — ensure the Clay tab is the active tab and its title includes the word "Clay". |
| 8 | **Confirm Chrome is the only large on-screen window** | Close or minimize unrelated large Chrome windows | locateFrontmostChromeWindow falls back to "largest on-screen titled Chrome window" if none have "clay" in the title. A different large Chrome window could be targeted instead. |
| 9 | **Consider the 20-step ceiling for the Clay demo task** | No code change required; optionally narrow the spoken task | Mapping 6 fields (Company Domain, City, LinkedIn URL, Employee Count, Industry, Email) each typically needs ~2 driver actions plus observes/scrolls. 20 steps is close to the ceiling for all six fields. Consider splitting the task into two utterances ("map the first three fields" then "map the remaining three") if the demo hits the limit. |
| 10 | **Record the demo video before submission** | Screen capture the full Clay field-mapping demo | Required for submission. |

---

## 4. Known Risks for Demo Day (not regressions, for owner awareness)

| Risk | Severity | Mitigation |
|------|----------|------------|
| Worker URL placeholder not yet replaced (see action 1 above) | BLOCKER | One-line edit in CompanionManager.swift line 73. |
| Clay tab title may not contain "clay" | Medium | Ensure the Clay workspace tab is the active tab and its title shows "Clay". |
| set_value silently no-ops on web input fields | Low | System prompt tells Claude to use type_text for web inputs; watch for "UI unchanged" verificationDelta in the HUD. |
| Ctrl+Option+Space toggle delivers a stray Space to Chrome | Low | Toggle while a non-text element is focused, or accept the stray space. |
| Observation truncated at 12,000 chars on wide Clay tables | Low | If a target field index falls past the cut, the agent will be told to scroll/narrow; watch for extra scroll steps. |
| 20-step ceiling on 6-field mapping task | Low-Medium | See action 9 above. |

---

*Checklist generated 2026-06-13. Codebase state: HEAD 69fed9c, branch main, clean working tree.*
