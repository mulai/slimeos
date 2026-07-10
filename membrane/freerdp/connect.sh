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
# A session that survived at least this long before dying is treated as a
# network drop (auto-reconnect); anything shorter is a connect/auth failure
# and gets an error dialog instead. Blind retries on fast failures are
# dangerous: 10 failed NLA logons lock a Windows account for 10 minutes
# (default policy), so a 5s retry loop with a bad saved password locks the
# user out of their own Brain within a minute.
MIN_SESSION_SECONDS=60

while true; do
    log "Connecting to ${BRAIN_NAME} (${VM_HOST}:${VM_PORT}) as ${SLIME_USERNAME}"
    LOG_OFFSET=$(wc -c < "$LOG_FILE")
    SECONDS=0

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
    RUNTIME=$SECONDS

    log "FreeRDP exited with code $EXIT_CODE after ${RUNTIME}s"

    if [[ $EXIT_CODE -eq 0 ]]; then
        log "Clean disconnect — returning to Brain picker"
        exec "$INSTALL_DIR/brain-select.sh"
    fi

    if (( RUNTIME >= MIN_SESSION_SECONDS )) && [[ "${RECONNECT_DELAY}" -ne 0 ]]; then
        log "Session dropped — reconnecting in ${RECONNECT_DELAY}s..."
        sleep "${RECONNECT_DELAY}"
        continue
    fi

    # Fast failure: show the user what happened and let them decide.
    # Only grep the log this attempt appended, not older attempts' errors.
    ERR_HINT=$(tail -c +$((LOG_OFFSET + 1)) "$LOG_FILE" | grep -o 'ERRCONNECT_[A-Z_]*' | tail -1 || true)
    choice=$(whiptail --title "$BRAIN_NAME" --menu \
        "Connection failed (${ERR_HINT:-exit code $EXIT_CODE})" 14 70 3 \
        "retry"    "Try again" \
        "password" "Re-enter password" \
        "back"     "Back to Brain list" 3>&1 1>&2 2>&3) \
        || exec "$INSTALL_DIR/brain-select.sh"
    case "$choice" in
        retry)    continue ;;
        password) rm -f "$CRED_FILE"; exec "$0" "$BRAIN_ID" ;;
        *)        exec "$INSTALL_DIR/brain-select.sh" ;;
    esac
done
