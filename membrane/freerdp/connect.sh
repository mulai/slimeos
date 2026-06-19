#!/usr/bin/env bash
# Slime OS — FreeRDP connection script
# Launched inside cage as the sole Wayland client.
# Reads /etc/slimeos/config and /etc/slimeos/hw-freerdp-flags,
# then connects to the cloud VM via WireGuard-tunneled RDP.
# On disconnect, waits RECONNECT_DELAY seconds and reconnects automatically.

set -euo pipefail

CONFIG_DIR="/etc/slimeos"
LOG_FILE="/var/log/slimeos-connect.log"

exec >> "$LOG_FILE" 2>&1

log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [connect] $*"; }

# ── Load config ───────────────────────────────────────────────────────────────
# shellcheck source=/dev/null
source "$CONFIG_DIR/config"

# Load hardware-specific FreeRDP flags
SLIMEOS_FREERDP_EXTRA_FLAGS="/network:broadband /gfx /bpp:32"
if [[ -f "$CONFIG_DIR/hw-freerdp-flags" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_DIR/hw-freerdp-flags"
fi

# ── Validate config ───────────────────────────────────────────────────────────
if [[ -z "${VM_HOST:-}" ]]; then
    log "ERROR: VM_HOST not set in $CONFIG_DIR/config"
    # Show an error screen inside cage instead of a black screen
    # (We'll use a simple weston-terminal fallback in v0.1)
    exec weston-terminal --shell="echo 'Slime OS: VM_HOST not configured. Edit /etc/slimeos/config and reboot.'; bash"
fi

if [[ -z "${SLIME_USERNAME:-}" ]]; then
    log "ERROR: SLIME_USERNAME not set in $CONFIG_DIR/config"
    exec weston-terminal --shell="echo 'Slime OS: SLIME_USERNAME not configured. Edit /etc/slimeos/config and reboot.'; bash"
fi

# ── Credential helper ─────────────────────────────────────────────────────────
# Credentials are stored in the kernel keyring by the Slime account daemon.
# For now (v0.1): prompt once, store encrypted in /etc/slimeos/.rdp-cred
CRED_FILE="$CONFIG_DIR/.rdp-cred"
if [[ ! -f "$CRED_FILE" ]]; then
    log "No stored credential — prompting (weston-terminal)"
    exec weston-terminal --shell="
        echo 'Slime OS — First-time Setup';
        echo 'Enter your Slime account password:';
        read -rs SLIME_PASS;
        echo \"\$SLIME_PASS\" | openssl enc -aes-256-cbc -pbkdf2 -pass pass:\$(cat /etc/machine-id) > $CRED_FILE;
        chmod 600 $CRED_FILE;
        echo 'Password saved. Rebooting...';
        sleep 2;
        sudo reboot"
fi

RDP_PASS=$(openssl enc -d -aes-256-cbc -pbkdf2 \
    -pass pass:"$(cat /etc/machine-id)" < "$CRED_FILE" 2>/dev/null || true)

if [[ -z "$RDP_PASS" ]]; then
    log "ERROR: Failed to decrypt stored credential. Re-prompting."
    rm -f "$CRED_FILE"
    exec "$0"
fi

# ── Resolution ────────────────────────────────────────────────────────────────
if [[ -n "${RDP_WIDTH:-}" && -n "${RDP_HEIGHT:-}" ]]; then
    RES_FLAGS="/w:${RDP_WIDTH} /h:${RDP_HEIGHT}"
else
    RES_FLAGS="/f"   # fullscreen
fi

# ── Connection loop ───────────────────────────────────────────────────────────
RECONNECT_DELAY="${RECONNECT_DELAY:-5}"

while true; do
    log "Connecting to ${VM_HOST}:${VM_PORT} as ${SLIME_USERNAME}"

    # Security flags (zero-trust stack):
    #   /sec:nla      — Network Level Authentication required
    #   /tls-seclevel:2 — TLS 1.2 minimum (TLS 1.3 preferred by xRDP)
    #   /cert:tofu    — Trust on first use, then pin
    set +e
    xfreerdp \
        /v:"${VM_HOST}:${VM_PORT}" \
        /u:"${SLIME_USERNAME}" \
        /p:"${RDP_PASS}" \
        /sec:nla \
        /tls-seclevel:2 \
        /cert:tofu \
        /network:"${RDP_NETWORK:-lan}" \
        ${RES_FLAGS} \
        /dynamic-resolution \
        /audio-mode:2 \
        /log-level:WARN \
        ${SLIMEOS_FREERDP_EXTRA_FLAGS}
    EXIT_CODE=$?
    set -e

    log "FreeRDP exited with code $EXIT_CODE"

    # Exit codes:
    #   0   = clean disconnect (user logged out)
    #   1   = connection refused / network error → reconnect
    #   2   = authentication failure → clear cred and re-prompt
    if [[ $EXIT_CODE -eq 2 ]]; then
        log "Authentication failed — clearing stored credential"
        rm -f "$CRED_FILE"
        exec "$0"
    fi

    if [[ "${RECONNECT_DELAY}" -eq 0 ]]; then
        log "Reconnect disabled — exiting"
        break
    fi

    log "Reconnecting in ${RECONNECT_DELAY}s..."
    sleep "${RECONNECT_DELAY}"
done
