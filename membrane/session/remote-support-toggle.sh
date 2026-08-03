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
# Reuses the exact same "ssh $SESSION_USER@<device's-wg-ip>" access pattern
# membrane/tools/rescue-enable-ssh.sh documents for manual Rescue-mode setup
# -- same account, same WireGuard-subnet-only reachability -- so on-device
# support docs describe one story, not two. The difference is this path is
# live-toggleable from the kiosk itself and nothing it does is durable:
#   * `on` only STARTS ssh.service (never `enable`s it) and adds a live ufw
#     rule (never touches the persisted /etc/slimeos/firewall-setup.sh) --
#     both vanish on the next reboot even if a user forgets to flip this
#     back off.
#   * the password is freshly randomized on every `on` -- flipping off then
#     on again invalidates whatever was shared before, so an old screenshot
#     or chat log of the connection info is worthless.
#   * `off` also locks the account (`usermod -L`), which DOES persist --
#     the extra belt-and-braces layer in case ssh.service or the firewall
#     rule are ever left behind by a crash mid-toggle.
set -euo pipefail

SESSION_USER="slime"
WG_SUBNET="10.10.0.0/24"
SSH_PORT="22"

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
[[ $# -eq 1 && ( "$1" == "on" || "$1" == "off" ) ]] || { echo "usage: $0 on|off" >&2; exit 2; }

case "$1" in
    on)
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

        wg_ip=$(ip -4 -o addr show wg0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
        jq -nc --arg host "${wg_ip:-unknown}" --arg port "$SSH_PORT" --arg user "$SESSION_USER" --arg pw "$password" \
            '{host:$host, port:($port|tonumber), username:$user, password:$pw}'
        ;;
    off)
        usermod -L "$SESSION_USER" 2>/dev/null || true
        systemctl stop ssh.service 2>/dev/null || true
        # `ufw delete` exits non-zero (and logs "Could not delete
        # non-existent rule") if this is called twice in a row or at boot
        # before `on` was ever run once -- expected, not an error here.
        ufw delete allow from "$WG_SUBNET" to any port "$SSH_PORT" proto tcp >/dev/null 2>&1 || true
        echo '{}'
        ;;
esac
