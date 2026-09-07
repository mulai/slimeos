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
# verified update" guarantee $CONFIG_DIR/version already has. The installed-
# version block is purely a read-only display of those local files; it never
# fetches anything itself, so it works identically online or offline.
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
#
# Software updates block (the "check now / update now here" ask from issue
# #6): this tab ALSO drives the update flow directly, so a user doesn't
# have to wait for the passive status-strip icon on the idle picker.
#
# The richer display (pending release's own changelog text, and telling
# "couldn't reach the server" apart from "you're up to date") depends on
# update.sh populating update_available_changelog / update_check_failed.
# update.sh is deliberately NOT in the update manifest (see its own header
# -- the self-update bootstrap problem), so a device that auto-updated
# into this release still carries the pre-#6 update.sh. That degrades
# cleanly: update_available_version is still set correctly, so the
# "Update available" card + "Update now" still work (just with no notes
# preview), and a failed check reads as "up to date" rather than erroring.
# A reinstall picks up the full behaviour.
#   {"type":"checkUpdate"}  -> calls do_update_check() (update.sh): re-fetches
#     the manifest off `main`, refreshes update_available_version / _changelog
#     / _released_at and update_check_failed, and re-syncs the status strip.
#   {"type":"applyUpdate"}  -> calls do_apply_update() (update.sh) directly.
#     The outer dispatch loop's own `applyUpdate` case is normally the ONLY
#     place that runs (see index.html's 'slime:apply-update' comment on why
#     the picker icon is gated to the two idle states); handling it here too
#     is safe because do_apply_update() is self-contained -- it either
#     reboots the device (terminal) or emits 'updateFailed' and returns,
#     after which this loop just re-renders.

do_changelog() {
    local mode="$1"
    local version changelog released_at released_relative
    # "" until the user runs a check this session; "checking" while
    # do_update_check() is mid-fetch (emitted optimistically, same pattern
    # as feedback.sh's status:"sending"); "checked" once at least one
    # completed -- the frontend then reads update_available_version /
    # update_check_failed to decide what to show.
    local check_state=""

    while true; do
        version=$(cat "$CONFIG_DIR/version" 2>/dev/null || echo "unknown")
        changelog=$(cat "$CONFIG_DIR/changelog" 2>/dev/null || true)
        [[ -n "$changelog" ]] || changelog="No changelog recorded for this install."
        released_at=$(cat "$CONFIG_DIR/changelog-released-at" 2>/dev/null || true)
        released_relative=""
        [[ -n "$released_at" ]] && released_relative=$(relative_time "$released_at")

        # `:-` guards: these three are coordinator.sh module vars that
        # always exist in a matched bundle -- the fallback only matters
        # under a partial hot-patch (new changelog.sh, older coordinator.sh)
        # and just yields the graceful-degradation path described above.
        local update_released_relative=""
        [[ -n "${update_available_released_at:-}" ]] && update_released_relative=$(relative_time "$update_available_released_at")

        emit_state changelogSettings "$(jq -nc --arg mode "$mode" --arg version "$version" --arg changelog "$changelog" \
            --arg releasedAt "$released_at" --arg releasedRelative "$released_relative" \
            --arg checkState "$check_state" \
            --arg updateAvailable "${update_available_version:-}" \
            --arg updateChangelog "${update_available_changelog:-}" \
            --arg updateReleasedRelative "$update_released_relative" \
            --arg checkFailed "${update_check_failed:-}" \
            '{mode:$mode, version:$version, changelog:$changelog,
              releasedAt:(if $releasedAt == "" then null else $releasedAt end),
              releasedRelative:(if $releasedRelative == "" then null else $releasedRelative end),
              checkState:$checkState,
              checkFailed:($checkFailed == "1"),
              updateAvailable:(if $updateAvailable == "" then null else $updateAvailable end),
              updateChangelog:(if $updateChangelog == "" then null else $updateChangelog end),
              updateReleasedRelative:(if $updateReleasedRelative == "" then null else $updateReleasedRelative end)}')"

        local line ev_type
        line=$(read_event) || return 0
        ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
        case "$ev_type" in
            checkUpdate)
                # Optimistic "Checking…" so the (single-threaded) coordinator
                # being blocked in the curl below still shows progress --
                # same trick feedback.sh uses for its "sending" state.
                check_state="checking"
                emit_state changelogSettings "$(jq -nc --arg mode "$mode" --arg version "$version" --arg changelog "$changelog" \
                    --arg releasedAt "$released_at" --arg releasedRelative "$released_relative" \
                    '{mode:$mode, version:$version, changelog:$changelog,
                      releasedAt:(if $releasedAt == "" then null else $releasedAt end),
                      releasedRelative:(if $releasedRelative == "" then null else $releasedRelative end),
                      checkState:"checking", checkFailed:false,
                      updateAvailable:null, updateChangelog:null, updateReleasedRelative:null}')"
                do_update_check
                check_state="checked"
                ;;
            applyUpdate)
                do_apply_update
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
