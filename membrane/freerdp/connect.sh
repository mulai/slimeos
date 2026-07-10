#!/usr/bin/env bash
# Slime OS — FreeRDP connection script
# Launched by brain-select.sh (already running inside the kiosk's terminal
# client) once the user has picked a saved Brain from the Connect screen.
# Reads that Brain's host/port/username from /etc/slimeos/brains.json,
# prompts for a password on first use, then connects via WireGuard-tunneled
# RDP. On disconnect, waits RECONNECT_DELAY seconds and reconnects
# automatically; on clean logout or auth failure, hands control back to the
# Brain picker.

set -euo pipefail

CONFIG_DIR="/etc/slimeos"
INSTALL_DIR="/opt/slimeos"
BRAINS_FILE="$CONFIG_DIR/brains.json"
CRED_DIR="$CONFIG_DIR/brains"
LOG_FILE="/var/log/slimeos/connect.log"

# No global 'exec >> log' here: whiptail draws its dialogs on this script's
# stdout/stderr, so redirecting them paints the UI into the log file and
# leaves the user staring at a frozen screen with an invisible prompt.
# log() appends explicitly; only xfreerdp's own output is sent to the log.
log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [connect] $*" >> "$LOG_FILE"; }

BRAIN_ID="${1:?Usage: connect.sh <brain-id>}"
mkdir -p "$CRED_DIR"
chmod 700 "$CRED_DIR"

# ── Load Brain record ─────────────────────────────────────────────────────────
BRAIN_JSON=$(jq -c --arg id "$BRAIN_ID" '.[] | select(.id == $id)' "$BRAINS_FILE")
if [[ -z "$BRAIN_JSON" ]]; then
    log "ERROR: brain id $BRAIN_ID not found — returning to picker"
    exec "$INSTALL_DIR/brain-select.sh"
fi

VM_HOST=$(jq -r '.host' <<<"$BRAIN_JSON")
VM_PORT=$(jq -r '.port' <<<"$BRAIN_JSON")
SLIME_USERNAME=$(jq -r '.username' <<<"$BRAIN_JSON")
BRAIN_NAME=$(jq -r '.name' <<<"$BRAIN_JSON")

if [[ -z "$SLIME_USERNAME" ]]; then
    SLIME_USERNAME=$(whiptail --title "$BRAIN_NAME" \
        --inputbox "Username for $BRAIN_NAME" 10 60 3>&1 1>&2 2>&3) || exec "$INSTALL_DIR/brain-select.sh"
    [[ -n "$SLIME_USERNAME" ]] || exec "$INSTALL_DIR/brain-select.sh"

    tmp=$(mktemp)
    # Write through the existing file, don't mv over it: replacing a file via
    # rename() needs write permission on /etc/slimeos itself, which is (and
    # should stay) root-owned -- we only own brains.json inside it.
    jq --arg id "$BRAIN_ID" --arg u "$SLIME_USERNAME" \
        'map(if .id == $id then .username = $u else . end)' "$BRAINS_FILE" > "$tmp" && cat "$tmp" > "$BRAINS_FILE"
    rm -f "$tmp"
fi

# Load hardware-specific FreeRDP flags
SLIMEOS_FREERDP_EXTRA_FLAGS="/network:broadband /gfx /bpp:32"
if [[ -f "$CONFIG_DIR/hw-freerdp-flags" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_DIR/hw-freerdp-flags"
fi

# Session-wide display/network preferences (not per-brain)
if [[ -f "$CONFIG_DIR/config" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_DIR/config"
fi

# ── Credential ────────────────────────────────────────────────────────────────
CRED_FILE="$CRED_DIR/${BRAIN_ID}.cred"
CRED_PASS="$(cat /etc/machine-id)-${BRAIN_ID}"

if [[ ! -f "$CRED_FILE" ]]; then
    log "No stored credential for $BRAIN_NAME — prompting"
    RDP_PASS_INPUT=$(whiptail --title "$BRAIN_NAME" \
        --passwordbox "Password for $SLIME_USERNAME@$BRAIN_NAME" 10 60 3>&1 1>&2 2>&3) || exec "$INSTALL_DIR/brain-select.sh"
    echo "$RDP_PASS_INPUT" | openssl enc -aes-256-cbc -pbkdf2 -pass pass:"$CRED_PASS" > "$CRED_FILE"
    chmod 600 "$CRED_FILE"
fi

RDP_PASS=$(openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:"$CRED_PASS" < "$CRED_FILE" 2>/dev/null || true)
if [[ -z "$RDP_PASS" ]]; then
    log "ERROR: Failed to decrypt stored credential. Re-prompting."
    rm -f "$CRED_FILE"
    exec "$0" "$BRAIN_ID"
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
    log "Connecting to ${BRAIN_NAME} (${VM_HOST}:${VM_PORT}) as ${SLIME_USERNAME}"

    # Security flags (zero-trust stack):
    #   /sec:rdp:off  — disable only legacy plain-RDP security and let the
    #                   rest negotiate: Windows Brains require NLA, xrdp
    #                   Brains only offer TLS (no CredSSP/NLA support at
    #                   all), so forcing either one breaks the other with
    #                   "Protocol Security Negotiation Failure". Transport
    #                   is WireGuard + TLS-or-better regardless.
    #   /cert:tofu    — Trust on first use, then pin
    # No /tls:seclevel: FreeRDP 3.15's /tls sub-option parser rejects even
    # its own documented values (non-fatal ERROR, option ignored) — the
    # server side enforces the TLS version floor instead.
    set +e
    xfreerdp3 \
        /v:"${VM_HOST}:${VM_PORT}" \
        /u:"${SLIME_USERNAME}" \
        /p:"${RDP_PASS}" \
        /sec:rdp:off \
        /cert:tofu \
        /network:"${RDP_NETWORK:-lan}" \
        ${RES_FLAGS} \
        /dynamic-resolution \
        /audio-mode:2 \
        /log-level:WARN \
        ${SLIMEOS_FREERDP_EXTRA_FLAGS} >> "$LOG_FILE" 2>&1
    EXIT_CODE=$?
    set -e

    log "FreeRDP exited with code $EXIT_CODE"

    # Exit codes:
    #   0   = clean disconnect (user logged out) → back to Brain picker
    #   1   = connection refused / network error → reconnect
    #   2   = authentication failure → clear cred, re-prompt
    if [[ $EXIT_CODE -eq 2 ]]; then
        log "Authentication failed — clearing stored credential"
        rm -f "$CRED_FILE"
        exec "$0" "$BRAIN_ID"
    fi

    if [[ $EXIT_CODE -eq 0 ]]; then
        log "Clean disconnect — returning to Brain picker"
        exec "$INSTALL_DIR/brain-select.sh"
    fi

    if [[ "${RECONNECT_DELAY}" -eq 0 ]]; then
        log "Reconnect disabled — returning to Brain picker"
        exec "$INSTALL_DIR/brain-select.sh"
    fi

    log "Reconnecting in ${RECONNECT_DELAY}s..."
    sleep "${RECONNECT_DELAY}"
done
