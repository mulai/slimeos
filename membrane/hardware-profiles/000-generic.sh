#!/usr/bin/env bash
# Profile 000 — Generic fallback (any architecture)
# Applied when no specific device match is found.
# Conservative settings that work on the widest range of hardware.

log() { echo "[slimeos/hw-profile:generic] $*"; }

log "Applying generic profile..."

# ── Kernel parameters ─────────────────────────────────────────────────────────
SLIMEOS_KERNEL_EXTRA="quiet"
# Empty = let wlroots auto-detect (tries gles2, falls back to pixman itself).
# Forcing "pixman" doesn't actually relax hardware requirements the way it
# sounds like it should: the DRM/KMS output negotiation and GBM buffer
# support wlroots needs for scanout are required regardless of which
# renderer draws the pixels, so pinning pixman bought no real safety and
# broke output negotiation on at least one virtual GPU (virtio-gpu-gl).
SLIMEOS_COMPOSITOR_RENDERER=""

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
