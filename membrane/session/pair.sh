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
# "settings" (opened deliberately via the pairing icon -- Back button, no
# Skip; lets a device add/replace its tunnel later).
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

pair_install_config() {
    local config="$1" tmp
    tmp=$(mktemp /etc/wireguard/wg0.conf.XXXXXX)
    printf '%s\n' "$config" > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" /etc/wireguard/wg0.conf
    # Two separate polkit-authorized systemd actions under the hood (start +
    # enable) -- see install.sh's 52-slimeos-wireguard.rules comment for why
    # both are needed, not just one.
    systemctl enable --now wg-quick@wg0
}

do_pair() {
    local mode="$1"
    local phase="entry"
    local host="" code=""

    while true; do
        if [[ "$phase" == "entry" ]]; then
            emit_state pairEntry "$(jq -nc --arg mode "$mode" '{mode:$mode, skippable:($mode=="boot")}')"

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
                    back)
                        [[ "$mode" == "settings" ]] && return 0
                        ;;
                    *) : ;;
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
                    *) : ;;
                esac
            done
        fi
    done
}
