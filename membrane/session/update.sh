#!/usr/bin/env bash
# Slime OS — In-kiosk update check + apply
#
# `source`d by membrane/session/coordinator.sh. Unlike timezone.sh/support.sh,
# neither function here owns the event loop -- both run to completion and
# return immediately, driven by two dispatch-loop case arms:
#   {"type":"_updateTick"}  bridge-synthesized (see main.go's update ticker) -> do_update_check
#   {"type":"applyUpdate"}  see index.html's 'slime:apply-update'            -> do_apply_update
#
# Since 0.3.45 this file and apply-update-helper.sh ship like any other
# bundle file (manifest + dest-map.txt): the helper already on a device
# installs the next one. Only the /etc/sudoers.d/51-slimeos-update grant is
# still install.sh-only.
#
# The manifest versions the WHOLE bundle as ONE number (Tommy's explicit
# design call). hardware-profiles/*.sh +
# detect.sh ARE ordinary bundle entries (since v0.3.14): apply-update-helper.sh
# re-runs detect.sh itself, right after staging, whenever one of those files
# changed -- see its own comment near hw_profile_changed.

REPO_BASE="https://raw.githubusercontent.com/mulai/slimeos/main"
MANIFEST_URL="$REPO_BASE/membrane/update/manifest.json"

emit_update_failed() { jq -nc --arg m "$1" '{type:"updateFailed", data:{message:$m}}'; }

# Simple X.Y.Z numeric compare -- SLIMEOS_VERSION has never been anything
# else. Returns 0 (true) if $1 > $2. Missing components default to 0, so
# "0.2" > "0.1.9" behaves the same as "0.2.0" would.
version_gt() {
    local a="$1" b="$2"
    local -a av bv
    IFS='.' read -r -a av <<<"$a"
    IFS='.' read -r -a bv <<<"$b"
    local i an bn
    for i in 0 1 2; do
        an="${av[$i]:-0}"; bn="${bv[$i]:-0}"
        (( 10#$an > 10#$bn )) && return 0
        (( 10#$an < 10#$bn )) && return 1
    done
    return 1
}

# Sets the module-level update_available_version (declared in coordinator.sh)
# and always calls send_status() so the idle picker's status strip icon
# reflects the current answer immediately, same reasoning as timezone.sh's
# explicit send_status() call after a successful change -- otherwise it'd
# only surface on the next incidental transition.
do_update_check() {
    local manifest remote_version local_version
    manifest=$(curl -fsS -m 10 "$MANIFEST_URL" 2>/dev/null) || {
        log "Update check: manifest fetch failed (non-fatal)"
        # A transient network failure must NOT wipe a previously-found
        # update -- leave update_available_* as they were, just flag that
        # this particular check didn't complete (do_changelog reads it).
        update_check_failed="1"
        return 0
    }
    remote_version=$(jq -r '.version // empty' <<<"$manifest" 2>/dev/null || echo "")
    [[ -n "$remote_version" ]] || {
        log "Update check: manifest missing/unreadable version field"
        update_check_failed="1"
        return 0
    }
    update_check_failed=""
    local_version=$(cat "$CONFIG_DIR/version" 2>/dev/null || echo "0.0.0")

    if version_gt "$remote_version" "$local_version"; then
        [[ "$remote_version" != "$update_available_version" ]] && log "Update available: $local_version -> $remote_version"
        update_available_version="$remote_version"
        # Stashed for the Settings > Changelog "what's new" preview only --
        # the status strip icon needs just the version. Manifest field is
        # already in hand, so this costs nothing extra. Sliced to just
        # $remote_version's own entry (same treatment/reasoning as
        # changelog.sh's do_changelog() — see changelog_block_for_version's
        # header comment): the manifest's `changelog` field is the FULL
        # history, and github.com/mulai/slimeos#16 asked for just the one
        # version's notes here, not the whole blob.
        local full_changelog version_block
        full_changelog=$(jq -r '.changelog // ""' <<<"$manifest" 2>/dev/null || echo "")
        version_block=$(changelog_block_for_version "$full_changelog" "$remote_version")
        update_available_changelog="${version_block:-$full_changelog}"
        update_available_released_at=$(jq -r '.released_at // ""' <<<"$manifest" 2>/dev/null || echo "")
    else
        update_available_version=""
        update_available_changelog=""
        update_available_released_at=""
    fi
    send_status
}

# Re-fetches the manifest fresh (a TOCTOU guard against `main` moving since
# the last do_update_check) rather than trusting update_available_version's
# cached value, then hands off to the privileged root helper, which
# downloads and sha256-verifies every file itself into a root-only
# directory and installs them (#39: this side used to stage and verify, and
# the helper trusted a directory this user could write). Any failure leaves
# the current install untouched and reports 'updateFailed'.
do_apply_update() {
    local target_version="$update_available_version"
    if [[ -z "$target_version" ]]; then
        log "Apply update requested but no update is currently known -- ignoring"
        return 0
    fi

    log "Applying update to $target_version"

    local manifest remote_version
    manifest=$(curl -fsS -m 10 "$MANIFEST_URL" 2>/dev/null) || {
        log "Apply update: manifest fetch failed"
        emit_update_failed "Couldn't reach the update server."
        return 0
    }
    remote_version=$(jq -r '.version // empty' <<<"$manifest" 2>/dev/null || echo "")

    if [[ -z "$remote_version" || "$remote_version" != "$target_version" ]]; then
        log "Apply update: manifest version drifted ($target_version -> ${remote_version:-unknown}) -- re-surfacing instead of applying blind"
        update_available_version="$remote_version"
        send_status
        emit_update_failed "The update changed while you were looking -- check again."
        return 0
    fi

    # The helper's output goes to the log, not to stdout (that's the UI's
    # event stream). Its "verified" line means every file checked out and
    # it's installing, then it reboots -- that's when the overlay shows.
    log "Handing off to the privileged apply helper (downloads, verifies, installs, reboots)"
    local rc
    set +e
    sudo -n /opt/slimeos/apply-update-helper.sh 2>&1 | while IFS= read -r line; do
        log "$line"
        [[ "$line" == "[apply-update] verified"* ]] && jq -nc '{type:"updateApplying"}'
    done
    rc=${PIPESTATUS[0]}
    set -e

    case "$rc" in
        0)
            # The helper has asked for the reboot, but `systemctl reboot`
            # returns before the system goes down and shutdown can take a
            # minute. Don't go back to the event loop meanwhile: the next
            # screen it draws covers the "Updating" overlay (seen on the UTM
            # VM 2026-09-26: Changelog came back still offering the version
            # that had just been installed).
            log "Apply update: installed, waiting for the reboot"
            sleep 180
            log "Apply update: still running 3 min after the reboot request"
            emit_update_failed "The update is installed. Restart the Membrane to finish."
            ;;
        3)
            log "Apply update: helper couldn't download/verify -- current install untouched (will retry on the next check)"
            emit_update_failed "Couldn't verify the update. It will be offered again later."
            ;;
        4)
            log "Apply update: helper found nothing newer to install"
            update_available_version=""
            send_status
            emit_update_failed "The update changed while you were looking -- check again."
            ;;
        *)
            log "ERROR: apply-update-helper.sh failed (exit $rc) or the sudoers grant is missing -- this device likely needs a reinstall before it can auto-update"
            emit_update_failed "This device needs a reinstall before it can auto-update."
            ;;
    esac
}
