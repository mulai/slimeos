#!/usr/bin/env bash
# Slime OS — retrofit tool: bring apply-update-helper.sh up to date on a
# device that was installed before 0.3.14.
#
# apply-update-helper.sh deliberately can't update itself (see its own
# header), so every device keeps the copy it was installed with. Only
# 0.3.14+ copies re-run hardware-profiles/detect.sh after an update lands.
# On an older device, hardware-profile changes AND the patched FreeRDP
# packages (hardware-profiles/freerdp/*.deb, installed by detect.sh's
# FreeRDP sync step) download and verify fine but are never applied.
# Found live 2026-09-24 on the NUC6CAYH (installed 2026-08-22): its
# Settings kept saying the faster connection needed a software update.
#
# This script is NOT part of the auto-update bundle — run it by hand, once,
# on each already-provisioned device. Safe to re-run (does nothing when the
# helper is already current).
#
# Usage — SSH in as 'slime' (Remote Support toggle), then:
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/mulai/slimeos/main/membrane/tools/retrofit-update-helper.sh)"
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }

REPO_BASE="https://raw.githubusercontent.com/mulai/slimeos/main"
INSTALL_DIR="/opt/slimeos"
HELPER="$INSTALL_DIR/apply-update-helper.sh"
# sha256 of membrane/update/apply-update-helper.sh. Update it here in the
# same commit whenever that file changes.
HELPER_SHA256="8332d20d5af2bafdc288ada8738a3bf438209fd584cfca372222f9714481b839"

[[ -f "$HELPER" ]] || { echo "No $HELPER on this device -- not a Slime OS Membrane install?" >&2; exit 1; }
[[ -f /etc/sudoers.d/51-slimeos-update ]] || {
    echo "No /etc/sudoers.d/51-slimeos-update -- this device predates the in-kiosk updater and needs a reinstall." >&2
    exit 1
}

if echo "$HELPER_SHA256  $HELPER" | sha256sum -c - >/dev/null 2>&1; then
    echo "  apply-update-helper.sh is already current -- nothing to do."
    exit 0
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
curl -fsSL --retry 3 --retry-delay 2 "$REPO_BASE/membrane/update/apply-update-helper.sh" -o "$tmp"
echo "$HELPER_SHA256  $tmp" | sha256sum -c - >/dev/null || {
    echo "Downloaded helper doesn't match the pinned checksum -- refusing to install it." >&2
    exit 1
}

backup="/root/apply-update-helper.sh.pre-retrofit-$(date +%Y%m%d-%H%M%S)"
cp -p "$HELPER" "$backup"
install -m 0700 -o root -g root "$tmp" "$HELPER"
echo "  ✓ apply-update-helper.sh updated (old copy: $backup)."

# Apply what earlier updates delivered but never applied: the matching
# hardware profile and, on amd64, the bundled FreeRDP build.
echo "  Re-running hardware detection (profile + FreeRDP sync)..."
bash "$INSTALL_DIR/hardware-profiles/detect.sh"

echo ""
echo "  ✓ Done. Restart the Membrane (or: systemctl restart slimeos-bridge) so the"
echo "    session picks up the re-applied profile."
echo ""
