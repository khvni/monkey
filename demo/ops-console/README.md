# Monkeybot — Teachable Agent Demo (HubSpot-style CRM)

A **real, steerable Claude agent** that drives a deliberately tedious CRM form — the kind of manual data entry a great "agent employee" should just handle. Not scripted: every action is decided live by Claude.

---

## TL;DR — record the demo right now

```bash
open -na "Google Chrome" --args --new-window \
  --app="file:///Users/khani/Desktop/projs/monkey/demo/ops-console/index.html?demo=1" \
  --window-size=1280,940 --window-position=100,40
```

1. A chromeless HubSpot-style window opens and the agent **auto-runs** the default task.
2. Record with **Cmd+Shift+5** (capture that window or the full screen).
3. ~40–55s: the agent fills the deal form, uses the **/ slash-command** for Deal stage, scrolls to the below-the-fold fields, and creates the deal.

> If it opens but doesn't move, Chrome cached an old copy — add a version param: `…index.html?v=2&demo=1`.

**For a live, steerable recording (recommended for judges):** open the URL **without** `?demo=1`. A floating Monkeybot bar appears and waits. Start your screen recording, then:
- Type a task in the bar → **Run**.
- Mid-run, type a correction in the coach box → **Teach** → watch it adapt. (This is the "coachable" money shot.)

---

## The thesis (what to say)

> "A great agent employee, like a great human one, is **coachable**. You give it a task, correct it once, and it handles the rest — even boring, manual SaaS busywork. Here it's driving a CRM: filling fields, using slash-commands, scrolling, submitting — all decided live by Claude."

---

## How it works (architecture)

```
  Your task (typed in the bar)
        │
        ▼
  ┌──────────────────────────────────────────────────────────┐
  │  demo-mode.js   (real agent loop, in the browser)         │
  │                                                           │
  │   observe()  ── reads the live DOM:                       │
  │      auto-discovers every labelled field (id, label,      │
  │      value, below-the-fold?), slash fields, view, counts  │
  │        │                                                   │
  │        ▼                                                   │
  │   decide()  ── POST to the Cloudflare Worker /chat ───────┼──▶ Claude (claude-sonnet-4-6)
  │      sends the action schema + observation + your task    │      returns ONE JSON action
  │      + any coaching;  parses ONE JSON action back ◀───────┼──┘
  │        │                                                   │
  │        ▼                                                   │
  │   execute()  ── moves the triangle cursor, shows the      │
  │      dialogue bubble, performs the DOM action             │
  │        │                                                   │
  │        └────────────── re-observe, loop (max 16 steps) ───┘
  └──────────────────────────────────────────────────────────┘
        │
        ▼
  index.html  (HubSpot-style CRM "Create deal" form it operates)
```

**It's the same observe → decide → act → re-observe loop the Swift Monkeybot runs through cua-driver** — here it runs in the browser and acts on the DOM directly, which makes it 100% reliable for a live demo (no cua / Apple-Events / window-focus fragility).

### Files
| File | Role |
|------|------|
| `index.html` | The CRM the agent operates. HubSpot-style "Create deal" form: text fields, a `/` slash-command **Deal stage** field, selects, below-the-fold fields (force scroll), submit → Pipeline table + Reports. All controls have stable `id`s + `<label>`s. |
| `demo-mode.js` | The **real agent**: triangle pointer, dialogue bubble at the cursor, the bottom control bar (task + Run + coach + Teach), and the live Claude loop. **Form-generic** — it auto-discovers fields, so the form can change without touching the agent. |
| `../../worker/src/index.ts` | Cloudflare Worker proxy (`/chat` → Anthropic). Holds the API key; **CORS enabled** so the browser agent can call it. Deployed at `clicky-proxy.byalikhani.workers.dev`. |

### The agent's action vocabulary (what Claude can emit)
`set_field` · `select_field` · `slash_field` · `toggle` · `scroll` · `submit` · `navigate` · `done` — one JSON object per turn, each with a short first-person `say` (shown in the cursor bubble).

### Steerable & coachable
- **Steer:** the task box is free text. "Create a renewal deal for Globex, $120k, owner Jordan Lee, stage Presentation scheduled, priority High."
- **Coach:** the Teach box injects a rule into the agent's context for the rest of the run (e.g. "always add a follow-up task for renewals"). It genuinely changes the next decisions — not a script.

---

## Prerequisites
- **cua-driver daemon** running (only needed if you also want the native/cua path): `open -n -g -a CuaDriver --args serve`. **The browser demo above needs nothing** beyond Chrome + internet (it calls the deployed Worker).
- The Worker must be reachable (it is — `clicky-proxy.byalikhani.workers.dev`, CORS on).

## Troubleshooting
- **Agent does nothing / "worker 4xx":** check internet; the Worker `/chat` must be up. Test: `curl -s -X POST https://clicky-proxy.byalikhani.workers.dev/chat -H 'content-type: application/json' -d '{"model":"claude-sonnet-4-6","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}'`
- **Stale UI:** add `?v=N` to bust Chrome's file:// cache.
- **Window too small / fields clipped:** use the `--window-size=1280,940` flag above.

## Security note
The Worker's `/chat` is currently **open CORS (`*`)** for the demo — anyone with the URL can spend the Anthropic key. Scope `access-control-allow-origin` (or add a shared-secret header) before making the repo public.

---

## 60-second script — LIVE coaching (recommended)

Open **without** `?demo=1` so the floating bar waits. The task box is pre-filled (it deliberately omits priority + follow-up so your coaching has a visible effect).

**Rehearse once first** (warms Chrome's cache + confirms the Worker responds + you see the timing). Then reload and record.

| Time | You do | You say |
|------|--------|---------|
| 0:00 | (window up, agent idle) | "This is Monkeybot — a teachable agent. My thesis: a great agent employee, like a great person, is **coachable**. Teach it once, and it handles the rest — even boring manual SaaS work." |
| 0:10 | Type in the **coach** box → **Teach**: `For renewals, always set priority to High and add a follow-up task.` | "First I'll coach it — in plain English." (a teal "You — coaching" bubble appears) |
| 0:17 | Click **Run** (task is pre-filled) | "Now the task: create this renewal deal." |
| 0:22–0:48 | (hands off — narrate) | "It reads the form and decides each action live — Claude, not a script. Watch it handle what people hate: the **slash-command** for deal stage, the fields **below the fold** it scrolls to, the dropdowns. And notice — my task never said 'High priority' or 'follow-up task'. It's doing those because I **coached** it." |
| 0:48 | (deal lands in Pipeline) | "Nothing's scripted — hand it any deal, coach it in plain English, and it adapts. A teachable agent doing real GUI busywork." |

**Why this lands:** the agent sets Priority = High and checks "Create a follow-up task" even though your task never mentioned them — proof it learned from your live coaching, not a script.

**If a step stalls:** it's the network/Worker (it calls Claude). Just click **Run** again — it's a real agent, safe to re-run.
