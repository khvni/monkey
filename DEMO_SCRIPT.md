# Monkeybot Demo Script — Clay Field Mapping (60 seconds max)

One spoken sentence drives the whole demo. Monkeybot hears it, looks at the screen,
and maps six Clay fields to a Google Sheet on its own while the HUD narrates each step.

**The line (say it verbatim):**

> "Monkeybot, map these Clay fields to my Google Sheet: Company Domain, City, LinkedIn URL, Employee Count, Industry, and Email."

---

## Pre-demo setup (do this BEFORE the audience is watching)

Run through every item. Any unchecked item is a likely live failure.

1. **Chrome on the pre-authed Clay workspace, front and maximized.**
   - The Clay tab is the *active* tab.
   - The window title shows the word **"Clay"** (case-insensitive). This is how Monkeybot
     locks onto the right window; if the title shows only a table/workspace name, the agent
     may grab a different Chrome window. If needed, rename the tab/view so "Clay" appears.
   - Ideally it is the **only large Chrome window** open. Close other big Chrome windows.
   - The Google Sheet side of the mapping is reachable from this same Clay view (the mapping
     panel/dropdowns are visible or one scroll away).

2. **cua-driver daemon running.** Confirm:
   ```
   cua-driver status        # expect "running"
   ```
   If it is not running, start it before anything else.

3. **TCC permissions granted** (Accessibility + Screen Recording) for the app.
   - Do NOT run `xcodebuild` from the terminal at any point — it invalidates TCC and you
     will fail `get_window_state` live. Launch the already-built app instead.

4. **Worker URL is set.** Open `leanring-buddy/CompanionManager.swift` and confirm
   `workerBaseURL` (line ~73) is your **deployed Cloudflare Worker URL**, NOT the placeholder
   `https://your-worker-name.your-subdomain.workers.dev`. Both the Clay brain and Clicky
   route through this; with the placeholder, **every turn fails on step 1.**
   - Also confirm the Worker forwards a model id your account is entitled to
     (`selectedModel` defaults to `claude-sonnet-4-6`).

5. **Monkeybot mode toggle ON.** Open the companion panel and flip the Monkeybot toggle on.
   - The panel shows a preflight status row. Wait for it to read
     **"Ready: daemon running, Accessibility + Screen Recording granted"** (green dot).
   - Preflight is *advisory only* — it will not block a run — so do not skip reading it.

6. **Mic works**, room is quiet enough for AssemblyAI to get a clean transcript.

> Optional safety net: open `~/Documents/Monkeybot/runs/` in Finder so you can show a prior
> successful run's trace if the live run stalls (see Fallback).

---

## The 60-second run, beat by beat

| Time | You do | What the audience sees |
|------|--------|------------------------|
| **0:00–0:03** | Tap **Ctrl+Option+Space** to start hands-free dictation. (Tip: have a non-text element focused so the Space keystroke doesn't land in the Clay page.) | HUD flips to **"Listening"** (blue). |
| **0:03–0:10** | Speak the line verbatim, clearly. Then tap **Ctrl+Option+Space** again to stop. (Or just tap Ctrl+Option to stop+submit.) | HUD shows the transcript was captured; flips toward **"Running"**. |
| **0:10–0:14** | (Nothing — let it work.) | HUD turns **"Running"** (blue). Step counter shows **`0 / 20`**, then **`1 / 20`**. Monkeybot raises/locks the Clay Chrome window and takes its first screen observation. |
| **0:14–0:45** | (Hands off. Narrate lightly: "It's reading the screen, then acting one step at a time, re-checking after every action.") | Step counter climbs (`2 / 20`, `3 / 20`, …). For each field — Company Domain → City → LinkedIn URL → Employee Count → Industry → Email — the HUD's **last-action line** updates: open the mapping dropdown, pick the matching column, move to the next field. The screen visibly changes as dropdowns open and selections land. |
| **0:45–0:55** | (Hands off.) | After the sixth field, Monkeybot emits its **done** action. HUD flips to **"Idle"** (green) with a one-line summary of what it mapped. |
| **0:55–1:00** | Say the closer: "And every step it took is saved as a trace." Open `~/Documents/Monkeybot/runs/` and click into the newest `…-map-these-clay-fields…` folder. | Finder shows the run folder: `task.txt`, `transcript.txt`, `steps.jsonl`, `observations/`, `screenshots/NN.png`, `final_summary.md`. Open one screenshot or `final_summary.md` to prove it's a real audit trail. |

**What the HUD tells the audience the whole time:**
- **Status:** Listening → Running → Idle (blue while listening/running, green when done).
- **Step counter:** `N / 20` — live progress, so a pause reads as "thinking," not "frozen."
- **Last action:** plain-language summary of the most recent click/selection.
- **Trace path:** where the run is being recorded, on disk, as it happens.

---

## If a step stalls (fallback — keep it calm, ~10 seconds)

The agent re-observes after every action and self-corrects, so most pauses resolve on their
own. Watch for a *true* stall: the step counter not advancing, or it climbing without the
screen changing (e.g. it picked a no-op action on a web field, or hit the 20-step ceiling on a
wide sheet).

1. **Stop it cleanly.** Tap **Ctrl+Option+Space** and speak again, OR just tap **Ctrl+Option**.
   Starting a new utterance cooperatively stops the current run (it cancels the in-flight task
   and kills the cua subprocess) — no force-quit, no crash.
2. **Pivot to the trace.** Open `~/Documents/Monkeybot/runs/<newest>/` and narrate it:
   "Even a partial run is fully recorded — here's every screen it saw and every action it took,
   one JSON line per step, with screenshots." Open `steps.jsonl` and a `screenshots/NN.png`.
3. **One clean retry** (only if time allows): re-confirm the Clay tab is front and titled
   "Clay," then say the line again. Don't retry more than once on stage.

**Two-second pre-flight gut check** (the failures most likely to bite live):
- Worker URL is real, not the placeholder → otherwise it fails on step 1.
- Preflight row is green → otherwise `get_window_state` may throw.
- The Clay tab title literally contains "Clay" and it's the only big Chrome window → otherwise
  it may lock onto the wrong window.
