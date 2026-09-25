#!/usr/bin/env bash
# Slime OS — WireGuard self-service pairing
#
# `source`d by membrane/session/coordinator.sh, exactly like
# membrane/session/network-setup.sh's do_network_setup(): it relies on
# coordinator.sh's own log()/emit_state()/read_event() helpers rather than
# redefining them.
#
# do_pair(mode) takes over the event-reading loop the same way
# do_network_setup() does. `mode` is "boot" (no WireGuard tunnel configured
# yet, shown automatically before the picker -- Skip button, no Back) or
# "settings" (opened deliberately via the Settings panel's Pairing tab --
# Back button, no Skip; lets a device add/replace its tunnel later;
# coordinator.sh's openSettings case can also re-enter this function on a
# `settingsTab` event without the panel ever closing -- see this file's
# "entry" phase).
#
# This is part of the open-source, account-free Connect path: it talks to a
# Brain's enrollment endpoint (brain/enroll/) over plain HTTPS, never to
# Authelia/dashboard.slimeos.com -- that's the separate, not-yet-built
# "Sign in with Slime ID" managed path.
#
# Phases, dispatched via a `phase` local, same two-levels-deep shape as
# network-setup.sh's do_network_setup():
#   "entry"    -- host+code entry form; Skip/Back return from here.
#   "fetching" -- POSTs the code to the enrollment endpoint, installs the
#                 resulting wg0.conf, and brings the tunnel up; success
#                 returns 0 (falls through to coordinator.sh's normal
#                 send_status/show_picker_or_empty, same as
#                 do_network_setup() returning).

pair_fetch_config() {
    local host="$1" code="$2"
    local body response http_code payload

    body=$(jq -nc --arg code "$code" '{code:$code}')

    response=$(curl -fsS -m 15 -w '\n%{http_code}' -X POST \
        -H 'Content-Type: application/json' -d "$body" \
        "https://${host}/pair" 2>&1) || true
    http_code=$(tail -n1 <<<"$response")
    payload=$(sed '$d' <<<"$response")

    if [[ "$http_code" != "200" ]]; then
        echo "${payload} (HTTP ${http_code:-none})"
        return 1
    fi

    local config
    config=$(jq -r '.config // empty' <<<"$payload" 2>/dev/null)
    if [[ -z "$config" ]]; then
        echo "Enrollment endpoint returned no config: $payload"
        return 1
    fi
    echo "$config"
}

# The config comes from whatever host was typed on the pairing screen, and
# wg-quick runs PreUp/PostUp/PreDown/PostDown (and a few other keys) as root.
# So never install it as received (#38): parse it, allow only the keys a
# Slime OS tunnel needs, check each value's shape, and write a fresh config
# from the parsed fields. Prints the rebuilt config, or an error and 1.
pair_sanitize_config() {
    local config="$1" line section="" key value
    local iface="" peers="" peer="" have_iface=false n_peers=0
    local re_key='^[A-Za-z0-9+/]{43}=$'
    local re_ip='[0-9A-Fa-f:.]{2,45}'
    local re_cidr_list="^${re_ip}(/[0-9]{1,3})?(, *${re_ip}(/[0-9]{1,3})?)*$"
    local re_ip_list="^${re_ip}(, *${re_ip})*$"
    local re_endpoint='^([A-Za-z0-9.-]{1,253}|\[[0-9A-Fa-f:.]{2,45}\]):[0-9]{1,5}$'

    _pair_end_peer() {
        [[ "$section" == peer ]] || return 0
        grep -q '^PublicKey = ' <<<"$peer" && grep -q '^AllowedIPs = ' <<<"$peer" \
            || { echo "Rejected WireGuard config: a [Peer] lacks PublicKey or AllowedIPs"; return 1; }
        peers+=$'\n[Peer]\n'"$peer"
        peer=""
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue

        case "${line,,}" in
            '[interface]')
                $have_iface && { echo "Rejected WireGuard config: more than one [Interface]"; return 1; }
                have_iface=true; section=interface; continue ;;
            '[peer]')
                _pair_end_peer || return 1
                section=peer; n_peers=$((n_peers + 1)); peer=""; continue ;;
        esac

        [[ "$line" == *=* ]] || { echo "Rejected WireGuard config: unexpected line"; return 1; }
        key="${line%%=*}"; value="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        # provision-peer.sh writes `DNS = ` when the hub has no DNS line.
        [[ -z "$value" ]] && continue

        case "$section:${key,,}" in
            interface:privatekey)   [[ "$value" =~ $re_key ]] && iface+="PrivateKey = $value"$'\n' ;;
            interface:address)      [[ "$value" =~ $re_cidr_list ]] && iface+="Address = $value"$'\n' ;;
            interface:dns)          [[ "$value" =~ $re_ip_list ]] && iface+="DNS = $value"$'\n' ;;
            interface:mtu)          [[ "$value" =~ ^[0-9]{3,4}$ ]] && (( 10#$value >= 576 && 10#$value <= 9000 )) \
                                        && iface+="MTU = $value"$'\n' ;;
            peer:publickey)         [[ "$value" =~ $re_key ]] && peer+="PublicKey = $value"$'\n' ;;
            peer:presharedkey)      [[ "$value" =~ $re_key ]] && peer+="PresharedKey = $value"$'\n' ;;
            peer:endpoint)          [[ "$value" =~ $re_endpoint ]] && peer+="Endpoint = $value"$'\n' ;;
            # A Slime OS tunnel only routes to Brains; never let a pairing
            # host take over the device's whole default route.
            peer:allowedips)        [[ "$value" =~ $re_cidr_list && ! "$value" =~ (^|[ ,])(0\.0\.0\.0|::)/0($|[ ,]) ]] \
                                        && peer+="AllowedIPs = $value"$'\n' ;;
            peer:persistentkeepalive) [[ "$value" =~ ^([0-9]{1,5}|off)$ ]] && peer+="PersistentKeepalive = $value"$'\n' ;;
            *)  echo "Rejected WireGuard config: key '${key//[^A-Za-z]/}' is not allowed"; return 1 ;;
        esac || { echo "Rejected WireGuard config: bad value for ${key//[^A-Za-z]/}"; return 1; }
    done <<<"$config"
    _pair_end_peer || return 1

    $have_iface && grep -q '^PrivateKey = ' <<<"$iface" && grep -q '^Address = ' <<<"$iface" \
        || { echo "Rejected WireGuard config: [Interface] lacks PrivateKey or Address"; return 1; }
    (( n_peers >= 1 )) || { echo "Rejected WireGuard config: no [Peer]"; return 1; }
    printf '[Interface]\n%s%s' "$iface" "$peers"
}

