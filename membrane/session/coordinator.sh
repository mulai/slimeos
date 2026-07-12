#!/usr/bin/env bash
# Slime OS — Kiosk backend coordinator
#
# Replaces brain-select.sh's whiptail menu loop. Runs as a single persistent
# process, supervised 1:1 by slimeos-bridge (membrane/bridge/), which pipes
# it newline-delimited JSON on stdin and relays its stdout lines verbatim to
# the lock screen's WebSocket connection (membrane/lockscreen/index.html).
# The bridge is a dumb relay — this script owns all the actual behavior.
#
# ── Protocol ─────────────────────────────────────────────────────────────────
# Read (stdin), one JSON object per line — mirrors the lockscreen's
# `slime:*` events 1:1, plus two bridge-synthesized lifecycle events:
#   {"type":"_clientConnected"}                          synthesized by the bridge on every new WS connection
#   {"type":"_clientDisconnected"}                        synthesized by the bridge when that connection drops
#   {"type":"addBrain","name":..,"host":..,"port":..}
#   {"type":"connect","id":..}
#   {"type":"removeBrain","id":..}
#   {"type":"credentials","username":?,"password":..}     (only consumed by do_connect, see connect.sh)
#   {"type":"retry"} | {"type":"reenterPassword"} | {"type":"back"} | {"type":"cancelConnect"}
#
# Write (stdout), one JSON object per line — mirrors window.SlimeUI 1:1:
#   {"type":"setState","state":"empty|picker|addBrain|credentials|connecting|error|reconnecting","data":{...}}
#   {"type":"setStatus","clock":"HH:MM","tunnel":"up|down|connecting"}
#
# `data` shapes are exactly what membrane/lockscreen/index.html's header
# comment documents. `addBrain` state is rendered entirely client-side (the
# form itself needs no backend round-trip); this script only ever emits
# empty/picker/credentials/connecting/error/reconnecting.
#
# On stdin EOF (the bridge died), exit cleanly rather than erroring — the
# bridge's own supervisor will spawn a fresh coordinator and resync whatever
# client reconnects.

set -euo pipefail

CONFIG_DIR="/etc/slimeos"
INSTALL_DIR="/opt/slimeos"
BRAINS_FILE="$CONFIG_DIR/brains.json"
CRED_DIR="$CONFIG_DIR/brains"
FREERDP_LOG_FILE="/var/log/slimeos/connect.log"

# stderr lands in slimeos-bridge's --log file (coordinator.log) — the bridge
# doesn't know or care about our log format, it just redirects our stderr
# wholesale, so there's no separate log path to configure here.
log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [coordinator] $*" >&2; }

emit_state()  { jq -nc --arg state "$1" --argjson data "$2" '{type:"setState", state:$state, data:$data}'; }
emit_status() { jq -nc --arg clock "$1" --arg tunnel "$2" '{type:"setStatus", clock:$clock, tunnel:$tunnel}'; }

# Sends the current real clock + tunnel state. The page auto-advances the
# clock locally every 30s after that (see index.html), so one correct value
# per client connection/resync is enough — without this, the status strip
# never leaves the hardcoded 00:00 default the page paints before its first
# backend message ever arrives.
send_status() {
    local clock tunnel
    clock=$(date +"%H:%M")
    if ip link show wg0 &>/dev/null; then
        tunnel="up"
    else
        tunnel="down"
    fi
    emit_status "$clock" "$tunnel"
}

read_event() {
    local line
    IFS= read -r line <&0 || return 1
    printf '%s' "$line"
}

mkdir -p "$CRED_DIR"
chmod 700 "$CRED_DIR"
[[ -f "$BRAINS_FILE" ]] || echo '[]' > "$BRAINS_FILE"

