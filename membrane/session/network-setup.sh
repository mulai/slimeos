#!/usr/bin/env bash
# Slime OS — Network setup (WiFi + Ethernet onboarding) function library
#
# `source`d by membrane/session/coordinator.sh, exactly like
# membrane/freerdp/connect.sh's do_connect(): it relies on coordinator.sh's
# own log()/emit_state()/emit_status()/read_event()/have_default_route()
# helpers rather than redefining them.
#
# do_network_setup(mode) takes over the event-reading loop the same way
# do_connect() does -- coordinator.sh's outer dispatch is not read from
# again until this function returns. `mode` is "boot" (no working network
# yet, shown automatically before the picker -- Skip button, no Back) or
# "settings" (opened deliberately via the picker's gear icon while a network
# already works -- Back button, no Skip).
#
# Phases, dispatched via a `phase` local. Unlike do_connect() (which nests
# three loop levels deep in its "connect" phase), every phase here is
# exactly two levels deep -- the outer phase-dispatch loop, and one inner
# event-read loop -- so `continue 2` always means "back to the phase
# dispatcher" throughout this file:
#   "list"       -- nmcli scan results; Skip/Back return from here.
#   "password"   -- only entered for a secured SSID; blocks on wifiPassword.
#   "connecting" -- runs nmcli device wifi connect; success returns 0 (falls
#                   through to coordinator.sh's normal send_status/
#                   show_picker_or_empty, same as do_connect() returning).

