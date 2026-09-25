#!/usr/bin/env bash
# Slime OS — Remote Support SSH toggle (root helper)
#
# Invoked as `remote-support-toggle.sh on|off`, run as root -- either via
# `sudo -n` by support.sh's do_support() (which itself runs unprivileged, as
# $SESSION_USER) in response to the Settings panel's Support tab checkbox,
# or directly by systemd at boot (slimeos-remote-support-reset.service, see
# install.sh) to force the "off" state regardless of how the machine was
# last shut down. /etc/sudoers.d/slimeos-remote-support scopes the NOPASSWD
# grant to exactly this one script, nothing broader.
#
# Same WireGuard-subnet-only port-22 rule as the manual Rescue-mode setup in
# membrane/tools/rescue-enable-ssh.sh, but a different account ($SESSION_USER
# here, RESCUE_USER there). The difference is this path is
# live-toggleable from the kiosk itself and nothing it does is durable:
#   * `on` only STARTS ssh.service (never `enable`s it) and adds a ufw
#     rule that `off` deletes -- and slimeos-remote-support-reset.service
#     runs `off` on every boot, so neither survives a reboot even if a user
#     forgets to flip this back off.
#   * the password is freshly randomized on every `on` -- flipping off then
#     on again invalidates whatever was shared before, so an old screenshot
#     or chat log of the connection info is worthless.
#   * `off` also locks the account (`usermod -L`), which DOES persist --
#     the extra belt-and-braces layer in case ssh.service or the firewall
#     rule are ever left behind by a crash mid-toggle.
#
# Exception: if RESCUE_MARKER exists, `off` keeps ssh.service running and
# the ufw rule open. That marker means membrane/tools/rescue-enable-ssh.sh
# was run from the installer USB's Rescue mode: a technician with physical
# access set up durable SSH for its own account, RESCUE_USER, and that has
# to survive this script's boot-time reset. `off` still locks
# $SESSION_USER either way, so the password `on` showed on screen never
# outlives a reboot. firewall-setup.sh checks the same marker to keep its
# ufw rule up. Without the marker, `off` also locks RESCUE_USER, so
# revoking is `rm` the marker and reboot.
#
# ACTIVE_FLAG (in /run, so gone after every reboot) is what support.sh
# reads to show the toggle as on. ssh.service alone can't tell it: with
# the marker, sshd runs after every boot without Remote Support being on.
set -euo pipefail

SESSION_USER="slime"
WG_SUBNET="10.10.0.0/24"
SSH_PORT="22"

