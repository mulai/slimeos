#!/usr/bin/env bash
# Slime OS — Remote Support settings tab
#
# `source`d by membrane/session/coordinator.sh, same shape as pair.sh's
# do_pair() and network-setup.sh's do_network_setup(): relies on
# coordinator.sh's own log()/emit_state()/read_event() helpers.
#
# Lets a user opt in to SSH access for the Slime OS support team, from the
# Settings panel's Support tab (see coordinator.sh's openSettings handling
# for how a user reaches this -- there is no boot-mode/auto-shown variant of
# this screen, unlike network-setup.sh/pair.sh; `mode` is always "settings").
#
# The actual privileged work -- starting ssh.service, opening the firewall
# to the WireGuard subnet only, rotating the connect-with password -- lives
# in the root-owned remote-support-toggle.sh, invoked here via a NOPASSWD
# sudo rule scoped to that one script (see install.sh's sudoers drop-in);
# this function itself runs unprivileged, same as every other do_*() in this
# file set.
#
# `enabled` is never trusted as a local variable across iterations -- it's
# re-derived from the live state (support_is_active) on every loop turn, so a
# stale coordinator restart mid-session can't show a wrong toggle position.
#
# One phase only (no "connecting"/"error" sub-screens): the toggle is a
# single synchronous root helper call, no multi-step form.

REMOTE_SUPPORT_TOGGLE="$INSTALL_DIR/remote-support-toggle.sh"

# Written by install.sh at install time (see its "On-device version record"
# step) and, from then on, kept current by the in-kiosk update mechanism
# (membrane/session/update.sh) whenever an update is applied. Purely
# read-only display here -- this tab never writes to it. Read once here (not
# per-loop-turn like `enabled` below): unlike ssh.service's live state, it
# can't change during a session (an applied update reboots the device).
MEMBRANE_VERSION="unknown"
[[ -f "$CONFIG_DIR/version" ]] && MEMBRANE_VERSION=$(cat "$CONFIG_DIR/version")

# The last successful `on` toggle's connection info (host/port/user/password),
# or "null". Deliberately module-level rather than local to do_support(): the
# password can't be recovered after the fact (chpasswd only keeps a hash), so a
# local copy meant the details vanished as soon as the user switched tabs or
# closed Settings, while Remote Support stayed on. Held in the long-running
# coordinator's memory only, never written to disk -- a coordinator restart
# still loses it (the screen then explains how to get a fresh password), and
# every boot forces Remote Support off anyway (install.sh's boot-time unit).
SUPPORT_CONNECTION="null"

# Both: ssh.service alone isn't enough, since a device set up from Rescue
# mode runs sshd on every boot without Remote Support being on. The flag is
# written by remote-support-toggle.sh `on` and lives in /run, so a reboot
# clears it.
support_is_active() {
    [[ -f /run/slimeos-remote-support-on ]] && systemctl is-active --quiet ssh.service
}

do_support() {
    local mode="$1"
    local error=""

    while true; do
        local enabled="false"
        support_is_active && enabled="true"
        # A prior toggle's own connection info stays on screen until the
        # next state change (mirrors the wifi/pair screens' pattern of only
        # replacing what's shown in response to a new event) -- but if
        # ssh.service somehow isn't actually running, showing stale
        # "share this" details would be actively misleading, so drop them.
        [[ "$enabled" == "true" ]] || SUPPORT_CONNECTION="null"

        emit_state supportSettings "$(jq -nc --arg mode "$mode" --argjson enabled "$enabled" \
            --argjson connection "$SUPPORT_CONNECTION" --arg error "$error" --arg version "$MEMBRANE_VERSION" \
            '{mode:$mode, enabled:$enabled, connection:$connection, error:(if $error == "" then null else $error end), version:$version}')"
        error=""

        local line ev_type
        line=$(read_event) || return 0
        ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
        case "$ev_type" in
            supportToggle)
                local want action output exit_code
                want=$(jq -r '.enabled // false' <<<"$line")
                action=on; [[ "$want" == "true" ]] || action=off

                log "Remote support: turning $action"
                set +e
                output=$(sudo -n "$REMOTE_SUPPORT_TOGGLE" "$action" 2>&1)
                exit_code=$?
                set -e

                if [[ $exit_code -ne 0 ]]; then
                    log "Remote support toggle ($action) failed (exit $exit_code): $output"
                    error="Couldn't change Remote Support right now."
                    SUPPORT_CONNECTION="null"
                elif [[ "$action" == "on" ]]; then
                    SUPPORT_CONNECTION="$output"
                else
                    SUPPORT_CONNECTION="null"
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