nm_scan_wifi() {
    # Best-effort: a very recent previous scan makes this a harmless no-op --
    # don't fail the whole flow if the radio is mid-scan already.
    nmcli device wifi rescan &>/dev/null || true
    sleep 1

    local entries=() raw ssid signal security secured protected
    while IFS= read -r raw; do
        [[ -z "$raw" ]] && continue
        # nmcli -t terse output escapes literal colons inside field values
        # as \: -- a plain `IFS=':' read` would split on those too, so swap
        # escaped colons for a sentinel byte before splitting on ':', then
        # restore real colons in the extracted SSID afterward. (Confirmed
        # necessary via a local test harness with a fake `Weird\:SSID`
        # entry -- the naive split silently truncated it to "Weird\".)
        protected="${raw//\\:/$'\x01'}"
        IFS=':' read -r ssid signal security <<<"$protected"
        ssid="${ssid//$'\x01'/:}"
        [[ -z "$ssid" ]] && continue
        secured="false"
        [[ -n "$security" && "$security" != "--" ]] && secured="true"
        entries+=("$(jq -nc --arg ssid "$ssid" --arg signal "$signal" --argjson secured "$secured" \
            '{ssid:$ssid, signal:($signal|tonumber? // null), secured:$secured}')")
    done < <(nmcli -t -f SSID,SIGNAL,SECURITY device wifi list 2>/dev/null)

    if [[ ${#entries[@]} -eq 0 ]]; then
        echo '[]'
    else
        # Dedup by SSID (a network in range of multiple APs/bands lists once
        # per BSSID), keeping the strongest signal, sorted strongest-first.
        printf '%s\n' "${entries[@]}" | jq -sc \
            'group_by(.ssid) | map(max_by(.signal // 0)) | sort_by(-(.signal // 0))'
    fi
}

nm_connect() {
    local ssid="$1" password="${2:-}"
    local con_name="slimeos-wifi-$ssid"
    # `nmcli connection add` + `up` instead of the `device wifi connect`
    # shortcut: that shortcut infers 802-11-wireless-security.key-mgmt from
    # nmcli's own scan cache, which doesn't always populate reliably --
    # confirmed on real hardware failing with "802-11-wireless-security.
    # key-mgmt: property is missing" even with a correct password. Setting
    # key-mgmt explicitly at profile-creation time sidesteps that detection
    # entirely. Delete any stale profile from a previous attempt (both our
    # own naming and the shortcut's default SSID-as-name) so retries don't
    # collide with a half-configured leftover.
    nmcli connection delete "$con_name" &>/dev/null || true
    nmcli connection delete "$ssid" &>/dev/null || true

    local output exit_code
    if [[ -n "$password" ]]; then
        output=$(nmcli connection add type wifi con-name "$con_name" ifname "*" ssid "$ssid" \
            wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$password" 2>&1)
    else
        output=$(nmcli connection add type wifi con-name "$con_name" ifname "*" ssid "$ssid" 2>&1)
    fi
    exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo "$output"
        return $exit_code
    fi

    nmcli connection up "$con_name" 2>&1
}

# Which device type is actually providing connectivity right now. Not the
# same question as coordinator.sh's have_default_route() (any route at all,
# used only to gate whether to show this screen automatically at boot) --
# confirmed live that reusing that generic check here mislabeled an active
# WiFi connection as "Ethernet is connected" once Ethernet was physically
# unplugged, because a route still existed (via WiFi), just not the one the
# message claimed.
active_connection_type() {
    if nmcli -t -f TYPE,STATE device status 2>/dev/null | grep -q '^ethernet:connected$'; then
        echo "ethernet"
    elif nmcli -t -f TYPE,STATE device status 2>/dev/null | grep -q '^wifi:connected$'; then
        echo "wifi"
    fi
}

# The active connection's *name* (con-name) is "slimeos-wifi-<ssid>" (see
# nm_connect above), not the bare SSID -- query the real broadcast SSID
# directly instead of stripping our own naming convention back apart.
active_wifi_ssid() {
    nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}'
}

do_network_setup() {
    local mode="$1"
    local phase="list"
    local ssid="" password="" secured="false"
    local last_scan="[]"

    while true; do
        if [[ "$phase" == "list" ]]; then
            log "Network setup ($mode): scanning for Wi-Fi networks"
            last_scan="$(nm_scan_wifi)" || last_scan='[]'
            local conn_type conn_ssid=""
            conn_type=$(active_connection_type)
            [[ "$conn_type" == "wifi" ]] && conn_ssid=$(active_wifi_ssid)
            emit_state wifiList "$(jq -nc --argjson n "$last_scan" --arg mode "$mode" --arg connType "$conn_type" --arg connSsid "$conn_ssid" \
                '{networks:$n, scanning:false, mode:$mode, connectionType:$connType, connectionSsid:$connSsid, skippable:($mode=="boot")}')"

            while true; do
                local line ev_type
                line=$(read_event) || return 0
                ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
                case "$ev_type" in
                    wifiConnect)
                        ssid=$(jq -r '.ssid // empty' <<<"$line")
                        [[ -z "$ssid" ]] && continue
                        secured=$(jq -r --arg s "$ssid" '.[] | select(.ssid == $s) | .secured' \
                            <<<"$last_scan" 2>/dev/null || echo false)
                        [[ "$secured" == "true" ]] && phase="password" || phase="connecting"
                        continue 2
                        ;;
                    wifiRescan)
                        continue 2
                        ;;
                    wifiSkip)
                        [[ "$mode" == "boot" ]] && return 0
                        ;;
                    back)
                        [[ "$mode" == "settings" ]] && return 0
                        ;;
                    *) try_handle_power_event "$ev_type" || : ;;
                esac
            done
        fi

        if [[ "$phase" == "password" ]]; then
            emit_state wifiPassword "$(jq -nc --arg ssid "$ssid" --arg mode "$mode" '{ssid:$ssid, mode:$mode}')"
            while true; do
                local line ev_type
                line=$(read_event) || return 0
                ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
                case "$ev_type" in
                    wifiPassword)
                        password=$(jq -r '.password // empty' <<<"$line")
                        phase="connecting"
                        continue 2
                        ;;
                    back)
                        phase="list"
                        continue 2
                        ;;
                    *) try_handle_power_event "$ev_type" || : ;;
                esac
            done
        fi

        if [[ "$phase" == "connecting" ]]; then
            emit_state wifiConnecting "$(jq -nc --arg ssid "$ssid" '{ssid:$ssid, stage:"Connecting to Wi-Fi…"}')"
            log "Network setup: connecting to '$ssid'"

            # nmcli's own exit code must NOT kill this script under set -e --
            # a failed connect is an expected, handled outcome here, not a
            # bug (same reasoning as connect.sh's `set +e` around xfreerdp3).
            set +e
            local output exit_code
            output=$(nm_connect "$ssid" "$password")
            exit_code=$?
            set -e

            if [[ $exit_code -eq 0 ]]; then
                log "Network setup: connected to '$ssid'"
                return 0
            fi

            log "nmcli connect to '$ssid' failed (exit $exit_code): $output"
            # nmcli has no fine-grained ERRCONNECT_*-style codes the way
            # FreeRDP's error.h does -- classify from its own stderr text.
            local message
            if grep -qi 'secrets were required\|no suitable device' <<<"$output"; then
                message="That password didn't work."
            elif grep -qi 'no network with ssid' <<<"$output"; then
                message="That network is no longer in range."
            else
                message="Couldn't connect to that network."
            fi
            emit_state wifiError "$(jq -nc --arg ssid "$ssid" --arg m "$message" --arg d "$output" --arg mode "$mode" --argjson secured "$secured" \
                '{ssid:$ssid, message:$m, detail:$d, mode:$mode, secured:$secured}')"

            while true; do
                local line ev_type
                line=$(read_event) || return 0
                ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
                case "$ev_type" in
                    retry) phase="connecting"; continue 2 ;;
                    reenterPassword)
                        [[ "$secured" == "true" ]] || continue
                        password=""
                        phase="password"
                        continue 2
                        ;;
                    back) phase="list"; continue 2 ;;
                    *) try_handle_power_event "$ev_type" || : ;;
                esac
            done
        fi
    done
}
