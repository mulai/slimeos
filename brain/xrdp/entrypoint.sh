#!/usr/bin/env bash
# Slime OS desktop container entrypoint
# Creates the user account and starts xRDP on each container start.

set -euo pipefail

SLIME_USER="${SLIME_USER:-slimeuser}"
SLIME_PASS="${SLIME_PASS:-changeme}"

echo "[slimeos/desktop] Starting Slime OS Linux Desktop..."

# ── Create user if not exists ─────────────────────────────────────────────────
if ! id "$SLIME_USER" &>/dev/null; then
    echo "[slimeos/desktop] Creating user: $SLIME_USER"
    useradd -m -s /bin/bash -G sudo,audio,video "$SLIME_USER"
    cp -r /etc/skel/. "/home/$SLIME_USER/"
    chown -R "$SLIME_USER:$SLIME_USER" "/home/$SLIME_USER"
fi

# Always update password (allows credential rotation via env var)
echo "${SLIME_USER}:${SLIME_PASS}" | chpasswd

# ── dbus ─────────────────────────────────────────────────────────────────────
rm -f /var/run/dbus/pid
dbus-daemon --system --fork 2>/dev/null || true

# ── xRDP ─────────────────────────────────────────────────────────────────────
rm -f /var/run/xrdp/xrdp.pid 2>/dev/null || true
mkdir -p /var/run/xrdp

echo "[slimeos/desktop] Starting xRDP on :3389"
exec /usr/sbin/xrdp --nodaemon
