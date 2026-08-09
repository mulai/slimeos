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
#   {"type":"forceBack"}                                   bridge-synthesized (see main.go's hotkey watcher) on a
#     held Ctrl+Alt+Backspace; recognized at every blocking-read site in this
#     file/connect.sh/network-setup.sh/pair.sh as an unconditional "give up,
#     return to the picker now" -- unlike plain `back`, never mode-conditional
#     or a partial step-back. Kills an in-flight xfreerdp3 session first if
#     one is running (see connect.sh's xfreerdp3-monitor loop).
#   {"type":"openSettings"}                                dispatched here; opens the tabbed Settings panel (see the
#     openSettings case below) defaulting to its Internet tab
#   {"type":"wifiConnect","ssid":..} | {"type":"wifiPassword","password":..} | {"type":"wifiRescan"} | {"type":"wifiSkip"}
#     (wifiConnect/wifiPassword/wifiRescan/wifiSkip only consumed by do_network_setup, see network-setup.sh —
#      retry/reenterPassword/back are reused there too, same as do_connect does)
#   {"type":"pairSubmit","host":..,"code":..} | {"type":"pairSkip"}
#     (pairSubmit/pairSkip only consumed by do_pair, see pair.sh — retry/back are reused there too)
#   {"type":"supportToggle","enabled":..}                  only consumed by do_support, see support.sh
#   {"type":"crashReportToggle","enabled":..}              only consumed by do_crash_reporting, see crash-reporting.sh
#   {"type":"settingsTab","tab":"internet"|"pair"|"support"|"privacy"}  only consumed by whichever of
#     do_network_setup/do_pair/do_support/do_crash_reporting is currently running in `settings` mode —
#     switches the Settings panel to a different tab without leaving it (see the
#     openSettings case's SETTINGS_NEXT_TAB loop below)
#   {"type":"crashConsent","granted":true|false}            handled directly here (see the outer dispatch's
#     crashConsent case) — a one-shot answer to the 'showCrashConsent' popup, writes
#     $CONFIG_DIR/crash-reporting-consent and never re-appears once answered
#   {"type":"crashReport","message":..,"stack":..,"state":..}  recognized regardless of which do_*
#     currently owns the event loop, same as powerShutdown/powerRestart — see
#     try_handle_crash_report() in crash-reporting.sh and its call sites in every
#     do_*'s catch-all
#   {"type":"powerShutdown"} | {"type":"powerRestart"}      already confirmed client-side (see index.html); no response emitted, the machine powers off/reboots
#   {"type":"slimeIdStart"}                                handled directly here — a direct user-initiated action from
#     the empty/picker screen's "Sign in with Slime ID" button, NOT boot-gated and NOT part of the
#     tabbed Settings panel (no settingsTab involvement). Calls do_slime_id_login(), see slime-id.sh —
#     deliberately scoped to just the login handshake (proves identity, stores a session token), no
#     brain listing or auto-provisioning yet.
#   {"type":"slimeIdLogout"}                               handled directly here — the "Sign out" link next to
#     "Signed in as ..." on empty/picker. Calls slime_id_logout() (slime-id.sh): best-effort revoke
#     call to /api/device/logout, then clears $CONFIG_DIR/slime-id-session regardless of whether
#     that call succeeded.
#   {"type":"saveBrainConsent","save":..,"name":..,"host":..,"port":..}  one-shot answer to the
#     'showSaveBrainPrompt' overlay below (same shape as crashConsent) -- if save=true, best-effort
#     POSTs the brain to /api/device/brains-save so it shows up in this account's Slime ID dashboard
#     and on any other signed-in device. Opt-in, never automatic -- see brains-save.ts's own comment.
#
# Write (stdout), one JSON object per line — mirrors window.SlimeUI 1:1:
#   {"type":"setState","state":"empty|picker|addBrain|credentials|connecting|error|reconnecting|wifiList|wifiPassword|wifiConnecting|wifiError|pairEntry|pairConnecting|pairError|supportSettings|crashReportSettings|slimeIdConnecting|slimeIdEntry|slimeIdError","data":{...}}
#   {"type":"setStatus","clock":"HH:MM","tunnel":"up|down|connecting"}
#   {"type":"showCrashConsent"}                            one-shot, not a setState — see index.html's doc comment
#   {"type":"showSaveBrainPrompt","data":{"name":..,"host":..,"port":..}}  one-shot, not a setState,
#     same shape as showCrashConsent -- shown right after a brain is added locally (addBrain case
#     below) while signed in to Slime ID. Answered via `saveBrainConsent`, see above.
#
# `data` shapes are exactly what membrane/lockscreen/index.html's header
# comment documents. `addBrain` state is rendered entirely client-side (the
# form itself needs no backend round-trip); this script only ever emits
# empty/picker/credentials/connecting/error/reconnecting/wifiList/
# wifiPassword/wifiConnecting/wifiError/pairEntry/pairConnecting/pairError/
# supportSettings/crashReportSettings/slimeIdConnecting/slimeIdEntry/slimeIdError.
# `empty`/`picker` both additionally carry `signedInEmail` (null unless
# do_slime_id_login() has ever successfully signed this device in).
# `picker`'s brain entries additionally carry `remote` (true for a Slime
# ID bookmark not yet paired on this device -- see REMOTE_BRAINS_JSON
# below and pair.sh's PAIR_HINT); `pairEntry` additionally carries an
# optional `hint` string, set only when entered via such a bookmark.
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