# ── Session-wide FreeRDP/display config, loaded once here (not per-connect-
# attempt as the old connect.sh did) and read by do_connect() via these vars.
SLIMEOS_FREERDP_EXTRA_FLAGS="/network:broadband /gfx /bpp:32"
if [[ -f "$CONFIG_DIR/hw-freerdp-flags" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_DIR/hw-freerdp-flags"
fi
if [[ -f "$CONFIG_DIR/config" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_DIR/config"
fi

RES_FLAGS="/f" # fullscreen
if [[ -n "${RDP_WIDTH:-}" && -n "${RDP_HEIGHT:-}" ]]; then
    RES_FLAGS="/w:${RDP_WIDTH} /h:${RDP_HEIGHT}"
fi

MIN_SESSION_SECONDS=60

# shellcheck source=../freerdp/connect.sh
source "$INSTALL_DIR/connect.sh" # defines do_connect()

add_brain() {
    local name="$1" host="$2" port="$3"
    local id tmp
    id=$(cat /proc/sys/kernel/random/uuid)
    tmp=$(mktemp)
    # Write-through, not `mv`: /etc/slimeos is root-owned; we only own
    # brains.json itself, not rename() rights inside its parent directory.
    jq --arg id "$id" --arg name "$name" --arg host "$host" --arg port "$port" \
        '. += [{id:$id, name:$name, host:$host, port:$port, username:"", lastConnected:null}]' \
        "$BRAINS_FILE" > "$tmp" && cat "$tmp" > "$BRAINS_FILE"
    rm -f "$tmp"
    log "Added brain '$name' ($host:$port) id=$id"
}

remove_brain() {
    local id="$1" tmp
    tmp=$(mktemp)
    jq --arg id "$id" 'map(select(.id != $id))' "$BRAINS_FILE" > "$tmp" && cat "$tmp" > "$BRAINS_FILE"
    rm -f "$tmp" "$CRED_DIR/${id}.cred"
    log "Removed brain id=$id"
}

stamp_last_connected() {
    local id="$1" tmp now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    tmp=$(mktemp)
    jq --arg id "$id" --arg now "$now" \
        'map(if .id == $id then .lastConnected = $now else . end)' \
        "$BRAINS_FILE" > "$tmp" && cat "$tmp" > "$BRAINS_FILE"
    rm -f "$tmp"
}

# Renders a stored ISO8601 timestamp (or null/missing) as the short relative
# string the picker card displays ("2 hours ago" / "never").
relative_time() {
    local iso="$1"
    if [[ -z "$iso" || "$iso" == "null" ]]; then
        echo "never"
        return
    fi
    local epoch now diff
    epoch=$(date -u -d "$iso" +%s 2>/dev/null) || { echo "never"; return; }
    now=$(date -u +%s)
    diff=$((now - epoch))
    if (( diff < 60 )); then
        echo "just now"
    elif (( diff < 3600 )); then
        echo "$(( diff / 60 )) minutes ago"
    elif (( diff < 86400 )); then
        echo "$(( diff / 3600 )) hours ago"
    else
        echo "$(( diff / 86400 )) days ago"
    fi
}

show_picker_or_empty() {
    local count
    count=$(jq 'length' "$BRAINS_FILE")
    if [[ "$count" -eq 0 ]]; then
        emit_state empty '{}'
        return
    fi

    local entries=()
    while IFS=$'\t' read -r id name host last; do
        local rel
        rel=$(relative_time "$last")
        entries+=("$(jq -nc --arg id "$id" --arg name "$name" --arg host "$host" --arg rel "$rel" \
            '{id:$id, name:$name, host:$host, lastConnected:$rel}')")
    done < <(jq -r '.[] | [.id, .name, .host, (.lastConnected // "")] | @tsv' "$BRAINS_FILE")

    local brains_json
    brains_json=$(printf '%s\n' "${entries[@]}" | jq -sc '.')
    emit_state picker "$(jq -nc --argjson b "$brains_json" '{brains:$b}')"
}

log "Coordinator starting, waiting for first client..."

while true; do
    line=$(read_event) || { log "stdin closed — exiting"; exit 0; }
    ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)

    case "$ev_type" in
        _clientConnected)
            log "Client connected — resyncing"
            send_status
            show_picker_or_empty
            ;;
        _clientDisconnected)
            : # nothing to do; an active connect session (if any) keeps running
            ;;
        addBrain)
            name=$(jq -r '.name // empty' <<<"$line")
            host=$(jq -r '.host // empty' <<<"$line")
            port=$(jq -r '.port // "3389"' <<<"$line")
            [[ -n "$host" ]] && add_brain "${name:-Untitled Brain}" "$host" "$port"
            show_picker_or_empty
            ;;
        removeBrain)
            id=$(jq -r '.id // empty' <<<"$line")
            [[ -n "$id" ]] && remove_brain "$id"
            show_picker_or_empty
            ;;
        connect)
            id=$(jq -r '.id // empty' <<<"$line")
            if [[ -n "$id" ]]; then
                log "Connecting to brain id=$id"
                stamp_last_connected "$id"
                do_connect "$id"
            fi
            send_status
            show_picker_or_empty
            ;;
        back)
            send_status
            show_picker_or_empty
            ;;
        *)
            # credentials/retry/reenterPassword/cancelConnect only make
            # sense while do_connect() is running — it consumes them
            # itself via its own read_event() calls. Anything else
            # (unrecognized types, stray events at the picker level) is
            # silently ignored.
            ;;
    esac
done
