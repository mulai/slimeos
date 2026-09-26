#!/usr/bin/env bash
# Slime OS desktop container entrypoint
# Creates the user account and starts xRDP on each container start.

set -euo pipefail

SLIME_USER="${SLIME_USER:-slimeuser}"
SLIME_PASS="${SLIME_PASS:-}"

# No default password (#45): every WireGuard peer can reach this desktop, so
# a well-known fallback would be an open login. Also refuse .env.example's
# placeholder.
if [[ -z "$SLIME_PASS" || "$SLIME_PASS" == CHANGE_ME* ]]; then
    echo "[slimeos/desktop] SLIME_PASS is not set (SLIME_DESKTOP_PASS in .env); refusing to start" >&2
    exit 1
fi

echo "[slimeos/desktop] Starting Slime OS Linux Desktop..."

# ── Create user if not exists ─────────────────────────────────────────────────
if ! id "$SLIME_USER" &>/dev/null; then
    echo "[slimeos/desktop] Creating user: $SLIME_USER"
    useradd -m -s /bin/bash -G audio,video "$SLIME_USER"
    cp -r /etc/skel/. "/home/$SLIME_USER/"
    chown -R "$SLIME_USER:$SLIME_USER" "/home/$SLIME_USER"
fi
# No sudo for the shared desktop login (#45); also drops it from a user
# created by an older image.
gpasswd -d "$SLIME_USER" sudo &>/dev/null || true

# Always update password (allows credential rotation via env var)
echo "${SLIME_USER}:${SLIME_PASS}" | chpasswd

# ── dbus ─────────────────────────────────────────────────────────────────────
rm -f /var/run/dbus/pid
dbus-daemon --system --fork 2>/dev/null || true

# ── xRDP ─────────────────────────────────────────────────────────────────────
rm -f /var/run/xrdp/xrdp.pid /var/run/xrdp/xrdp-sesman.pid 2>/dev/null || true
mkdir -p /var/run/xrdp

echo "[slimeos/desktop] Starting xRDP on :3389"
/usr/sbin/xrdp-sesman
exec /usr/sbin/xrdp --nodaemon
