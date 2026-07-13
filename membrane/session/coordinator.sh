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
#   {"type":"networkSettings"}                             dispatched here; hands off to do_network_setup (see network-setup.sh)
#   {"type":"wifiConnect","ssid":..} | {"type":"wifiPassword","password":..} | {"type":"wifiRescan"} | {"type":"wifiSkip"}
#     (wifiConnect/wifiPassword/wifiRescan/wifiSkip only consumed by do_network_setup, see network-setup.sh —
#      retry/reenterPassword/back are reused there too, same as do_connect does)
#   {"type":"pairSettings"}                                  dispatched here; hands off to do_pair (see pair.sh)
#   {"type":"pairSubmit","host":..,"code":..} | {"type":"pairSkip"}
#     (pairSubmit/pairSkip only consumed by do_pair, see pair.sh — retry/back are reused there too)
#   {"type":"powerShutdown"} | {"type":"powerRestart"}      already confirmed client-side (see index.html); no response emitted, the machine powers off/reboots
#
# Write (stdout), one JSON object per line — mirrors window.SlimeUI 1:1:
#   {"type":"setState","state":"empty|picker|addBrain|credentials|connecting|error|reconnecting|wifiList|wifiPassword|wifiConnecting|wifiError|pairEntry|pairConnecting|pairError","data":{...}}
#   {"type":"setStatus","clock":"HH:MM","tunnel":"up|down|connecting"}
#
# `data` shapes are exactly what membrane/lockscreen/index.html's header
# comment documents. `addBrain` state is rendered entirely client-side (the
# form itself needs no backend round-trip); this script only ever emits
# empty/picker/credentials/connecting/error/reconnecting/wifiList/
# wifiPassword/wifiConnecting/wifiError/pairEntry/pairConnecting/pairError.
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

# Used both to gate the automatic network-setup screen (see network_checked
# below) and by network-setup.sh's own wifiList "ethernetUp" hint. A short
# retry window (not an instant single check) avoids a false "offline"
# reading on a slow-negotiating Ethernet link right at boot — same shape as
# slimeos-session.sh's own MAX_WAIT wait for wg0.
have_default_route() {
    local waited=0
    while [[ -z "$(ip route show default 2>/dev/null)" ]]; do
        (( waited >= 5 )) && return 1
        sleep 1
        waited=$((waited + 1))
    done
    return 0
}

# File existence, not `ip link show wg0`: this is a durable "has this device
# already been paired" marker. Link state is transient runtime status
# (already reported separately by send_status()'s tunnel indicator) and
# would wrongly re-trigger the pairing screen if the interface is just
# administratively down.
have_wg_tunnel() { [[ -f /etc/wireguard/wg0.conf ]]; }

read_event() {
    local line
    IFS= read -r line <&0 || return 1
    printf '%s' "$line"
}

# do_connect()/do_network_setup()/do_pair() each take over the event loop
# with their own blocking read_event() calls -- while any of them "owns" it,
# an unrecognized event type (including powerShutdown/powerRestart) falls
# into that loop's own catch-all and is silently dropped, never reaching the
# outer dispatch's powerShutdown/powerRestart cases below. Confirmed live:
# the power button visibly did nothing while sitting on the pairing screen.
# Every blocking-read site in connect.sh/network-setup.sh/pair.sh checks
# this first for any event type it doesn't itself recognize, so power off/
# restart works from any screen, not just the idle picker. Returns 0 (and
# acts) if it was a power event, 1 otherwise -- callers fall through to
# their own no-op on a 1.
try_handle_power_event() {
    case "$1" in
        powerShutdown)
            log "Power: shutdown requested"
            systemctl poweroff || log "ERROR: systemctl poweroff failed — check org.freedesktop.login1.power-off polkit rule"
            ;;
        powerRestart)
            log "Power: restart requested"
            systemctl reboot || log "ERROR: systemctl reboot failed — check org.freedesktop.login1.reboot polkit rule"
            ;;
        *)
            return 1
            ;;
    esac
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
# shellcheck source=network-setup.sh
source "$INSTALL_DIR/network-setup.sh" # defines do_network_setup()
# shellcheck source=pair.sh
source "$INSTALL_DIR/pair.sh" # defines do_pair()

# Gates the automatic (boot-mode) network-setup / pairing screens to once
# per coordinator process, not once per _clientConnected -- that event also
# fires on every WS reconnect and bridge-crash-recovery resync, which would
# otherwise re-trigger the checks (and network_checked's up-to-5s
# have_default_route wait) on every client reattach.
network_checked=false
wg_checked=false

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
            if ! $network_checked; then
                network_checked=true
                if ! have_default_route; then
                    log "No default route detected — entering network setup (boot mode)"
                    do_network_setup boot
                fi
            fi
            if ! $wg_checked; then
                wg_checked=true
                if ! have_wg_tunnel; then
                    log "No WireGuard tunnel configured — entering pairing (boot mode)"
                    do_pair boot
                fi
            fi
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
        networkSettings)
            do_network_setup settings
            send_status
            show_picker_or_empty
            ;;
        pairSettings)
            do_pair settings
            send_status
            show_picker_or_empty
            ;;
        powerShutdown|powerRestart)
            # `|| log ...` inside the helper, not a bare call: a failure here
            # (e.g. a polkit rule not authorizing it) must not crash the
            # whole coordinator under set -e -- same lesson as the
            # once-missing connect.log guard in connect.sh.
            try_handle_power_event "$ev_type"
            ;;
        *)
            # credentials/retry/reenterPassword/cancelConnect only make
            # sense while do_connect() is running, wifiConnect/
            # wifiPassword/wifiRescan/wifiSkip (plus retry/reenterPassword/
            # back again) only make sense while do_network_setup() is
            # running, and pairSubmit/pairSkip (plus retry/back again) only
            # make sense while do_pair() is running — each consumes its own
            # events directly via its own read_event() calls. Anything else
            # (unrecognized types, stray events at the picker level) is
            # silently ignored.
            ;;
    esac
done
