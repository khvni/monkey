Update: April 27, 2026.

Hi there! I'm Farza, the guy that made Clicky.

The existing codebase remains open source. Tinker with it, make it yours, start a company out of it, do whatever you want I don't mind. But, for all the new stuff I'm hacking on, gonna keep it private. To get the latest Clicky, you can go [here](https://www.heyclicky.com/).

I also tweeted about this [here](https://x.com/FarzaTV/status/2043402737828962489).

Go crazy with this repo!! It's an MIT license.

# Hi, this is Clicky.
It's an AI teacher that lives as a buddy next to your cursor. It can see your screen, talk to you, and even point at stuff. Kinda like having a real teacher next to you.

Download it [here](https://www.clicky.so/) for free.

Here's the [original tweet](https://x.com/FarzaTV/status/2041314633978659092) that kinda blew up for a demo for more context.

![Clicky — an ai buddy that lives on your mac](clicky-demo.gif)

This is the open-source version of Clicky for those that want to hack on it, build their own features, or just see how it works under the hood.

> This fork adds **Monkeybot**, a voice-driven on-screen agent layered on top of Clicky. For exactly what was kept from base Clicky versus what was added, see [Base Clicky vs Monkeybot changes built today](#base-clicky-vs-monkeybot-changes-built-today) at the bottom.

## Get started with Claude Code

The fastest way to get this running is with [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Once you get Claude running, paste this:

```
Hi Claude.

Clone https://github.com/farzaa/clicky.git into my current directory.

Then read the CLAUDE.md. I want to get Clicky running locally on my Mac.

Help me set up everything — the Cloudflare Worker with my own API keys, the proxy URLs, and getting it building in Xcode. Walk me through it.
```

That's it. It'll clone the repo, read the docs, and walk you through the whole setup. Once you're running you can just keep talking to it — build features, fix bugs, whatever. Go crazy.

## Manual setup

If you want to do it yourself, here's the deal.

### Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- Node.js 18+ (for the Cloudflare Worker)
- A [Cloudflare](https://cloudflare.com) account (free tier works)
- API keys for: [Anthropic](https://console.anthropic.com), [AssemblyAI](https://www.assemblyai.com), [ElevenLabs](https://elevenlabs.io)

### 1. Set up the Cloudflare Worker

The Worker is a tiny proxy that holds your API keys. The app talks to the Worker, the Worker talks to the APIs. This way your keys never ship in the app binary.

```bash
cd worker
npm install
```

Now add your secrets. Wrangler will prompt you to paste each one:

```bash
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY
```

For the ElevenLabs voice ID, open `wrangler.toml` and set it there (it's not sensitive):

```toml
[vars]
ELEVENLABS_VOICE_ID = "your-voice-id-here"
```

Deploy it:

```bash
npx wrangler deploy
```

It'll give you a URL like `https://your-worker-name.your-subdomain.workers.dev`. Copy that.

### 2. Run the Worker locally (for development)

If you want to test changes to the Worker without deploying:

```bash
cd worker
npx wrangler dev
```

This starts a local server (usually `http://localhost:8787`) that behaves exactly like the deployed Worker. You'll need to create a `.dev.vars` file in the `worker/` directory with your keys:

```
ANTHROPIC_API_KEY=sk-ant-...
ASSEMBLYAI_API_KEY=...
ELEVENLABS_API_KEY=...
ELEVENLABS_VOICE_ID=...
```

Then update the proxy URLs in the Swift code to point to `http://localhost:8787` instead of the deployed Worker URL while developing. Grep for `clicky-proxy` to find them all.

### 3. Update the proxy URLs in the app

The app has the Worker URL hardcoded in a few places. Search for `your-worker-name.your-subdomain.workers.dev` and replace it with your Worker URL:

```bash
grep -r "clicky-proxy" leanring-buddy/
```

You'll find it in:
- `CompanionManager.swift` — Claude chat + ElevenLabs TTS
- `AssemblyAIStreamingTranscriptionProvider.swift` — AssemblyAI token endpoint

### 4. Open in Xcode and run

```bash
open leanring-buddy.xcodeproj
```

In Xcode:
1. Select the `leanring-buddy` scheme (yes, the typo is intentional, long story)
2. Set your signing team under Signing & Capabilities
3. Hit **Cmd + R** to build and run

The app will appear in your menu bar (not the dock). Click the icon to open the panel, grant the permissions it asks for, and you're good.

### Permissions the app needs

- **Microphone** — for push-to-talk voice capture
- **Accessibility** — for the global keyboard shortcut (Control + Option)
- **Screen Recording** — for taking screenshots when you use the hotkey
- **Screen Content** — for ScreenCaptureKit access

## Architecture

If you want the full technical breakdown, read `CLAUDE.md`. But here's the short version:

**Menu bar app** (no dock icon) with two `NSPanel` windows — one for the control panel dropdown, one for the full-screen transparent cursor overlay. Push-to-talk streams audio over a websocket to AssemblyAI, sends the transcript + screenshot to Claude via streaming SSE, and plays the response through ElevenLabs TTS. Claude can embed `[POINT:x,y:label:screenN]` tags in its responses to make the cursor fly to specific UI elements across multiple monitors. All three APIs are proxied through a Cloudflare Worker.

## Project structure

```
leanring-buddy/          # Swift source (yes, the typo stays)
  CompanionManager.swift    # Central state machine
  CompanionPanelView.swift  # Menu bar panel UI
  ClaudeAPI.swift           # Claude streaming client
  ElevenLabsTTSClient.swift # Text-to-speech playback
  OverlayWindow.swift       # Blue cursor overlay
  AssemblyAI*.swift         # Real-time transcription
  BuddyDictation*.swift     # Push-to-talk pipeline
worker/                  # Cloudflare Worker proxy
  src/index.ts              # Three routes: /chat, /tts, /transcribe-token
CLAUDE.md                # Full architecture doc (agents read this)
```

## Contributing

PRs welcome. If you're using Claude Code, it already knows the codebase — just tell it what you want to build and point it at `CLAUDE.md`.

Got feedback? DM me on X [@farzatv](https://x.com/farzatv).

---

# Base Clicky vs Monkeybot changes built today

This repo is a fork of [farzaa/clicky](https://github.com/farzaa/clicky). The base Clicky app (tagged `v0.1.0-clicky-base`) was built by Farza and is the foundation everything below sits on. The **Monkeybot** work (`v0.2.0`) adds a voice-driven on-screen agent on top of that foundation. **Most of Clicky was NOT built today** — the list below is precise about which is which.

## Kept from base Clicky (NOT built today)

These already existed in base Clicky and were reused as-is:

- **SwiftUI / AppKit menu-bar app shell** — the menu-bar (no-dock) app and its `NSPanel` windows.
- **Push-to-talk pointing pipeline** — hold **Ctrl + Option** to talk; Claude can point the cursor at on-screen elements.
- **AssemblyAI streaming transcription** — real-time speech-to-text over a websocket.
- **ScreenCaptureKit screenshots** — screen capture for context.
- **Claude API via Cloudflare Worker `/chat`** — streaming SSE proxy that holds the API keys.
- **ElevenLabs TTS** — spoken responses.
- **Transparent cursor overlay** — the blue cursor that flies to UI elements.
- **PostHog analytics**.
- **DesignSystem (DS) tokens** — shared design tokens.

## Built today (Monkeybot — `v0.2.0`)

New files:

- `MonkeyAction.swift` — strict JSON action schema (with per-kind validation).
- `AgentRuntime.swift` — agent runtime protocol + shared `AgentContext`.
- `ClaudeAgentRuntime.swift` — the Claude "brain"; emits exactly one JSON action per turn. Reuses the existing Clicky `ClaudeAPI` instance (no second Cloudflare connection).
- `CuaDriverClient.swift` — `Process` wrapper over the `cua-driver` 0.5.3 CLI (tools: `list_windows`, `get_window_state`, `click`, `type_text`, `set_value`, `scroll`, `press_key`, `hotkey`).
- `MonkeyAgentLoop.swift` — observe-act-verify loop; re-observes every turn (element indices are snapshot-scoped), max 20 steps.
- `MonkeyTraceRecorder.swift` — per-run traces under `runs/<timestamp>-<slug>/` (`task.txt`, `transcript.txt`, `steps.jsonl`, `observations/`, `screenshots/`, `final_summary.md`).
- `MonkeybotHUDView.swift` — floating HUD showing live status (Listening / Running / Idle, current step, last action, trace path).

Other additions:

- **Hands-free dictation** — **Ctrl + Option + Space** toggles a continuous dictation session that auto-submits on stop; pressing **Ctrl + Option** stops and submits.
- **Monkeybot mode toggle + preflight wiring** — across `CompanionManager`, `CompanionPanelView`, `MenuBarPanelManager`, and `GlobalPushToTalkShortcutMonitor` (mode toggle, routing transcripts into the agent loop, and the advisory cua-driver / TCC preflight status row).
- `scripts/install_cua.sh` — installs the `cua-driver` CLI dependency.

> Note: `cua-driver` 0.5.3 is an external CLI dependency invoked as `cua-driver call <tool> <json>`; it is not part of this repo. The Cloudflare Worker auth and base Clicky setup are unchanged — see the setup sections above.
