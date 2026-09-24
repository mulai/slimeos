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
# can now enable the exact same access live, from the gear icon, with no USB
# stick and a fresh password shown on screen instead of one typed here by
# hand. Reach for THIS script only when the kiosk itself is unreachable
# (cage/cog crashed, black screen, etc) and Rescue mode is the only way in.
#
# Usage — boot the installer USB → Advanced options → Rescue mode → pick the
# root partition → "Execute a shell" (you are root; no sudo). Then:
#
#   passwd slime      # pick a password; SSH uses it
#   rm -f /etc/resolv.conf; echo "nameserver 1.1.1.1" > /etc/resolv.conf
#   curl -fsSL https://raw.githubusercontent.com/mulai/slimeos/main/membrane/tools/rescue-enable-ssh.sh | bash
#
# then exit the shell and reboot without the USB. Everything below takes
# effect on that next real boot:
#   * openssh-server installed
#   * ssh.service enabled via a direct symlink (a rescue chroot has no live
#     systemd to `enable --now` with — see the 2026-07-12 bring-up notes)
#   * the 'slime' account unlocked (belt-and-braces on top of `passwd`
#     above, which already drops any lock left by a previous boot's reset)
#   * /etc/slimeos/rescue-ssh-enabled dropped as a marker. Two OTA-delivered
#     scripts read it, not this one, because this chroot can't run ufw or
#     touch a live systemd (see above):
#       - firewall-setup.sh (slimeos-firewall.service, every boot) adds a
#         `ufw allow` for port 22 from the WireGuard subnet ONLY when the
#         marker is present, instead of leaving that port closed. The LAN
#         still sees nothing — ufw's default deny incoming stands; only
#         Brain-hub-side WireGuard peers (10.10.0.0/24) can reach sshd.
#       - remote-support-toggle.sh (slimeos-remote-support-reset.service,
#         every boot, forces Remote Support off) leaves the account and
#         ssh.service alone when the marker is present, instead of locking
#         the account and stopping sshd the way it normally does.
#     Before 0.3.32 the rule lived in a per-device copy of
#     /etc/slimeos/firewall-setup.sh that this script sed-edited directly;
#     that file no longer exists (firewall-setup.sh is OTA-delivered straight
#     to /opt/slimeos and reset ufw on every boot before it could be found
#     and edited here), so the marker replaces the sed edit.
#     To revoke this access later: as root over the same durable SSH session,
#     `rm /etc/slimeos/rescue-ssh-enabled`, then either reboot or toggle
#     Remote Support off once from the kiosk's Settings panel — either one
#     runs remote-support-toggle.sh off with nothing left to skip, which
#     locks the account, stops sshd and drops the firewall rule for real.
set -euo pipefail

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

# Marker for firewall-setup.sh and remote-support-toggle.sh (both
# OTA-delivered, both re-read on every boot) -- see the header above for why
# this script can't touch ufw or a live systemd itself, and can't edit a
# per-device firewall-setup.sh copy the way it used to before 0.3.32.
mkdir -p /etc/slimeos
touch /etc/slimeos/rescue-ssh-enabled

# Belt-and-braces on top of `passwd` above, which already clears any lock
# left by a previous boot's Remote Support reset when it sets the new hash.
usermod -U slime 2>/dev/null || true

echo ""
echo "  ✓ SSH enabled for the next boot, and every boot after that"
echo "    (WireGuard peers only, port 22)"
echo "  ✓ Make sure you've set a password:  passwd slime"
echo ""
echo "  Now: exit this shell, remove the USB, and reboot normally."
echo "  Reach it from the Brain hub side, e.g.:  ssh slime@<this-device's-wg-ip>"
echo "  To revoke later: rm /etc/slimeos/rescue-ssh-enabled, then reboot or"
echo "  toggle Remote Support off once from the kiosk's Settings panel."
echo ""