# Root does the install (#48): /etc/wireguard is root-owned and the session
# user may only run wg-install-helper.sh, which sanitizes the config again
# with pair_sanitize_config() before writing it and starting wg-quick@wg0.
# The local check just gives a clear error without a sudo round trip.
pair_install_config() {
    local config="$1"
    config=$(pair_sanitize_config "$config") || { echo "$config"; return 1; }
    printf '%s\n' "$config" | sudo -n /opt/slimeos/wg-install-helper.sh
}

do_pair() {
    local mode="$1"
    local phase="entry"
    local host="" code=""

    while true; do
        if [[ "$phase" == "entry" ]]; then
            # PAIR_HINT (global, set by coordinator.sh's `connect` case just
            # before calling do_pair) carries a remembered Slime ID
            # bookmark's name/host through as context when reconnecting a
            # brain on a new device -- empty/unset for every other caller.
            emit_state pairEntry "$(jq -nc --arg mode "$mode" --arg hint "${PAIR_HINT:-}" \
                '{mode:$mode, skippable:($mode=="boot"), hint:(if $hint == "" then null else $hint end)}')"

            while true; do
                local line ev_type
                line=$(read_event) || return 0
                ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
                case "$ev_type" in
                    pairSubmit)
                        host=$(jq -r '.host // empty' <<<"$line")
                        code=$(jq -r '.code // empty' <<<"$line")
                        [[ -z "$host" || -z "$code" ]] && continue
                        phase="fetching"
                        continue 2
                        ;;
                    pairSkip)
                        [[ "$mode" == "boot" ]] && return 0
                        ;;
                    settingsTab)
                        # Only reachable in `settings` mode -- same reasoning
                        # as network-setup.sh's identical case: the frontend
                        # only shows a tab bar on this flow's top-level
                        # screen, which is this "entry" phase.
                        [[ "$mode" == "settings" ]] || continue
                        SETTINGS_NEXT_TAB=$(jq -r '.tab // empty' <<<"$line")
                        [[ -n "$SETTINGS_NEXT_TAB" ]] && return 0
                        ;;
                    back)
                        [[ "$mode" == "settings" ]] && return 0
                        ;;
                    forceBack) return 0 ;;
                    *)
                        try_handle_power_event "$ev_type" || :
                        try_handle_crash_report "$ev_type" "$line" || :
                        ;;
                esac
            done
        fi

        if [[ "$phase" == "fetching" ]]; then
            emit_state pairConnecting "$(jq -nc '{stage:"Fetching your Brain'"'"'s configuration..."}')"
            log "Pairing: fetching config from '$host'"

            # Same reasoning as connect.sh's `set +e` around xfreerdp3 and
            # network-setup.sh's around nmcli: a failed fetch/install is an
            # expected, handled outcome here, not a bug -- must not kill the
            # coordinator under set -e.
            set +e
            local config output exit_code
            config=$(pair_fetch_config "$host" "$code")
            exit_code=$?
            set -e

            if [[ $exit_code -eq 0 ]]; then
                set +e
                output=$(pair_install_config "$config" 2>&1)
                exit_code=$?
                set -e
            else
                output="$config"
            fi

            if [[ $exit_code -eq 0 ]]; then
                log "Pairing: tunnel installed and started"
                return 0
            fi

            log "Pairing failed (exit $exit_code): $output"
            local message
            if grep -qi 'invalid_or_expired\|HTTP 404' <<<"$output"; then
                message="That code is invalid or has expired."
            elif grep -qi 'rate_limited\|HTTP 429' <<<"$output"; then
                message="Too many attempts -- wait a moment and try again."
            else
                message="Couldn't reach that Brain."
            fi
            emit_state pairError "$(jq -nc --arg m "$message" --arg d "$output" --arg mode "$mode" \
                '{message:$m, detail:$d, mode:$mode}')"

            while true; do
                local line ev_type
                line=$(read_event) || return 0
                ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
                case "$ev_type" in
                    retry) phase="fetching"; continue 2 ;;
                    back) phase="entry"; continue 2 ;;
                    forceBack) return 0 ;;
                    *)
                        try_handle_power_event "$ev_type" || :
                        try_handle_crash_report "$ev_type" "$line" || :
                        ;;
                esac
            done
        fi
    done
}
