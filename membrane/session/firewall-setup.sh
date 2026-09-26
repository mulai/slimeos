#!/usr/bin/env bash
# Slime OS — firewall setup and self-repair (root)
#
# Run as `firewall-setup.sh boot` by slimeos-firewall.service on every boot
# (ordered After=ufw.service), and with no argument by
# remote-support-toggle.sh before it adds or removes its rule.
#
#   * First boot only (no marker): reset ufw to deny-in/allow-out and enable
#     it. Before 0.3.32 this reset ran on EVERY boot, concurrently with
#     ufw.service loading the previous rules; on 2026-09-24 that race left a
#     UTM Membrane with ENABLED=no and half-loaded live chains (no
#     ufw-user-logging-input). `ufw enable` then fails forever with "Could
#     not load logging rules", and `ufw allow` only writes user.rules, so
#     Remote Support showed as on while SSH stayed unreachable.
#   * Every run: if ufw is disabled or its live chains are incomplete,
#     rebuild them with disable + enable (a plain enable doesn't reload an
#     already-running firewall).
#   * `boot`: drop Remote Support's port-22 rule. The per-boot reset used to
#     do this; devices installed before 2026-08-03 have no
#     slimeos-remote-support-reset.service to do it instead.
#   * `boot`, when RESCUE_MARKER exists: add the port-22 rule back instead of
#     dropping it. membrane/tools/rescue-enable-ssh.sh (run from the
#     installer USB's Rescue mode, with no live ufw to call directly) drops
#     that marker to mean "SSH must keep working on this device"; unlike
#     Remote Support's own rule, this one has to survive every boot, and
#     remote-support-toggle.sh's own boot-time reset leaves it alone for the
#     same reason (see that script). Idempotent either way -- ufw no-ops
#     re-adding a rule that's already there.
#
# flock: the boot unit and the Remote Support reset unit can both call this
# at boot; two concurrent ufw rebuilds are the same race again.
set -euo pipefail

MARKER="/etc/slimeos/firewall-initialized"
RESCUE_MARKER="/etc/slimeos/rescue-ssh-enabled"

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

exec 9>/run/slimeos-firewall.lock
flock 9

if [[ ! -f "$MARKER" ]]; then
    ufw --force reset >/dev/null
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw --force enable >/dev/null
    touch "$MARKER"
fi

healthy() {
    grep -qx 'ENABLED=yes' /etc/ufw/ufw.conf &&
        iptables -S ufw-user-input >/dev/null 2>&1 &&
        iptables -S ufw-user-logging-input >/dev/null 2>&1
}

if ! healthy; then
    echo "[firewall] ufw disabled or live chains incomplete -- rebuilding" >&2
    ufw --force disable >/dev/null 2>&1 || true
    ufw --force enable >/dev/null
    healthy || { echo "[firewall] ufw still unhealthy after rebuild" >&2; exit 1; }
fi

if [[ "${1:-}" == "boot" ]]; then
    # Hub only (10.10.0.1); 0.3.50 and earlier opened the whole subnet.
    ufw delete allow from 10.10.0.0/24 to any port 22 proto tcp >/dev/null 2>&1 || true
    if [[ -f "$RESCUE_MARKER" ]]; then
        ufw allow from 10.10.0.1 to any port 22 proto tcp comment 'slimeos rescue ssh' >/dev/null
    else
        ufw delete allow from 10.10.0.1 to any port 22 proto tcp >/dev/null 2>&1 || true
    fi
fi
