#!/usr/bin/env bash
# Slime OS — cage Wayland session entrypoint
# Launched by slimeos-session.service as the 'slime' user on tty1.
# Starts cage (kiosk Wayland compositor) with brain-select.sh as the sole application.

set -euo pipefail

INSTALL_DIR="/opt/slimeos"
CONFIG_DIR="/etc/slimeos"
LOG_FILE="/var/log/slimeos/session.log"

exec >> "$LOG_FILE" 2>&1
trap 'echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] FAILED at line $LINENO: $BASH_COMMAND"' ERR
echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Session starting"

# ── Load hardware profile flags ───────────────────────────────────────────────
HW_FLAGS="$CONFIG_DIR/hw-freerdp-flags"
SLIMEOS_COMPOSITOR_RENDERER=""   # empty = let wlroots auto-detect
if [[ -f "$HW_FLAGS" ]]; then
    # shellcheck source=/dev/null
    source "$HW_FLAGS"
fi

# ── XDG runtime dir ───────────────────────────────────────────────────────────
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# ── Wait for WireGuard VPN ────────────────────────────────────────────────────
MAX_WAIT=30
waited=0
while ! ip link show wg0 &>/dev/null; do
    if (( waited >= MAX_WAIT )); then
        echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] WireGuard wg0 not up after ${MAX_WAIT}s — continuing anyway"
        break
    fi
    sleep 1
    # not (( waited++ )): post-increment evaluates to the pre-increment value,
    # so on the very first pass (waited=0) it's falsy and set -e kills the
    # script immediately.
    waited=$((waited + 1))
done

if ip link show wg0 &>/dev/null; then
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] WireGuard wg0 is up"
fi

# ── Launch cage ───────────────────────────────────────────────────────────────
# cage: minimal Wayland compositor designed for kiosk use
#   -d = allow drop to shell on exit (disabled in production — remove for security)
#   -s = allow switching VTs
# cog (WPE WebKit's kiosk launcher) is the only application cage manages,
# pointed at the local lock screen bundle. cog talks to slimeos-bridge (a
# separate, independently-supervised systemd unit — see
# membrane/bridge/) over a loopback WebSocket; the bridge relays JSON
# events to coordinator.sh, which owns the actual Brain-picker/connect
# logic that brain-select.sh + connect.sh used to drive via whiptail.
echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Launching cage compositor (renderer: ${SLIMEOS_COMPOSITOR_RENDERER:-auto})"

# cage 0.1.4 (Debian 12) has no --renderer flag at all ("invalid option -- '-'")
# -- renderer backend selection for wlroots compositors is done via the
# WLR_RENDERER env var, not a cage CLI option. Only export it when a hardware
# profile explicitly requests one; leaving it unset lets wlroots auto-detect
# (its own default behavior), which is what "empty" is supposed to mean here.
if [[ -n "$SLIMEOS_COMPOSITOR_RENDERER" ]]; then
    export WLR_RENDERER="$SLIMEOS_COMPOSITOR_RENDERER"
fi

# Virtual GPUs (UTM/virglrenderer at least) render the DRM hardware-cursor
# plane flipped vertically with a shifted hotspot — the arrow points down
# and clicks land off-target. Compositing the cursor in software sidesteps
# the cursor plane; only needed in VMs, real GPUs handle it fine.
if systemd-detect-virt --quiet; then
    export WLR_NO_HARDWARE_CURSORS=1
fi

# WebKit's internal renderer sandbox (bubblewrap + xdg-dbus-proxy) refuses to
# start with "Unexpected capabilities but not setuid" in this environment --
# bwrap itself is healthy (works fine invoked directly), the failure is
# specific to whatever capability/namespace state WebKit's own dbus-proxy
# launch sees. Disabling it is an acceptable trade for this kiosk
# specifically: the sandbox exists to contain a compromised renderer that
# loaded untrusted remote content, but this page is always first-party,
# locally-shipped, static HTML (membrane/lockscreen/index.html) -- it never
# fetches or renders anything from the network. Every other layer (AppArmor,
# no SSH, encrypted credentials, WireGuard-only network) stays in place.
export WEBKIT_FORCE_SANDBOX=0

# cog's Wayland platform module is named "wl" (libcogplatform-wl.so), not
# "wayland" -- passing the latter makes cog fail to find any usable platform
# and abort before ever opening a window.
exec cage -- cog -P wl "file://$INSTALL_DIR/lockscreen/index.html"
