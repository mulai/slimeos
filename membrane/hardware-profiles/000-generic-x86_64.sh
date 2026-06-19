#!/usr/bin/env bash
# Profile 000 — Generic x86_64 fallback
# Applied when no specific device match is found.
# Conservative settings that work on the widest range of hardware.

log() { echo "[slimeos/hw-profile:generic] $*"; }

log "Applying generic x86_64 profile..."

# ── Kernel parameters ─────────────────────────────────────────────────────────
SLIMEOS_KERNEL_EXTRA="quiet"
SLIMEOS_COMPOSITOR_RENDERER="pixman"   # Software rendering — safe fallback

# ── Power management ─────────────────────────────────────────────────────────
if command -v systemctl &>/dev/null; then
    systemctl enable NetworkManager 2>/dev/null || true
fi

# ── FreeRDP performance flags ─────────────────────────────────────────────────
# Conservative codec set — works on all GPUs
SLIMEOS_FREERDP_EXTRA_FLAGS="/network:broadband /gfx:rfx /bpp:32"

# Export for use by connect.sh
cat > /etc/slimeos/hw-freerdp-flags <<EOF
SLIMEOS_FREERDP_EXTRA_FLAGS="$SLIMEOS_FREERDP_EXTRA_FLAGS"
SLIMEOS_COMPOSITOR_RENDERER="$SLIMEOS_COMPOSITOR_RENDERER"
EOF

log "Generic profile applied."
