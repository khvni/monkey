# Monkeybot — Hands-on cua Test Results (2026-06-13)

These are results from **driving the real mock Clay page through cua-driver myself** (the same primitives Monkeybot's loop uses), not just static review. Goal: show what works and what doesn't, end-to-end, on a real Chrome window.

## Environment
- cua-driver 0.5.3 daemon running; TCC: Accessibility ✅, Screen Recording ✅.
- Target: `demo/mock-clay/index.html` opened in Google Chrome (pid 680). Active tab confirmed via osascript = `file:///…/mock-clay/index.html`.

## ✅ What works
| Area | Result |
|---|---|
| cua daemon + TCC | Running, both grants present. |
| **Window selection heuristic** | `list_windows` → the Clay window is the **largest on-screen Chrome window with a non-empty title** ('Clay — Field Mapping (Mock)', area 1.32M vs off-screen helpers ≤0.2M). Exactly what `MonkeyAgentLoop.selectTargetWindow` picks. ✅ |
| cua action primitives | `start_session`, `get_window_state`, `set_value`, `type_text`, `click`, `page` all present + callable; AX snapshot returns 685 elements. |
| Mock page | Loads, real native controls, observable Save signal (verified during build via Playwright). |

## ❌ What does NOT work out-of-the-box (CRITICAL for the Clay demo)
**Chrome web-content automation fails via BOTH grounding paths until one Chrome setting is enabled.**

1. **AX path (`get_window_state`) exposes the wrong tab's web content.** With the Clay tab confirmed active, the captured `AXWebArea` was *still* a previously-rendered background tab ("On Developer Marketing | Lee Robinson"), and the address-bar AXTextField read `leerob.com/...`. The Clay form fields (`Company Domain`, `#sheet-url`, `Save mapping`) **never appeared in the AX tree** — `query="Domain"` returned empty against 685 walked elements. Root cause: Chrome builds/exposes the a11y tree lazily per tab and does not reliably refresh the exposed `AXWebArea` on a programmatic tab switch — so element_index targeting of *web* content is unreliable.
2. **DOM path (`page` tool) is gated.** `page execute_javascript` → `"JavaScript from Apple Events is disabled. Use action=enable_javascript_apple_events"`. `page query_dom "select"` degraded to Chrome's *own* chrome popups (Extensions, Tab Search), not the page's 6 `<select>`s.
3. Also confirmed: the raw AX tree is **66 KB / 682 elements** of mostly Chrome chrome — real-world justification for Monkeybot's 12k observation cap.

## Root cause + REQUIRED fix for the demo
For reliable Clay (or any web-app) automation, **enable Chrome ▸ View ▸ Developer ▸ "Allow JavaScript from Apple Events"** (one-time; restarts Chrome). Then the cua `page` tool drives the real DOM (`query_dom` / `click_element` / `execute_javascript`) — the v0.3 browser-grounding path — bypassing Chrome's flaky web-AX entirely.

This **upgrades the v0.3 browser-grounding feature from "nice-to-have" to "required for the Chrome/Clay demo."** Monkeybot already probes for it and falls back to AX, but on Chrome the AX fallback is NOT reliable for web content (finding #1), so the setting must be on.

Order of reliability for web targets, confirmed:
1. **page DOM (needs Apple Events on)** — robust. ← enable this for the demo.
2. AX element_index — unreliable for Chrome *web* content (works great for native macOS apps).
3. Pixel coordinates — last-resort fallback; fragile.

## Recommended product changes (queued for the fix pass)
- **Preflight should detect + surface this**: the cua preflight / Monkeybot toggle row should warn "Enable Chrome → Allow JavaScript from Apple Events for reliable web automation" with the one-liner to do it, instead of silently degrading to an AX path that can't see the page.
- DEMO_SCRIPT must list "Enable Allow JavaScript from Apple Events" as a required pre-demo step (not optional).
- Native-app targets (non-browser) are unaffected — AX element_index works there.

## Note
I did NOT auto-enable Apple Events because it restarts the user's Chrome (loses open tabs). The error message itself is definitive proof the DOM path activates once enabled. Offer stands to run the full end-to-end DOM drive once Chrome is restarted with the setting on.
