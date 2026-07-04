#!/usr/bin/env bash
# Slime OS — cage Wayland session entrypoint
# Launched by slimeos-session.service as the 'slime' user on tty1.
# Starts cage (kiosk Wayland compositor) with brain-select.sh as the sole application.

set -euo pipefail

INSTALL_DIR="/opt/slimeos"
CONFIG_DIR="/etc/slimeos"
LOG_FILE="/var/log/slimeos/session.log"

exec >> "$LOG_FILE" 2>&1
echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Session starting"

# ── Load hardware profile flags ───────────────────────────────────────────────
HW_FLAGS="$CONFIG_DIR/hw-freerdp-flags"
SLIMEOS_COMPOSITOR_RENDERER="pixman"   # safe default
if [[ -f "$HW_FLAGS" ]]; then
    # shellcheck source=/dev/null
    source "$HW_FLAGS"
fi

# ── XDG runtime dir ───────────────────────────────────────────────────────────
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# ── Wait for WireGuard VPN ────────────────────────────────────────────────────
MAX_WAIT=30
waited=0
while ! ip link show wg0 &>/dev/null; do
    if (( waited >= MAX_WAIT )); then
        echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] WireGuard wg0 not up after ${MAX_WAIT}s — continuing anyway"
        break
    fi
    sleep 1
    (( waited++ ))
done

if ip link show wg0 &>/dev/null; then
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] WireGuard wg0 is up"
fi

# ── Launch cage ───────────────────────────────────────────────────────────────
# cage: minimal Wayland compositor designed for kiosk use
#   -d = allow drop to shell on exit (disabled in production — remove for security)
#   -s = allow switching VTs
# brain-select.sh is the only application cage manages. It shows the Brain
# picker (Connect screen) and hands off to connect.sh once a Brain is chosen.
echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Launching cage compositor (renderer: $SLIMEOS_COMPOSITOR_RENDERER)"

exec cage --renderer "$SLIMEOS_COMPOSITOR_RENDERER" -- "$INSTALL_DIR/brain-select.sh"
