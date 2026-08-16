#!/usr/bin/env bash
# Slime OS — privileged update-apply helper (root)
#
# Invoked as `apply-update-helper.sh` with NO arguments, via `sudo -n` by
# membrane/session/update.sh's do_apply_update() (itself running
# unprivileged, as $SESSION_USER) once every staged file has been
# downloaded AND sha256-verified. /etc/sudoers.d/51-slimeos-update scopes
# the NOPASSWD grant to exactly this one script, no args -- same precedent
# as remote-support-toggle.sh.
#
# Deliberately does NO networking: every file it touches is read from a
# fixed, hardcoded staging path ($STAGING_DIR, below), already
# checksum-verified by the caller before this ever runs.
#
# Destination mapping is READ FROM STAGED DATA (dest-map.txt, part of the
# regular bundle, see membrane/update/dest-map.txt), not hardcoded --
# real incident, 2026-08-16 (v0.3.0): a hardcoded bash array here meant
# adding changelog.sh to the bundle required this script's own CODE to
# change, but this script is deliberately excluded from the auto-update
# manifest (same "v1 can't update itself" limitation as update.sh) -- so
# every already-provisioned device kept running its OLD, frozen array,
# silently never copying the new file into place even though it was
# correctly downloaded and verified into staging. coordinator.sh (which
# DOES update normally) shipped a `source changelog.sh` line pointing at a
# file that never arrived -- crash-looped every 2s on both the UTM VM and
# the AMD box. Moving the MAPPING (not the copy logic) into the same
# generic, checksummed staging pipeline every other file already goes
# through means a future new file only ever needs a new line in
# dest-map.txt, which flows to every device automatically. Checksum
# verification (already done by the caller) only ever covered file
# CONTENT, never where a file claims it should go -- now that the mapping
# itself is untrusted data, DEST_SAFE below is the thing that closes that
# gap: any `dest` containing `..` or starting with `/` is rejected outright,
# so a bad dest-map.txt can corrupt what gets installed but never *where*
# it lands (still confined under $INSTALL_DIR).
#
# File replacement uses `install` (unlink + recreate, i.e. rename
# semantics) rather than in-place truncation: both coordinator.sh
# (currently being interpreted by this script's own calling process) and
# the running slimeos-bridge binary keep executing their already-open
# inode after this runs, same guarantee any Unix package manager relies on.
#
# Applies via a full reboot rather than individually restarting
# slimeos-session.service/slimeos-bridge.service: this script runs as a
# descendant of slimeos-bridge.service's own cgroup (sudo'd from
# coordinator.sh, itself a child of the bridge), so restarting THAT service
# first would SIGTERM this script before it could also restart the session
# service -- KillMode=control-group is the systemd default and neither unit
# overrides it. Reboot sidesteps the ordering hazard entirely and reuses
# the already-proven boot/Plymouth path instead of inventing a live
# two-service bounce (cog/WPE only ever reads index.html once at process
# start regardless, so a session restart is unavoidable for UI changes no
# matter which path is taken).
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
[[ $# -eq 0 ]] || { echo "usage: $0 (no arguments)" >&2; exit 2; }

INSTALL_DIR="/opt/slimeos"
CONFIG_DIR="/etc/slimeos"
STAGING_DIR="$CONFIG_DIR/update-staging"
PREVIOUS_DIR="$CONFIG_DIR/update-previous"

[[ -d "$STAGING_DIR" ]] || { echo "no staged update found at $STAGING_DIR" >&2; exit 1; }
[[ -f "$STAGING_DIR/dest-map.txt" ]] || { echo "no staged dest-map.txt -- refusing to guess destinations" >&2; exit 1; }

# Build the name -> destination map from staged, already-verified data.
# Both fields are validated before either is trusted with anything -- name
# is used to locate the STAGED source file ($STAGING_DIR/$name), dest the
# INSTALLED destination ($INSTALL_DIR/$dest), so both need the same
# "must be a plain relative path, no traversal" guard, not just dest.
# Reject outright rather than merely warn: a rejected entry just means
# that one file doesn't get copied this round (caught immediately by a
# human watching this output), not a silent wrong-location read or write.
declare -A DEST_FOR=()
while IFS=: read -r name dest; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    if [[ -z "$dest" || "$name" == /* || "$name" == *..* || "$dest" == /* || "$dest" == *..* ]]; then
        echo "[apply-update] REJECTED unsafe dest-map.txt entry: $name -> $dest" >&2
        continue
    fi
    DEST_FOR["$name"]="$INSTALL_DIR/$dest"
done < "$STAGING_DIR/dest-map.txt"
[[ ${#DEST_FOR[@]} -gt 0 ]] || { echo "dest-map.txt parsed to zero safe entries" >&2; exit 1; }

echo "[apply-update] snapshotting current bundle to $PREVIOUS_DIR (rescue-mode restore target only, no automatic rollback)"
rm -rf "$PREVIOUS_DIR"
mkdir -p "$PREVIOUS_DIR"
for name in "${!DEST_FOR[@]}"; do
    src="${DEST_FOR[$name]}"
    [[ -f "$src" ]] && cp -p "$src" "$PREVIOUS_DIR/$name"
done

echo "[apply-update] applying staged files"
applied_any=false
for name in "${!DEST_FOR[@]}"; do
    staged="$STAGING_DIR/$name"
    [[ -f "$staged" ]] || continue
    dest="${DEST_FOR[$name]}"
    mkdir -p "$(dirname "$dest")"
    case "$name" in
        *.sh|slimeos-bridge) mode=0755 ;;
        *) mode=0644 ;;
    esac
    install -m "$mode" -o root -g root "$staged" "$dest"
    applied_any=true
done

if ! $applied_any; then
    echo "[apply-update] nothing staged, aborting without touching version or rebooting" >&2
    exit 1
fi

# Purely informational (see changelog.sh's Settings tab) -- doesn't gate
# anything the way version below does, but written here, before version,
# so version stays the true "did this fully land" marker either way.
if [[ -f "$STAGING_DIR/changelog" ]]; then
    install -m 0644 -o root -g root "$STAGING_DIR/changelog" "$CONFIG_DIR/changelog"
fi
if [[ -f "$STAGING_DIR/changelog-released-at" ]]; then
    install -m 0644 -o root -g root "$STAGING_DIR/changelog-released-at" "$CONFIG_DIR/changelog-released-at"
fi

# Written last, only after every file above has landed -- a helper that
# dies partway through the loop above never advances this, so the next
# _updateTick's do_update_check() sees the still-old version and retries
# the whole cycle from scratch (idempotent, self-healing).
if [[ -f "$STAGING_DIR/version" ]]; then
    install -m 0644 -o root -g root "$STAGING_DIR/version" "$CONFIG_DIR/version"
fi

# Clear CONTENTS only, never rm -rf the directory itself: it's slime:slime-
# owned (set once by install.sh), and this helper running as root could
# recreate the directory but never restore that ownership correctly for the
# NEXT unprivileged do_apply_update() run -- same reasoning as update.sh's
# own staging-dir cleanup.
rm -rf "${STAGING_DIR:?}"/*

echo "[apply-update] rebooting to complete the update"
systemctl reboot
