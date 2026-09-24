#!/usr/bin/env bash
# Slime OS — debug/support tool: enable SSH access to a Membrane over its
# WireGuard tunnel, from the installer USB's Rescue-mode chroot.
#
# A kiosk Membrane has no interactive access path once cage owns the console
# (VT switching is blocked while the lock screen is up), so remote support
# needs sshd reachable through the Brain hub. This script sets that up from
# the only shell always available on a real device: Rescue mode.
#
# FALLBACK ONLY as of the Settings panel's Support tab (see
# membrane/session/support.sh / remote-support-toggle.sh): a working kiosk
# can now enable the same access live, from the gear icon, with no USB
# stick and a fresh password shown on screen instead of one typed here by
# hand. Reach for THIS script only when the kiosk itself is unreachable
# (cage/cog crashed, black screen, etc) and Rescue mode is the only way in.
#
# Usage — boot the installer USB → Advanced options → Rescue mode → pick the
# root partition → "Execute a shell" (you are root; no sudo). Then:
#
#   rm -f /etc/resolv.conf; echo "nameserver 1.1.1.1" > /etc/resolv.conf
#   curl -fsSL https://raw.githubusercontent.com/mulai/slimeos/main/membrane/tools/rescue-enable-ssh.sh | bash
#   passwd slime-rescue      # pick a password; SSH uses it
#
# then exit the shell and reboot without the USB. Everything below takes
# effect on that next real boot:
#   * openssh-server installed
#   * ssh.service enabled via a direct symlink (a rescue chroot has no live
#     systemd to `enable --now` with — see the 2026-07-12 bring-up notes)
#   * a dedicated 'slime-rescue' account (sudo). NOT 'slime': Remote Support
#     rotates that account's password on every "on" and locks it on every
#     "off" and every boot, and it must keep doing that on this device too,
#     or the password shown on the kiosk would stay valid forever.
#     remote-support-toggle.sh never changes this account's password.
#   * /etc/slimeos/rescue-ssh-enabled dropped as a marker. Two OTA-delivered
#     scripts read it, not this one, because this chroot can't run ufw or
#     touch a live systemd (see above):
#       - firewall-setup.sh (slimeos-firewall.service, every boot) adds a
#         `ufw allow` for port 22 from the WireGuard subnet ONLY when the
#         marker is present, instead of leaving that port closed. The LAN
#         still sees nothing — ufw's default deny incoming stands; only
#         Brain-hub-side WireGuard peers (10.10.0.0/24) can reach sshd.
#       - remote-support-toggle.sh (`off`, every boot) keeps ssh.service
#         and that rule up when the marker is present. It still locks
#         'slime' either way.
#     Before 0.3.32 the rule lived in a per-device copy of
#     /etc/slimeos/firewall-setup.sh that this script sed-edited directly;
#     that file no longer exists (firewall-setup.sh is OTA-delivered straight
#     to /opt/slimeos), so the marker replaces the sed edit.
#     To revoke this access later: as root over the same SSH session,
#     `rm /etc/slimeos/rescue-ssh-enabled`, then reboot. The boot-time
#     `off` then stops sshd, drops the rule and locks 'slime-rescue'.
set -euo pipefail

RESCUE_USER="slime-rescue"

[[ $EUID -eq 0 ]] || { echo "Run as root (you already are in a rescue chroot — don't use sudo)" >&2; exit 1; }

# d-i's rescue chroot usually has /proc & /sys mounted; some paths in apt
# maintainer scripts want them. Mount defensively if missing.
mountpoint -q /proc 2>/dev/null || mount -t proc proc /proc 2>/dev/null || true
mountpoint -q /sys  2>/dev/null || mount -t sysfs sys /sys 2>/dev/null || true

echo "Installing openssh-server..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server

# Belt and braces: the package postinst normally enables ssh.service itself
# (deb-systemd-helper works offline), but make sure regardless.
ln -sf /lib/systemd/system/ssh.service \
    /etc/systemd/system/multi-user.target.wants/ssh.service

# Re-running on a device that already has the account is fine: `passwd`
# afterwards replaces the hash, which also clears a lock left by a revoke.
id "$RESCUE_USER" &>/dev/null || useradd -m -s /bin/bash -G sudo "$RESCUE_USER"

# Marker for firewall-setup.sh and remote-support-toggle.sh (both
# OTA-delivered, both re-read on every boot) -- see the header above for why
# this script can't touch ufw or a live systemd itself.
mkdir -p /etc/slimeos
touch /etc/slimeos/rescue-ssh-enabled

echo ""
echo "  ✓ SSH enabled for the next boot, and every boot after that"
echo "    (WireGuard peers only, port 22, account '$RESCUE_USER')"
echo ""
echo "  Now set its password:  passwd $RESCUE_USER"
echo "  Then: exit this shell, remove the USB, and reboot normally."
echo "  Reach it from the Brain hub side, e.g.:  ssh $RESCUE_USER@<this-device's-wg-ip>"
echo "  To revoke later: rm /etc/slimeos/rescue-ssh-enabled, then reboot."
echo ""