# Used to gate the automatic network-setup screen (see network_checked
# below). A retry window (not an instant single check) avoids a false
# "offline" reading on a link that's still coming up right at boot — same
# shape as slimeos-session.sh's own MAX_WAIT wait for wg0. Callers pick the
# window: Ethernet negotiates within a few seconds, but WiFi
# (firmware load + scan + WPA handshake + DHCP) routinely needs 10-30s, so
# a saved WiFi profile that WOULD autoconnect loses a short race and the
# setup screen re-appears on every boot asking for a network the device
# already knows — confirmed on real hardware.
have_default_route() {
    local max_wait="${1:-5}" waited=0
    while [[ -z "$(ip route show default 2>/dev/null)" ]]; do
        (( waited >= max_wait )) && return 1
        sleep 1
        waited=$((waited + 1))
    done
    return 0
}

# Whether NetworkManager already holds a WiFi profile it will bring up on
# its own (autoconnect defaults to yes for profiles nm_connect() creates).
# Read-only nmcli query — allowed for any user by default polkit policy, no
# custom rule needed.
have_saved_wifi_profile() {
    nmcli -t -f TYPE,AUTOCONNECT connection show 2>/dev/null \
        | grep -q '^802-11-wireless:yes$'
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
# /gfx:AVC444 — H.264 4:4:4 over the graphics pipeline. Negotiated, so
# Brains without GFX/H.264 (xrdp 0.9) silently fall back to the older
# codecs, while Windows Brains get dramatically smoother video playback
# than bare /gfx's RemoteFX-progressive. Debian's freerdp3 links
# libavcodec, so the decoder is always present. No /network here — the
# old "/network:broadband" duplicated do_connect()'s own
# /network:$RDP_NETWORK and, coming later on the command line, silently
# overrode whatever the config file said.
SLIMEOS_FREERDP_EXTRA_FLAGS="/gfx:AVC444 /bpp:32"
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
# shellcheck source=support.sh
source "$INSTALL_DIR/support.sh" # defines do_support()
# shellcheck source=crash-reporting.sh
source "$INSTALL_DIR/crash-reporting.sh" # defines do_crash_reporting(), try_handle_crash_report()
# shellcheck source=slime-id.sh
source "$INSTALL_DIR/slime-id.sh" # defines do_slime_id_login(), slime_id_logout()

# Gates the automatic (boot-mode) network-setup / pairing screens to once
# per coordinator process, not once per _clientConnected -- that event also
# fires on every WS reconnect and bridge-crash-recovery resync, which would
# otherwise re-trigger the checks (and network_checked's up-to-5s
# have_default_route wait) on every client reattach.
network_checked=false
wg_checked=false
consent_checked=false

# Cache of this account's Slime ID-bookmarked brains (see brains-list.ts),
# refreshed explicitly at a few entry points (refresh_remote_brains, below)
# rather than on every show_picker_or_empty call -- that function runs on
# nearly every screen transition (back, settings close, post-connect...),
# and a network round trip on each of those would make routine navigation
# feel laggy. "[]" (not signed in, or last fetch failed) always degrades to
# "no bookmarks shown", never blocks the picker.
REMOTE_BRAINS_JSON="[]"

# Set by do_network_setup()/do_pair()/do_support() (see each of their
# `settingsTab` cases) when the Settings panel's tab bar is clicked while
# one of them is running -- read by the openSettings case's dispatch loop
# below, immediately after that function returns, to decide whether to
# re-enter the panel on a different tab or actually close it. Global (not a
# local passed by reference) because these three functions are `source`d
# into this same process and already share every other coordinator.sh
# helper the same way.
SETTINGS_NEXT_TAB=""

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

# Best-effort POST to /api/device/brains-list -- same non-fatal posture as
# slime_id_logout's revoke call (SLIME_ID_API/SLIME_ID_SESSION_FILE are
# defined in slime-id.sh, sourced before this is ever called). Any failure
# (offline, expired token, server error) just yields "[]", same as "signed
# out" -- never blocks or errors the picker.
fetch_remote_brains() {
    local token
    token=$(jq -r '.token // empty' "$SLIME_ID_SESSION_FILE" 2>/dev/null)
    if [[ -z "$token" ]]; then
        echo '[]'
        return
    fi

    set +e
    local response
    response=$(curl -fsS -m 5 -X POST -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg t "$token" '{session_token:$t}')" \
        "$SLIME_ID_API/device/brains-list" 2>/dev/null)
    set -e

    jq -c '.brains // []' <<<"$response" 2>/dev/null || echo '[]'
}

# Refreshes REMOTE_BRAINS_JSON. Called at real entry points (client
# reconnect, right after a Slime ID login/logout, after a bookmark
# reconnect) rather than on every picker render -- see REMOTE_BRAINS_JSON's
# own comment above.
refresh_remote_brains() {
    if [[ -z "$(signed_in_email)" ]]; then
        REMOTE_BRAINS_JSON='[]'
        return
    fi
    REMOTE_BRAINS_JSON=$(fetch_remote_brains)
}

# Best-effort POST to /api/device/brains-save -- only ever called after the
# user explicitly answers "yes" to the showSaveBrainPrompt overlay
# (saveBrainConsent case below), never automatically. A failure here just
# means the bookmark isn't saved this time; the brain itself was already
# added locally by add_brain() regardless, so there's nothing to roll back.
save_remote_brain() {
    local name="$1" host="$2" port="$3" token
    token=$(jq -r '.token // empty' "$SLIME_ID_SESSION_FILE" 2>/dev/null)
    [[ -z "$token" ]] && return 0

    set +e
    curl -fsS -m 5 -X POST -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg t "$token" --arg n "$name" --arg h "$host" --arg p "$port" \
            '{session_token:$t, name:$n, host:$h, port:$p}')" \
        "$SLIME_ID_API/device/brains-save" >/dev/null 2>&1
    local rc=$?
    set -e

    if [[ $rc -eq 0 ]]; then
        log "Saved brain '$name' to Slime ID"
    else
        log "Failed to save brain '$name' to Slime ID (non-fatal)"
    fi
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

# Purely a local-state read, no live validation against the backend --
# see slime-id.sh's own header comment on why this pass stops at "prove
# the handshake works." A stale/expired token still shows as signed in
# here; nothing yet depends on it being valid.
#
# Always returns 0 regardless of whether a session exists -- every caller
# assigns this via `email=$(signed_in_email)`, and under set -e a
# non-zero exit from the RIGHT side of an assignment kills the whole
# coordinator, not just this function. (Bit exactly this on the first
# on-device test: every _clientConnected call show_picker_or_empty() ->
# signed_in_email() on a device with no session yet -- i.e. nearly always
# -- crash-looped the coordinator every ~2s.) The explicit `return 0` as
# the last line is load-bearing, not decorative -- don't remove it.
signed_in_email() {
    [[ -s "$SLIME_ID_SESSION_FILE" ]] && jq -r '.email // empty' "$SLIME_ID_SESSION_FILE" 2>/dev/null
    return 0
}

show_picker_or_empty() {
    local count remote_count email
    count=$(jq 'length' "$BRAINS_FILE")
    remote_count=$(jq 'length' <<<"$REMOTE_BRAINS_JSON" 2>/dev/null || echo 0)
    email=$(signed_in_email)
    if [[ "$count" -eq 0 && "$remote_count" -eq 0 ]]; then
        emit_state empty "$(jq -nc --arg e "$email" '{signedInEmail:(if $e == "" then null else $e end)}')"
        return
    fi

    local entries=()
    while IFS=$'\t' read -r id name host last; do
        local rel
        rel=$(relative_time "$last")
        entries+=("$(jq -nc --arg id "$id" --arg name "$name" --arg host "$host" --arg rel "$rel" \
            '{id:$id, name:$name, host:$host, lastConnected:$rel, remote:false}')")
    done < <(jq -r '.[] | [.id, .name, .host, (.lastConnected // "")] | @tsv' "$BRAINS_FILE")

    # Slime ID bookmarks not already paired on this device (matched by
    # host+port against the local brains.json) -- rendered as distinct
    # "tap to reconnect" cards. Skipping ones already paired here avoids
    # showing the same brain twice once it's been both saved AND paired
    # on this particular kiosk.
    while IFS=$'\t' read -r rid rname rhost rport; do
        [[ -z "$rid" ]] && continue
        if jq -e --arg h "$rhost" --arg p "$rport" \
            'any(.[]; .host == $h and ((.port // "") == $p))' "$BRAINS_FILE" >/dev/null 2>&1; then
            continue
        fi
        entries+=("$(jq -nc --arg id "remote:$rid" --arg name "$rname" --arg host "$rhost" \
            '{id:$id, name:$name, host:$host, lastConnected:"Tap to reconnect", remote:true}')")
    done < <(jq -r '.[] | [.id, .name, (.host // ""), (.port // "")] | @tsv' <<<"$REMOTE_BRAINS_JSON")

    local brains_json
    brains_json=$(printf '%s\n' "${entries[@]}" | jq -sc '.')
    emit_state picker "$(jq -nc --argjson b "$brains_json" --arg e "$email" \
        '{brains:$b, signedInEmail:(if $e == "" then null else $e end)}')"
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
                # Give a saved WiFi profile time to autoconnect before
                # concluding the device is offline (see have_default_route's
                # comment); a device with no saved WiFi keeps the short
                # window so first-boot onboarding still appears promptly.
                route_wait=5
                have_saved_wifi_profile && route_wait=30
                if ! have_default_route "$route_wait"; then
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
            refresh_remote_brains
            send_status
            show_picker_or_empty
            # Once only, ever, per device. install.sh seeds this file with
            # literal content "unset" at install time (so crashConsent's
            # write handler is always an overwrite, never a create -- see
            # its own comment) -- check CONTENT, not mere existence, or a
            # freshly installed device (file always present) would never
            # show this at all. Missing entirely (e.g. a hand-patched
            # device predating this feature) is treated the same as
            # "unset". Deliberately checked last (after network/pairing) so
            # it never competes with first-boot onboarding, and sent as its
            # own message rather than a setState — see index.html's
            # 'showCrashConsent' doc comment — so it overlays whatever
            # screen show_picker_or_empty just rendered instead of
            # replacing it.
            if ! $consent_checked; then
                consent_checked=true
                consent_state=$(cat "$CONFIG_DIR/crash-reporting-consent" 2>/dev/null || echo "unset")
                if [[ "$consent_state" == "unset" ]]; then
                    jq -nc '{type:"showCrashConsent"}'
                fi
            fi
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
            # Opt-in, never automatic (see brains-save.ts) -- only offered
            # when a brain was actually added and the device is signed in.
            if [[ -n "$host" && -n "$(signed_in_email)" ]]; then
                jq -nc --arg n "${name:-Untitled Brain}" --arg h "$host" --arg p "$port" \
                    '{type:"showSaveBrainPrompt", data:{name:$n, host:$h, port:$p}}'
            fi
            ;;
        saveBrainConsent)
            save=$(jq -r '.save // false' <<<"$line")
            if [[ "$save" == "true" ]]; then
                sname=$(jq -r '.name // empty' <<<"$line")
                shost=$(jq -r '.host // empty' <<<"$line")
                sport=$(jq -r '.port // empty' <<<"$line")
                [[ -n "$shost" ]] && save_remote_brain "${sname:-Untitled Brain}" "$shost" "$sport"
            fi
            ;;
        removeBrain)
            id=$(jq -r '.id // empty' <<<"$line")
            [[ -n "$id" ]] && remove_brain "$id"
            show_picker_or_empty
            ;;
        crashConsent)
            granted=$(jq -r '.granted // false' <<<"$line")
            # install.sh pre-creates this file (world-unwritable dir,
            # slime-owned file) specifically so this is always an overwrite,
            # never a create -- but don't let a failure here (stale/
            # hand-patched device missing that seed file, disk full, etc.)
            # take down the whole coordinator under set -e. Worst case: the
            # popup just reappears next time instead of silently corrupting
            # session state.
            if [[ "$granted" == "true" ]]; then
                echo "granted" > "$CONFIG_DIR/crash-reporting-consent" || log "Failed to write crash-reporting-consent (granted)"
            else
                echo "declined" > "$CONFIG_DIR/crash-reporting-consent" || log "Failed to write crash-reporting-consent (declined)"
            fi
            ;;
        connect)
            id=$(jq -r '.id // empty' <<<"$line")
            if [[ "$id" == remote:* ]]; then
                # A Slime ID bookmark, not yet paired on this device --
                # Slime ID never holds the WireGuard credential for a free
                # Brain (see pair.sh's own doc comment), so this routes
                # into the normal pairing form instead of connecting
                # directly. PAIR_HINT (read by pair.sh's do_pair) just
                # carries the remembered name/host through as context; it
                # doesn't skip the fresh pairing-code entry.
                rid="${id#remote:}"
                rname=$(jq -r --arg id "$rid" '.[] | select(.id == $id) | .name // empty' <<<"$REMOTE_BRAINS_JSON" | head -n1)
                rhost=$(jq -r --arg id "$rid" '.[] | select(.id == $id) | .host // empty' <<<"$REMOTE_BRAINS_JSON" | head -n1)
                log "Reconnecting to bookmarked brain '$rname' ($rhost) — needs a fresh pairing code"
                PAIR_HINT="Reconnecting to \"${rname:-a saved Brain}\"${rhost:+ ($rhost)} — enter a fresh pairing code from its enroll screen."
                do_pair settings
                PAIR_HINT=""
                refresh_remote_brains
            elif [[ -n "$id" ]]; then
                log "Connecting to brain id=$id"
                stamp_last_connected "$id"
                do_connect "$id"
            fi
            send_status
            show_picker_or_empty
            ;;
        slimeIdStart)
            do_slime_id_login
            refresh_remote_brains
            send_status
            show_picker_or_empty
            ;;
        slimeIdLogout)
            slime_id_logout
            refresh_remote_brains
            send_status
            show_picker_or_empty
            ;;
        back|forceBack)
            send_status
            show_picker_or_empty
            ;;
        openSettings)
            # Gear icon: opens the tabbed Settings panel, always starting on
            # its Internet tab. Each do_* function returns 0 either because
            # the user closed the panel entirely (back/forceBack, or a
            # completed action like a successful WiFi reconnect -- see
            # network-setup.sh's unconditional `return 0` on connect
            # success) or because a tab click interrupted it, in which case
            # it sets SETTINGS_NEXT_TAB before returning. Only the latter
            # case loops back around; anything else falls through to the
            # normal post-flow resync below, same as every other case here.
            settings_tab="internet"
            while true; do
                SETTINGS_NEXT_TAB=""
                case "$settings_tab" in
                    internet) do_network_setup settings ;;
                    pair)     do_pair settings ;;
                    support)  do_support settings ;;
                    privacy)  do_crash_reporting settings ;;
                esac
                [[ -n "$SETTINGS_NEXT_TAB" ]] || break
                settings_tab="$SETTINGS_NEXT_TAB"
            done
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
        crashReport)
            try_handle_crash_report "$ev_type" "$line"
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
