#!/usr/bin/env bash
# serve_mock_clay.sh — Serve the mock Clay field-mapping page over HTTP.
#
# Optional convenience only: the page also works directly from file:// via
#   open -a "Google Chrome" demo/mock-clay/index.html
# Use this when you'd rather drive it over http://localhost:8000/.
set -euo pipefail

# Resolve the demo/mock-clay directory relative to this script, so it works
# regardless of the current working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOCK_DIR="$(cd "${SCRIPT_DIR}/../demo/mock-clay" && pwd)"

PORT="${1:-8000}"

echo "Serving mock Clay page from: ${MOCK_DIR}"
echo "Open: http://localhost:${PORT}/"
echo "Press Ctrl+C to stop."

exec python3 -m http.server "${PORT}" --directory "${MOCK_DIR}"
