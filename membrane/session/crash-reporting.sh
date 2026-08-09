#!/usr/bin/env bash
# Slime OS — Privacy settings tab + anonymous error reporting
#
# `source`d by membrane/session/coordinator.sh, same shape as pair.sh's
# do_pair() and support.sh's do_support(): relies on coordinator.sh's own
# log()/emit_state()/read_event() helpers.
#
# Two responsibilities live here:
#   1. do_crash_reporting(mode) -- the Settings panel's Privacy tab: a single
#      on/off toggle, no root helper needed (this touches no privileged
#      system state, unlike Remote Support's SSH/firewall changes).
#   2. try_handle_crash_report() -- a try_handle_power_event()-style
#      cross-cutting helper. A JS error can happen on ANY screen, but only
#      one do_*() owns read_event() at a time -- so every do_*'s catch-all
#      (see support.sh/pair.sh/network-setup.sh/connect.sh/coordinator.sh's
#      own outer dispatch) calls this alongside try_handle_power_event,
#      exactly the same way power events are recognized no matter which
#      screen is showing.
#
# Consent itself is a separate, simpler flow than this file's toggle:
# coordinator.sh's boot sequence shows a one-shot 'showCrashConsent' popup
# the first time a device ever reaches the idle screen with no answer on
# file yet (see coordinator.sh's consent_checked gate), and handles the
# 'crashConsent' reply directly in its own outer dispatch -- a one-shot
# yes/no has nothing left to render, so it doesn't need a loop-owning
# do_*() function of its own the way a real screen does.
#
# Anonymity is enforced by minimal collection, not by scrubbing after the
# fact: index.html's crash-report handler only ever sends {message, stack,
# state} -- never brain hostnames/IPs, WiFi SSIDs, WireGuard keys, or
# anything typed into a form. scrub_pii() below is belt-and-braces on top of
# that, in case an error message happens to interpolate something
# unexpected (e.g. a failed fetch's URL). The backend re-runs an equivalent
# scrub server-side too, so a compromised/modified device can't skip it.

CONSENT_FILE="$CONFIG_DIR/crash-reporting-consent"
REPORT_ENDPOINT="https://www.slimeos.com/api/report-error"
HW_PROFILE_MARKER="$CONFIG_DIR/hw-profile-applied"

crash_reporting_enabled() {
    [[ -f "$CONSENT_FILE" ]] && [[ "$(cat "$CONSENT_FILE")" == "granted" ]]
}

do_crash_reporting() {
    local mode="$1"

    while true; do
        local enabled="false"
        crash_reporting_enabled && enabled="true"

        emit_state crashReportSettings "$(jq -nc --arg mode "$mode" --argjson enabled "$enabled" \
            '{mode:$mode, enabled:$enabled}')"

        local line ev_type
        line=$(read_event) || return 0
        ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
        case "$ev_type" in
            crashReportToggle)
                local want
                want=$(jq -r '.enabled // false' <<<"$line")
                # See coordinator.sh's crashConsent case for why this is
                # guarded: a failed write here must never crash the whole
                # coordinator under set -e.
                if [[ "$want" == "true" ]]; then
                    echo "granted" > "$CONSENT_FILE" || log "Failed to write crash-reporting-consent (granted)"
                else
                    echo "declined" > "$CONSENT_FILE" || log "Failed to write crash-reporting-consent (declined)"
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

scrub_pii() {
    sed -E \
        -e 's/[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[ip]/g' \
        -e 's/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/[mac]/g' \
        -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/[email]/g' \
        -e 's#/home/[^/[:space:]]+#/home/[user]#g'
}

# Called from every do_*'s catch-all so a 'crashReport' event is recognized
# regardless of which screen currently owns the event loop -- same pattern
# as try_handle_power_event(). Returns 0 (handled, or deliberately a no-op
# because reporting isn't enabled) for a crashReport event, 1 for anything
# else, so callers can `|| :` it exactly like try_handle_power_event.
try_handle_crash_report() {
    [[ "$1" == "crashReport" ]] || return 1
    local line="$2"

    crash_reporting_enabled || return 0

    local message stack source_state hw_profile
    message=$(jq -r '.message // "Unknown error"' <<<"$line" | scrub_pii | cut -c1-500)
    stack=$(jq -r '.stack // ""' <<<"$line" | scrub_pii | cut -c1-4000)
    source_state=$(jq -r '.state // ""' <<<"$line")
    hw_profile="unknown"
    [[ -f "$HW_PROFILE_MARKER" ]] && hw_profile=$(grep '^profile=' "$HW_PROFILE_MARKER" | cut -d= -f2)

    local payload
    payload=$(jq -nc --arg message "$message" --arg stack "$stack" --arg source "$source_state" \
        --arg version "$MEMBRANE_VERSION" --arg profile "$hw_profile" \
        '{message:$message, stack:$stack, source:$source, slimeos_version:$version, hardware_profile:$profile}')

    # Backgrounded and disowned so a slow/dead network never blocks whatever
    # screen is currently showing -- unlike pair.sh's curl, nothing here
    # needs to wait on the result.
    ( curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
        -d "$payload" "$REPORT_ENDPOINT" >/dev/null 2>&1 \
        || log "Crash report failed to send (non-fatal)" ) &
    disown
    return 0
}
