#!/usr/bin/env bash
# Slime OS — Changelog settings tab
#
# `source`d by membrane/session/coordinator.sh, same shape as timezone.sh's
# do_timezone()/support.sh's do_support(): relies on coordinator.sh's own
# log()/emit_state()/read_event() helpers. `mode` is always "settings" --
# there is no boot-mode variant of this screen.
#
# Shows what changed in the version CURRENTLY INSTALLED, not whatever's
# newest on `main` -- $CONFIG_DIR/changelog is written once by install.sh
# (seeded from manifest.json's own `changelog` field at install time) and
# advanced by apply-update-helper.sh alongside $CONFIG_DIR/version whenever
# a real update applies (see update.sh's do_apply_update() and the helper's
# own header) -- same "only ever advanced as the last step of a fully
# verified update" guarantee $CONFIG_DIR/version already has. This tab is
# purely a read-only display of those local files; it never fetches
# anything itself, so it works identically online or offline.
#
# $CONFIG_DIR/changelog-released-at (manifest.json's `released_at`, same
# seed/advance lifecycle as changelog above) is an ISO8601 timestamp of
# when the installed release was published -- shown as a relative string
# ("3 hours ago") via relative_time(), already defined in coordinator.sh
# and directly callable here since this file is sourced into that same
# process (same reuse coordinator.sh's own brain-picker cards already make
# of that function for `lastConnected`). Absent/empty (a device that
# predates this field, or a manifest that never set it) just omits the
# line client-side rather than showing a confusing "never".

do_changelog() {
    local mode="$1"
    local version changelog released_at released_relative

    while true; do
        version=$(cat "$CONFIG_DIR/version" 2>/dev/null || echo "unknown")
        changelog=$(cat "$CONFIG_DIR/changelog" 2>/dev/null || true)
        [[ -n "$changelog" ]] || changelog="No changelog recorded for this install."
        released_at=$(cat "$CONFIG_DIR/changelog-released-at" 2>/dev/null || true)
        released_relative=""
        [[ -n "$released_at" ]] && released_relative=$(relative_time "$released_at")
        emit_state changelogSettings "$(jq -nc --arg mode "$mode" --arg version "$version" --arg changelog "$changelog" \
            --arg releasedAt "$released_at" --arg releasedRelative "$released_relative" \
            '{mode:$mode, version:$version, changelog:$changelog,
              releasedAt:(if $releasedAt == "" then null else $releasedAt end),
              releasedRelative:(if $releasedRelative == "" then null else $releasedRelative end)}')"

        local line ev_type
        line=$(read_event) || return 0
        ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
        case "$ev_type" in
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
