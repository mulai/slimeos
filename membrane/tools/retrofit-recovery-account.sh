#!/usr/bin/env bash
# Slime OS — retrofit tool: add the dedicated 'slime-recovery' console
# account to a device that was installed before 0.3.3.
#
# install.sh's "13b" section (0.3.3+) creates this account automatically on
# every fresh install. Devices installed before that fix only have the
# 'slime' account, whose real login password is NOT stable -- it's
# rewritten on every Remote Support "on" toggle and locked entirely
# (`usermod -L`) by default on every boot (see remote-support-toggle.sh /
# slimeos-remote-support-reset.service) -- so the recovery PIN shown once
# at install time stops being a working console password the moment Remote
# Support is ever used even once. Found live 2026-08-23 on the NUC6CAYH.
#
# This script is NOT part of the auto-update bundle (account/sshd changes
# aren't file-copy operations apply-update-helper.sh can express) -- it has
# to be run by hand, once, on each already-provisioned device. Safe to
# re-run (idempotent).
#
# Usage — SSH in as 'slime' (Remote Support toggle, or the existing
# rescue-enable-ssh.sh persistent setup), then:
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/mulai/slimeos/main/membrane/tools/retrofit-recovery-account.sh)"
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }

CONFIG_DIR="/etc/slimeos"
RECOVERY_USER="slime-recovery"
PIN_FILE="$CONFIG_DIR/recovery-pin"

[[ -f "$PIN_FILE" ]] || { echo "No $PIN_FILE on this device -- not a Slime OS Membrane install?" >&2; exit 1; }
RECOVERY_PIN=$(cat "$PIN_FILE")

if id "$RECOVERY_USER" &>/dev/null; then
    echo "  '$RECOVERY_USER' already exists -- just re-syncing its password to the current recovery PIN."
else
    useradd -m -s /bin/bash -G sudo "$RECOVERY_USER"
    echo "  Created '$RECOVERY_USER'."
fi
echo "${RECOVERY_USER}:${RECOVERY_PIN}" | chpasswd

mkdir -p /etc/ssh/sshd_config.d
echo "DenyUsers ${RECOVERY_USER}" > /etc/ssh/sshd_config.d/50-slimeos-recovery-console-only.conf
systemctl reload ssh.service 2>/dev/null || true

echo ""
echo "  ✓ '$RECOVERY_USER' is set up -- console-login only (tty1 or Ctrl+Alt+F2..F6), SSH denied."
echo "  ✓ Password is the recovery PIN already shown to you at install time."
echo "  This account is now permanent and independent of Remote Support toggling."
echo ""
