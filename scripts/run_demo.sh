#!/usr/bin/env bash
# Monkeybot teachable computer-use demo — drives the Ops Console web app via cua-driver.
#
# Thesis: a great agent employee is COACHABLE. Round 1 the agent does the task
# "mostly right but a few things off"; you teach it the correct workflow; then it
# repeats the rote task perfectly + fast, N times.
#
# Prereqs (see DEMO_SCRIPT.md):
#   1. cua-driver daemon running:  open -n -g -a CuaDriver --args serve
#   2. Chrome: View > Developer > "Allow JavaScript from Apple Events" ENABLED
#   3. Ops Console open as a dedicated window (this script opens it if missing).
#
# Usage:  scripts/run_demo.sh            # full teach->repeat demo (~50s)
#         scripts/run_demo.sh --naive    # just the imperfect first attempt
#         scripts/run_demo.sh --coached  # just the perfected repeats
set -euo pipefail

CUA="${CUA_DRIVER:-$HOME/.local/bin/cua-driver}"
APP_URL="file://$(cd "$(dirname "$0")/.." && pwd)/demo/ops-console/index.html"
MODE="${1:-full}"

say(){ printf "\n\033[1;36m▶ %s\033[0m\n" "$1"; }
pause(){ sleep "${1:-0.7}"; }

# --- locate (or open) the Ops Console window ---
find_win(){ "$CUA" call list_windows 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin)
ws=[w for w in d["windows"] if "Ops Console" in (w.get("title") or "")]
ws.sort(key=lambda w:-w["z_index"])
print(str(ws[0]["pid"])+" "+str(ws[0]["window_id"])) if ws else print("")'; }

WIN="$(find_win || true)"
if [ -z "${WIN:-}" ]; then
  say "Opening Ops Console…"
  open -na "Google Chrome" --args --new-window --app="$APP_URL" --window-size=1200,900 --window-position=120,60
  sleep 2.5; WIN="$(find_win)"
fi
PID="${WIN% *}"; WID="${WIN#* }"
[ -n "$PID" ] && [ -n "$WID" ] || { echo "Could not find Ops Console window"; exit 1; }
echo "Driving Ops Console  pid=$PID window=$WID"

# --- cua page helpers (DOM path — reliable once Apple Events is on) ---
SID="monkeybot-demo"
click(){ # click an element by CSS selector (animates the agent cursor)
  "$CUA" call page "{\"action\":\"click_element\",\"pid\":$PID,\"window_id\":$WID,\"selector\":\"$1\",\"session\":\"$SID\"}" >/dev/null; }
js(){ # run JS in the page
  "$CUA" call page "{\"action\":\"execute_javascript\",\"pid\":$PID,\"window_id\":$WID,\"javascript\":$1}" >/dev/null; }
setval(){ # focus + set an input/select value + fire events (selector, value)
  js "\"const e=document.querySelector('$1'); e.focus(); e.value=$2; e.dispatchEvent(new Event('input',{bubbles:true})); e.dispatchEvent(new Event('change',{bubbles:true}));\""; }
slash(){ # demo the slash-command: open menu, arrow to the chosen severity, Enter (selector, index 0..2)
  js "\"const f=document.querySelector('#f-sev'); f.focus(); f.value='/'; f.dispatchEvent(new Event('input',{bubbles:true})); f.dispatchEvent(new KeyboardEvent('keydown',{key:'/',bubbles:true}));\""
  pause 0.5
  local i=0; while [ "$i" -lt "$1" ]; do js "\"document.querySelector('#f-sev').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true}));\""; pause 0.25; i=$((i+1)); done
  js "\"document.querySelector('#f-sev').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));\""; pause 0.4; }
scroll_down(){ js "\"document.querySelector('#main').scrollTo({top:600,behavior:'smooth'});\""; pause 0.6; }
scroll_top(){ js "\"document.querySelector('#main').scrollTo({top:0,behavior:'smooth'});\""; pause 0.4; }
submit(){ click "#f-submit"; pause 1.0; }
goto(){ click "[data-view=\"$1\"]"; pause 0.6; }

# --- a single CORRECT record (the taught workflow) ---
do_record(){ # title, sevIndex(0=SEV1,1=SEV2,2=SEV3), team, service, notes, page(0/1)
  scroll_top
  click "#f-title"; setval "#f-title" "'$1'"; pause 0.3
  click "#f-sev";   slash "$2"                                  # the slash-command, done right
  setval "#f-team" "'$3'"
  scroll_down                                                    # fields below the fold
  click "#f-service"; setval "#f-service" "'$4'"
  click "#f-notes";   setval "#f-notes" "'$5'"
  [ "$6" = "1" ] && click "#f-page" || true
  submit; }

naive(){
  say "Attempt 1 — agent tries on its own (no coaching). Watch it fumble the slash-command + skip a field."
  scroll_top
  click "#f-title"; setval "#f-title" "'Checkout latency spike'"; pause 0.3
  # WRONG: types plain text instead of using the / slash-command token
  click "#f-sev"; setval "#f-sev" "'high priority'"; pause 0.4
  # WRONG: forgets the owning team, never scrolls to the below-fold fields
  submit
  say "Off: severity isn't a real token, no team, missed the below-fold service/description. This is where you COACH it."; }

coached(){
  say "Coached — now it repeats the workflow exactly, every time."
  do_record "Checkout latency spike"      0 "Payments"       "checkout-api"   "5xx spike on /charge after deploy"  1
  do_record "Search results timing out"   1 "Platform"       "search-svc"     "p99 > 3s, thread pool saturated"    0
  do_record "Image CDN cache misses"      2 "Infrastructure" "img-cdn"        "edge cache hit rate dropped to 40%" 0
  goto "queue"
  say "Three incidents logged, identically structured — the rote work, done."; }

case "$MODE" in
  --naive)   naive ;;
  --coached) coached ;;
  *)         naive; say "…you demonstrate the correct workflow once (teach)…"; sleep 1.5; coached ;;
esac
say "Demo complete."
