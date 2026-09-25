#!/usr/bin/env bash
# Slime OS — WireGuard config install helper (root)
#
# Invoked as `wg-install-helper.sh` with NO arguments and the config on
# stdin, via `sudo -n` by pair.sh's pair_install_config() (running as
# $SESSION_USER). /etc/sudoers.d/53-slimeos-wireguard scopes the NOPASSWD
# grant to exactly this script, no args -- same precedent as
# apply-update-helper.sh.
#
# Why a root helper (#48): the session user used to own /etc/wireguard and
# could start/enable wg-quick@wg0 through a polkit rule, so it could write
# a wg0.conf with `PostUp = <cmd>` (wg-quick runs it as root) and bring it
# up. The same rule also let it enable ANY unit file (manage-unit-files
# can't be scoped per unit). Now /etc/wireguard is root-owned, the polkit
# rule is gone, and the only way in is this script, which runs every config
# through pair_sanitize_config()'s allowlist (the one #38 added) and writes
# the rebuilt result.
#
# Exit 3 = config rejected (the reason is on stdout).
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
[[ $# -eq 0 ]] || { echo "usage: $0 < wg0.conf (no arguments)" >&2; exit 2; }

INSTALL_DIR="/opt/slimeos"
WG_DIR="/etc/wireguard"

# pair.sh only defines functions; it's root-owned under $INSTALL_DIR.
# shellcheck source=pair.sh
source "$INSTALL_DIR/pair.sh"

config=$(head -c 16384)
if ! clean=$(pair_sanitize_config "$config"); then
    echo "$clean"
    exit 3
fi

# 0755 so the session user can still see that wg0.conf exists
# (coordinator.sh's have_wg_tunnel), never read it.
mkdir -p "$WG_DIR"
chown root:root "$WG_DIR"
chmod 755 "$WG_DIR"
tmp=$(mktemp "$WG_DIR/wg0.conf.XXXXXX")
printf '%s\n' "$clean" > "$tmp"
chmod 600 "$tmp"
mv "$tmp" "$WG_DIR/wg0.conf"
systemctl enable --now wg-quick@wg0
