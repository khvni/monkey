# Mock Clay — Field Mapping page

A self-contained, static HTML page that mimics Clay's "map your Google Sheet
columns" modal. It is the **reproducible fallback for the live-Clay demo** of
Monkeybot: when the real Clay app is unavailable, signed-out, or rate-limited,
point the agent at this page instead and the demo runs identically.

## What it is

- `index.html` — the whole page. Plain HTML/CSS/JS, **no build step**, opens
  straight from `file://` in Chrome.
- The `<title>` is **"Clay — Field Mapping (Mock)"** so Monkeybot's window
  picker (which selects the Chrome window whose title contains `clay`) lands on
  this tab automatically.

## Open it in Chrome

```sh
open -a "Google Chrome" demo/mock-clay/index.html
```

Or, if you prefer serving it over HTTP (optional, not required):

```sh
scripts/serve_mock_clay.sh        # python3 -m http.server in this directory
# then open http://localhost:8000/ in Chrome
```

## What the agent can drive

Every control is a **real, AX-exposed, labeled native form element** (proper
`<label for>`, `id`, and `name`) — not a styled `<div>`. That means the same
page is addressable two ways:

- **Accessibility tree** (`get_window_state` → `element_index`, the verified
  primary path): the inputs, native `<select>`s, and buttons all appear as
  actionable elements with their labels.
- **Page / DOM tool** (`query_dom` by CSS selector): every control has a stable
  `#id` selector.

Controls:

| Element                  | Selector                | How to drive it                         |
| ------------------------ | ----------------------- | --------------------------------------- |
| Google Sheet URL input   | `#sheet-url`            | `type_text` (free-form text)            |
| Company Domain → column   | `#map-company-domain`   | `set_value` (native `<select>`)         |
| City → column             | `#map-city`             | `set_value` (native `<select>`)         |
| LinkedIn URL → column     | `#map-linkedin-url`     | `set_value` (native `<select>`)         |
| Employee Count → column   | `#map-employee-count`   | `set_value` (native `<select>`)         |
| Industry → column         | `#map-industry`         | `set_value` (native `<select>`)         |
| Email → column            | `#map-email`            | `set_value` (native `<select>`)         |
| Save                     | `#save`                 | `click`                                 |

## Observable success signal

Clicking **Save mapping** (`#save`) sets the `#status` element's text to
`Saved ✓`. That is the concrete signal the agent's verification step reads to
confirm the task completed. (Changing any field afterward clears the signal, so
a re-run reproduces it rather than reading a stale value.)
