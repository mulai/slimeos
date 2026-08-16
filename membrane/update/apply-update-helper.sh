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
# Deliberately does NO networking and NO parsing of untrusted data: every
# file it touches is read from a fixed, hardcoded staging path
# ($STAGING_DIR, below) by a fixed, hardcoded filename -> destination
# mapping ($DEST_FOR, below) -- never a `dest` field out of manifest.json.
# Checksum verification (already done by the caller) only covers file
# CONTENT, not where a file claims it should go -- keeping the destination
# mapping compiled into THIS script, not data-driven, is what closes that
# gap: a bad/malicious manifest.json can corrupt what gets installed, but
# never where it lands.
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

# Fixed filename -> absolute destination path. Deliberately NOT derived from
# manifest.json or anything else staged alongside the files -- see header.
declare -A DEST_FOR=(
    [coordinator.sh]="$INSTALL_DIR/coordinator.sh"
    [connect.sh]="$INSTALL_DIR/connect.sh"
    [network-setup.sh]="$INSTALL_DIR/network-setup.sh"
    [pair.sh]="$INSTALL_DIR/pair.sh"
    [support.sh]="$INSTALL_DIR/support.sh"
    [timezone.sh]="$INSTALL_DIR/timezone.sh"
    [remote-support-toggle.sh]="$INSTALL_DIR/remote-support-toggle.sh"
    [crash-reporting.sh]="$INSTALL_DIR/crash-reporting.sh"
    [slime-id.sh]="$INSTALL_DIR/slime-id.sh"
    [index.html]="$INSTALL_DIR/lockscreen/index.html"
    [space-grotesk.woff2]="$INSTALL_DIR/lockscreen/fonts/space-grotesk.woff2"
    [plus-jakarta-sans.woff2]="$INSTALL_DIR/lockscreen/fonts/plus-jakarta-sans.woff2"
    [jetbrains-mono.woff2]="$INSTALL_DIR/lockscreen/fonts/jetbrains-mono.woff2"
    [slimeos-bridge]="$INSTALL_DIR/slimeos-bridge"
)

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

# Written last, only after every file above has landed -- a helper that
# dies partway through the loop above never advances this, so the next
# _updateTick's do_update_check() sees the still-old version and retries
# the whole cycle from scratch (idempotent, self-healing).
if [[ -f "$STAGING_DIR/version" ]]; then
    install -m 0644 -o root -g root "$STAGING_DIR/version" "$CONFIG_DIR/version"
fi

rm -rf "$STAGING_DIR"

echo "[apply-update] rebooting to complete the update"
systemctl reboot
