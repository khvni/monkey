#!/usr/bin/env bash
# install_cua.sh — Install and preflight cua-driver for Monkeybot
# Idempotent: safe to run multiple times.
set -euo pipefail

# ---------------------------------------------------------------------------
# Colour helpers (no-op if terminal does not support it)
# ---------------------------------------------------------------------------
if [ -t 1 ] && command -v tput &>/dev/null && tput setaf 1 &>/dev/null; then
    RED=$(tput setaf 1)
    GRN=$(tput setaf 2)
    YLW=$(tput setaf 3)
    CYN=$(tput setaf 6)
    BLD=$(tput bold)
    RST=$(tput sgr0)
else
    RED='' GRN='' YLW='' CYN='' BLD='' RST=''
fi

log_info()  { printf '%s[info]%s  %s\n'  "${CYN}" "${RST}" "$*"; }
log_ok()    { printf '%s[ok]%s    %s\n'  "${GRN}" "${RST}" "$*"; }
log_warn()  { printf '%s[warn]%s  %s\n'  "${YLW}" "${RST}" "$*"; }
log_error() { printf '%s[error]%s %s\n'  "${RED}" "${RST}" "$*" >&2; }
separator() { printf '%s%s%s\n' "${BLD}" "─────────────────────────────────────────────────────────────" "${RST}"; }

# ---------------------------------------------------------------------------
# 1. Run the official cua-driver installer (idempotent)
# ---------------------------------------------------------------------------
separator
log_info "Step 1 — Running official cua-driver installer …"
log_info "  curl -fsSL https://raw.githubusercontent.com/trycua/cua/main/libs/cua-driver/scripts/install.sh | bash"
curl -fsSL https://raw.githubusercontent.com/trycua/cua/main/libs/cua-driver/scripts/install.sh | bash
log_ok "Installer completed."

# ---------------------------------------------------------------------------
# 2. Verify binary presence at all four canonical search paths
# ---------------------------------------------------------------------------
separator
log_info "Step 2 — Verifying binary at canonical search paths …"

# Order matches CuaDriverClient.locateBinary() in the contract
CANONICAL_PATHS=(
    "${HOME}/.local/bin/cua-driver"
    "/opt/homebrew/bin/cua-driver"
    "/usr/local/bin/cua-driver"
)

RESOLVED_BINARY=""
for candidate_path in "${CANONICAL_PATHS[@]}"; do
    if [ -x "${candidate_path}" ]; then
        log_ok "  Found (executable): ${candidate_path}"
        if [ -L "${candidate_path}" ]; then
            real_path=$(readlink -f "${candidate_path}" 2>/dev/null || readlink "${candidate_path}")
            log_info "         -> symlink to: ${real_path}"
        fi
        # Use the first found path (mirrors Swift client search order)
        if [ -z "${RESOLVED_BINARY}" ]; then
            RESOLVED_BINARY="${candidate_path}"
        fi
    else
        log_warn "  Not found / not executable: ${candidate_path}"
    fi
done

# Fall back to PATH if none of the canonical paths resolved
if [ -z "${RESOLVED_BINARY}" ]; then
    log_warn "  Not found at any canonical path — falling back to PATH lookup …"
    if PATH_BINARY=$(command -v cua-driver 2>/dev/null); then
        log_ok "  Found on PATH: ${PATH_BINARY}"
        RESOLVED_BINARY="${PATH_BINARY}"
    else
        log_error "  cua-driver binary not found on PATH or at any canonical path."
        log_error "  Please ensure the installer succeeded and that ~/.local/bin is on your PATH."
        exit 1
    fi
fi

log_ok "Using binary: ${RESOLVED_BINARY}"

# ---------------------------------------------------------------------------
# 3. Print version
# ---------------------------------------------------------------------------
separator
log_info "Step 3 — Printing cua-driver version …"
version_output=$("${RESOLVED_BINARY}" --version 2>&1 || true)
if [ -n "${version_output}" ]; then
    log_ok "  ${version_output}"
else
    log_warn "  --version produced no output (daemon may not be running yet)."
fi

# ---------------------------------------------------------------------------
# 4. Attempt `cua-driver permissions status --json`
# ---------------------------------------------------------------------------
separator
log_info "Step 4 — Checking TCC permissions status …"
log_info "  Running: ${RESOLVED_BINARY} permissions status --json"

permissions_output=$("${RESOLVED_BINARY}" permissions status --json 2>&1) && permissions_exit=0 || permissions_exit=$?

if [ "${permissions_exit}" -eq 0 ]; then
    log_ok "permissions status output:"
    printf '%s\n' "${permissions_output}"

    # Parse booleans from JSON for a quick summary (no jq dependency)
    accessibility_granted=$(printf '%s' "${permissions_output}" | grep -o '"accessibility"[[:space:]]*:[[:space:]]*[a-z]*' | grep -o '[a-z]*$' || echo "unknown")
    screen_recording_granted=$(printf '%s' "${permissions_output}" | grep -o '"screen_recording"[[:space:]]*:[[:space:]]*[a-z]*' | grep -o '[a-z]*$' || echo "unknown")

    printf '\n'
    log_info "  accessibility    : ${accessibility_granted}"
    log_info "  screen_recording : ${screen_recording_granted}"

    if [ "${accessibility_granted}" = "true" ] && [ "${screen_recording_granted}" = "true" ]; then
        log_ok "All required TCC permissions are granted. Monkeybot is ready to run."
    else
        log_warn "One or more TCC permissions are not yet granted (see commands below)."
    fi
else
    log_warn "  'permissions status --json' exited with code ${permissions_exit}."
    log_warn "  Output: ${permissions_output}"
    log_warn "  This is normal if the CuaDriver daemon is not running yet."
fi

# ---------------------------------------------------------------------------
# 5. Print exact commands to grant TCC permissions
# ---------------------------------------------------------------------------
separator
log_info "Step 5 — Commands to grant TCC permissions (Accessibility + Screen Recording):"
printf '\n'
printf '  %s# Option A — use the cua-driver built-in grant helper%s\n' "${BLD}" "${RST}"
printf '  %s\n' "${RESOLVED_BINARY} permissions grant"
printf '\n'
printf '  %s# Option B — launch the CuaDriver app in server mode (opens system prompt dialogs)%s\n' "${BLD}" "${RST}"
printf '  %s\n' 'open -n -g -a CuaDriver --args serve'
printf '\n'
log_info "After granting permissions, restart CuaDriver and re-run this script to verify."

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
separator
log_ok "install_cua.sh complete."
log_info "Binary in use : ${RESOLVED_BINARY}"
log_info "Next step     : Ensure TCC permissions are granted, then build and run the Monkeybot Xcode target."