INSTALL_DIR="/opt/slimeos"
FIREWALL_SETUP="$INSTALL_DIR/firewall-setup.sh"
FIREWALL_UNIT="/etc/systemd/system/slimeos-firewall.service"
RESCUE_MARKER="/etc/slimeos/rescue-ssh-enabled"
RESCUE_USER="slime-rescue"
ACTIVE_FLAG="/run/slimeos-remote-support-on"

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
[[ $# -eq 1 && ( "$1" == "on" || "$1" == "off" ) ]] || { echo "usage: $0 on|off" >&2; exit 2; }

# One-time migration for devices installed before 0.3.32, whose boot unit
# runs /etc/slimeos/firewall-setup.sh (a ufw reset on every boot, racing
# ufw.service -- see firewall-setup.sh's header). This script is the only
# OTA-delivered file that already runs as root at boot (via `off`), so it
# repoints the unit at the OTA-delivered copy. The marker stops that copy
# from doing its first-boot reset on an already-configured device.
migrate_firewall_unit() {
    [[ -x "$FIREWALL_SETUP" ]] || return 0
    grep -qx "ExecStart=$FIREWALL_SETUP boot" "$FIREWALL_UNIT" 2>/dev/null && return 0
    touch /etc/slimeos/firewall-initialized
    cat > "$FIREWALL_UNIT" <<SERVICE
[Unit]
Description=Slime OS — Firewall setup (ufw)
DefaultDependencies=no
After=ufw.service
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=$FIREWALL_SETUP boot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE
    rm -f /etc/slimeos/firewall-setup.sh
    systemctl daemon-reload || true
}

# #48 migration (0.3.46), same reasoning as migrate_firewall_unit: this is the
# OTA-delivered root script that runs at every boot. Takes /etc/wireguard back
# from the session user, grants it wg-install-helper.sh instead, and only then
# drops the polkit rule that let it write/enable wg-quick@wg0 (and enable any
# other unit file). Idempotent; cheap enough to run every boot.
WG_HELPER="$INSTALL_DIR/wg-install-helper.sh"
WG_SUDOERS="/etc/sudoers.d/53-slimeos-wireguard"
WG_POLKIT_RULE="/etc/polkit-1/rules.d/52-slimeos-wireguard.rules"
migrate_wireguard_root() {
    [[ -x "$WG_HELPER" ]] || return 0
    if [[ ! -f "$WG_SUDOERS" ]]; then
        local tmp
        tmp=$(mktemp)
        printf '%s ALL=(root) NOPASSWD: %s ""\n' "$SESSION_USER" "$WG_HELPER" > "$tmp"
        visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; return 1; }
        install -m 0440 -o root -g root "$tmp" "$WG_SUDOERS"
        rm -f "$tmp"
    fi
    mkdir -p /etc/wireguard
    chown root:root /etc/wireguard
    chmod 755 /etc/wireguard
    rm -f /etc/wireguard/wg0.conf.??????
    if [[ -f /etc/wireguard/wg0.conf ]]; then
        chown root:root /etc/wireguard/wg0.conf
        chmod 600 /etc/wireguard/wg0.conf
    fi
    rm -f "$WG_POLKIT_RULE"
}

case "$1" in
    on)
        # Repair first: on a half-loaded ufw, `ufw allow` below only writes
        # user.rules and never reaches the live firewall.
        [[ -x "$FIREWALL_SETUP" ]] && "$FIREWALL_SETUP"

        # Excludes 0/O/1/l/I -- this gets read off a screen and typed by a
        # human on the other end, not pasted.
        #
        # The leading `head -c 256` bounds the /dev/urandom read to a
        # finite chunk BEFORE it ever reaches `tr` -- piping the infinite
        # device straight into `tr | head -c 20` looks equivalent but isn't
        # under `set -o pipefail`: the final `head` closing early sends
        # SIGPIPE to `tr` (still blocked reading /dev/urandom), which bash
        # reports as tr exiting 141, and pipefail then fails this whole
        # script even though the truncation was intentional. Bounding the
        # input first means `tr` hits a normal EOF and exits 0 on its own.
        # 256 bytes filtered through this ~23%-of-256-values charset
        # comfortably clears 20 characters with room to spare.
        password=$(head -c 256 /dev/urandom | tr -dc 'A-HJ-NP-Za-km-z2-9' | head -c 20)
        echo "${SESSION_USER}:${password}" | chpasswd
        usermod -U "$SESSION_USER"

        systemctl start ssh.service

        # Idempotent: harmless if a previous `on` already added it (e.g. a
        # coordinator restart between toggles never got the matching `off`).
        ufw allow from "$WG_SUBNET" to any port "$SSH_PORT" proto tcp comment 'slimeos remote support' >/dev/null

        # `ufw status` reads user.rules, not the live firewall, so check the
        # live chain. Without this the kiosk shows working connection details
        # for an SSH port nobody can reach.
        if ! iptables -S ufw-user-input 2>/dev/null | grep -q -- "-s $WG_SUBNET .*--dport $SSH_PORT "; then
            echo "ufw rule for port $SSH_PORT is not in the live firewall" >&2
            usermod -L "$SESSION_USER" 2>/dev/null || true
            systemctl stop ssh.service 2>/dev/null || true
            exit 1
        fi

        touch "$ACTIVE_FLAG"
        wg_ip=$(ip -4 -o addr show wg0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
        jq -nc --arg host "${wg_ip:-unknown}" --arg port "$SSH_PORT" --arg user "$SESSION_USER" --arg pw "$password" \
            '{host:$host, port:($port|tonumber), username:$user, password:$pw}'
        ;;
    off)
        # Never let the migration or repair fail `off` itself: locking the
        # account and stopping ssh below matter more.
        migrate_firewall_unit || echo "firewall unit migration failed" >&2
        migrate_wireguard_root || echo "wireguard root migration failed" >&2
        if [[ -x "$FIREWALL_SETUP" ]]; then "$FIREWALL_SETUP" || true; fi

        rm -f "$ACTIVE_FLAG"
        usermod -L "$SESSION_USER" 2>/dev/null || true
        if [[ -f "$RESCUE_MARKER" ]]; then
            # Rescue-mode SSH lives on RESCUE_USER over this same port --
            # see the RESCUE_MARKER note up top.
            echo '{}'
            exit 0
        fi
        usermod -L "$RESCUE_USER" 2>/dev/null || true
        systemctl stop ssh.service 2>/dev/null || true
        # `ufw delete` exits non-zero (and logs "Could not delete
        # non-existent rule") if this is called twice in a row or at boot
        # before `on` was ever run once -- expected, not an error here.
        ufw delete allow from "$WG_SUBNET" to any port "$SSH_PORT" proto tcp >/dev/null 2>&1 || true
        echo '{}'
        ;;
esac
