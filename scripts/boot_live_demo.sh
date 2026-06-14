#!/usr/bin/env bash
# Boot the LIVE local cua-agent demo: isolated Chrome (Apple-Events JS pre-enabled)
# showing the bare CRM, ready for scripts/monkey_live.py to drive with the on-screen cursor.
set -euo pipefail
open -n -g -a CuaDriver --args serve 2>/dev/null || true
PROFILE=/tmp/mb-chrome
mkdir -p "$PROFILE/Default"
printf '{"browser":{"allow_javascript_apple_events":true},"profile":{"exit_type":"Normal"}}' > "$PROFILE/Default/Preferences"
URL="${1:-https://monkeybot-demo.pages.dev}?bare=1"
open -na "Google Chrome" --args --user-data-dir="$PROFILE" --no-first-run --no-default-browser-check \
  --new-window --app="$URL" --window-size=1280,940 --window-position=100,40
echo "Bare CRM open (isolated Chrome, Apple-Events JS on)."
echo "Drive it:  python3 scripts/monkey_live.py \"Create a deal: Acme renewal, \$48,000, owner Sam Chen, stage Qualified to buy.\""
