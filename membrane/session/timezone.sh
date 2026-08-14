#!/usr/bin/env bash
# Slime OS — Timezone settings tab
#
# `source`d by membrane/session/coordinator.sh, same shape as support.sh's
# do_support(): relies on coordinator.sh's own log()/emit_state()/
# read_event() helpers. `mode` is always "settings" -- there is no boot-mode
# variant of this screen, same as support.sh.
#
# `timedatectl set-timezone` is called directly as the unprivileged session
# user, not through a sudo-wrapped root helper (contrast support.sh's
# remote-support-toggle.sh) -- it's a plain D-Bus action
# (org.freedesktop.timedate1.set-timezone) that install.sh's polkit rule
# authorizes for $SESSION_USER directly, the same mechanism already used for
# NetworkManager/systemd unit management/udisks2 elsewhere in this file set.
#
# The full IANA zone list is read once (it can't change mid-session) rather
# than re-shelling out to `timedatectl list-timezones` on every loop turn
# the way `enabled` is re-derived live in support.sh -- there's no live
# external state here to go stale, only the current timezone itself, which
# IS re-read every turn so a change made outside this UI (or a failed set
# that partially applied) never shows a wrong value.

TIMEZONE_LIST=""
timezone_list() {
    [[ -n "$TIMEZONE_LIST" ]] || TIMEZONE_LIST=$(timedatectl list-timezones 2>/dev/null)
    printf '%s' "$TIMEZONE_LIST"
}

current_timezone() {
    timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC"
}

do_timezone() {
    local mode="$1"
    local error=""

    while true; do
        local current; current=$(current_timezone)
        emit_state timezoneSettings "$(jq -nc --arg mode "$mode" --arg current "$current" \
            --arg error "$error" --arg list "$(timezone_list)" \
            '{mode:$mode, current:$current, timezones:($list | split("\n")), error:(if $error == "" then null else $error end)}')"
        error=""

        local line ev_type
        line=$(read_event) || return 0
        ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
        case "$ev_type" in
            timezoneSet)
                local want output exit_code
                want=$(jq -r '.timezone // empty' <<<"$line")
                if [[ -z "$want" ]] || ! grep -qxF "$want" <<<"$(timezone_list)"; then
                    log "Timezone set rejected: '$want' not a known zone"
                    error="Not a recognized timezone."
                    continue
                fi

                log "Setting timezone to $want"
                set +e
                output=$(timedatectl set-timezone "$want" 2>&1)
                exit_code=$?
                set -e

                if [[ $exit_code -ne 0 ]]; then
                    log "timedatectl set-timezone failed (exit $exit_code): $output"
                    error="Couldn't change the timezone right now."
                else
                    # send_status() (coordinator.sh) is normally only sent
                    # on specific transitions (connect/resync, leaving the
                    # Settings panel, etc) -- the status strip's clock
                    # otherwise just free-runs forward locally from
                    # whichever value it last got (see index.html's
                    # setStatus()). Without this, a changed timezone
                    # wouldn't visibly affect the clock until the next one
                    # of those transitions happened to fire, which reads
                    # as "the clock didn't update" even though the
                    # timezone itself did change immediately.
                    send_status
                fi
                ;;
            settingsTab)
                [[ "$mode" == "settings" ]] || continue
                SETTINGS_NEXT_TAB=$(jq -r '.tab // empty' <<<"$line")
                [[ -n "$SETTINGS_NEXT_TAB" ]] && return 0
                ;;
            back) return 0 ;;
            forceBack) return 0 ;;
            *)
                try_handle_power_event "$ev_type" || :
                try_handle_crash_report "$ev_type" "$line" || :
                ;;
        esac
    done
}
