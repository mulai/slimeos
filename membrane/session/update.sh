#!/usr/bin/env bash
# Slime OS — In-kiosk update check + apply
#
# `source`d by membrane/session/coordinator.sh. Unlike timezone.sh/support.sh,
# neither function here owns the event loop -- both run to completion and
# return immediately, driven by two dispatch-loop case arms:
#   {"type":"_updateTick"}  bridge-synthesized (see main.go's update ticker) -> do_update_check
#   {"type":"applyUpdate"}  see index.html's 'slime:apply-update'            -> do_apply_update
#
# v1 explicitly cannot update ITSELF: this file, apply-update-helper.sh, the
# /etc/sudoers.d/51-slimeos-update grant, and the update-staging/
# update-previous directories are all install.sh-provisioned artifacts,
# absent on any device that hasn't been (re)installed since this feature
# shipped. A device already in the field before this ships can only pick it
# up via a manual reinstall -- there's no "next tick retries" story for that
# gap, unlike a bad checksum below, which genuinely is self-healing.
#
# The manifest versions the WHOLE bundle as ONE number (Tommy's explicit
# design call) -- deliberately excludes hardware-profiles/*.sh (a profile
# change also needs hardware-profiles/detect.sh re-run to take effect, out
# of scope for v1) and this file + apply-update-helper.sh themselves (the
# bootstrap problem above).

REPO_BASE="https://raw.githubusercontent.com/mulai/slimeos/main"
MANIFEST_URL="$REPO_BASE/membrane/update/manifest.json"
UPDATE_STAGING_DIR="$CONFIG_DIR/update-staging"

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
    manifest=$(curl -fsS -m 10 "$MANIFEST_URL" 2>/dev/null) || { log "Update check: manifest fetch failed (non-fatal)"; return 0; }
    remote_version=$(jq -r '.version // empty' <<<"$manifest" 2>/dev/null || echo "")
    [[ -n "$remote_version" ]] || { log "Update check: manifest missing/unreadable version field"; return 0; }
    local_version=$(cat "$CONFIG_DIR/version" 2>/dev/null || echo "0.0.0")

    if version_gt "$remote_version" "$local_version"; then
        [[ "$remote_version" != "$update_available_version" ]] && log "Update available: $local_version -> $remote_version"
        update_available_version="$remote_version"
    else
        update_available_version=""
    fi
    send_status
}

# Re-fetches the manifest fresh (a TOCTOU guard against `main` moving since
# the last do_update_check) rather than trusting update_available_version's
# cached value, downloads + sha256-verifies every listed file plus the
# arch-matched bridge binary into $UPDATE_STAGING_DIR, then hands off to the
# privileged root helper. Any failure aborts cleanly, leaves the current
# install untouched, and reports 'updateFailed' -- the current version
# marker is only ever advanced by the helper itself, as its last step,
# after every file lands, so a partial run here never corrupts anything.
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

    rm -rf "$UPDATE_STAGING_DIR"
    mkdir -p "$UPDATE_STAGING_DIR"
    chmod 700 "$UPDATE_STAGING_DIR"
    # Read by apply-update-helper.sh as the trusted new version marker --
    # already confirmed equal to $remote_version above, and this file is
    # never executed, only cat'd into $CONFIG_DIR/version, so no checksum
    # is needed for it the way every other staged file gets one.
    echo "$remote_version" > "$UPDATE_STAGING_DIR/version"

    local staged_ok=true src sha256 base dest
    while IFS=$'\t' read -r src sha256; do
        [[ -z "$src" ]] && continue
        base=$(basename "$src")
        dest="$UPDATE_STAGING_DIR/$base"
        if ! curl -fsS -m 30 "$REPO_BASE/membrane/$src" -o "$dest" 2>/dev/null; then
            log "Apply update: download failed for $src"
            staged_ok=false
            break
        fi
        if ! echo "$sha256  $dest" | sha256sum -c - >/dev/null 2>&1; then
            log "Apply update: checksum mismatch for $src"
            staged_ok=false
            break
        fi
    done < <(jq -r '.files[] | [.src, .sha256] | @tsv' <<<"$manifest" 2>/dev/null)

    if $staged_ok; then
        local bridge_arch bridge_src bridge_sha bridge_dest
        bridge_arch=$(dpkg --print-architecture)
        bridge_src=$(jq -r --arg a "$bridge_arch" '.bridge[$a].src // empty' <<<"$manifest" 2>/dev/null || echo "")
        bridge_sha=$(jq -r --arg a "$bridge_arch" '.bridge[$a].sha256 // empty' <<<"$manifest" 2>/dev/null || echo "")
        bridge_dest="$UPDATE_STAGING_DIR/slimeos-bridge"
        if [[ -z "$bridge_src" ]]; then
            log "Apply update: no bridge binary listed for arch $bridge_arch"
            staged_ok=false
        elif ! curl -fsS -m 30 "$REPO_BASE/membrane/$bridge_src" -o "$bridge_dest" 2>/dev/null; then
            log "Apply update: bridge binary download failed"
            staged_ok=false
        elif ! echo "$bridge_sha  $bridge_dest" | sha256sum -c - >/dev/null 2>&1; then
            log "Apply update: bridge binary checksum mismatch"
            staged_ok=false
        fi
    fi

    if ! $staged_ok; then
        log "Apply update: aborting, leaving the current install untouched (will retry on the next check)"
        rm -rf "$UPDATE_STAGING_DIR"
        emit_update_failed "Couldn't verify the update. It will be offered again later."
        return 0
    fi

    log "Update staged and verified -- handing off to the privileged apply helper (this reboots the device)"
    jq -nc '{type:"updateApplying"}'
    if ! sudo -n /opt/slimeos/apply-update-helper.sh; then
        log "ERROR: apply-update-helper.sh failed or the sudoers grant is missing -- this device likely needs a reinstall before it can auto-update"
        emit_update_failed "This device needs a reinstall before it can auto-update."
    fi
}
