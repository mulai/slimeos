#!/usr/bin/env bash
# Profile 009 — VMware guest (Workstation / Fusion / ESXi)
# The vmwgfx virtual GPU cannot import dmabufs exported by another process:
# cog/WPE renders the lock screen fine, but when it hands its GPU buffers to
# cage over zwp_linux_dmabuf_v1 the import fails ("importing the supplied
# dmabufs failed", protocol error 7) and cog is killed — black screen with a
# live compositor. Validated on Workstation Pro 26H1, 2026-07-19.
#
# Forcing the pixman renderer makes cage stop advertising linux-dmabuf, so
# WebKit falls back to wl_shm buffers; cog still renders with GLES internally
# (vmwgfx EGL works in-process — 3D acceleration must be enabled in the VM
# settings, or cage fails earlier with EGL_NOT_INITIALIZED). This is safe
# HERE precisely because it is scoped to vmwgfx: the same pixman pin broke
# output negotiation on virtio-gpu-gl (see 000-generic.sh).

log() { echo "[slimeos/hw-profile:vmware-guest] $*"; }

log "Applying VMware guest profile..."

# ── Kernel parameters ─────────────────────────────────────────────────────────
SLIMEOS_KERNEL_EXTRA="quiet"
SLIMEOS_COMPOSITOR_RENDERER="pixman"

# ── FreeRDP performance flags ─────────────────────────────────────────────────
# Same as generic: AVC444 decode is pure CPU via libavcodec, so software
# compositing doesn't change the calculus.
SLIMEOS_FREERDP_EXTRA_FLAGS="/gfx:AVC444 /bpp:32"

# Export for use by connect.sh and slimeos-session.sh
cat > /etc/slimeos/hw-freerdp-flags <<EOF
SLIMEOS_FREERDP_EXTRA_FLAGS="$SLIMEOS_FREERDP_EXTRA_FLAGS"
SLIMEOS_COMPOSITOR_RENDERER="$SLIMEOS_COMPOSITOR_RENDERER"
EOF

log "VMware guest profile applied."
