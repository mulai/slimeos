#!/usr/bin/env bash
# Profile 008 — Gigabyte GA-78LMT-S2P / AMD FX-6100 (AM3+, Bulldozer)
# Validated device: Tommy's second real-hardware test machine
#
# Specs (from Windows System Information, pre-wipe):
#   Board: Gigabyte GA-78LMT-S2P (AMD 760G + SB710 chipset, Award BIOS v6.00)
#   CPU:   AMD FX-6100 Six-Core @ ~3.3 GHz (Bulldozer)
#   RAM:   8 GB
#   NIC/GPU/WiFi chipsets: not yet confirmed — this board has an added
#     wireless card (not onboard), model unknown until Linux actually
#     boots and `lspci`/`lsusb` can identify it.
#
# This is a placeholder, same spirit as 000-generic.sh, kept separate so
# `detect.sh` doesn't silently lump this device under the fallback profile.
# Fill in real NIC/GPU/WiFi driver tuning (see 001-gigabyte-h97.sh for the
# level of detail to aim for) after the first real boot's `lspci -k`/
# `lsusb`/`dmesg` output is available — don't guess at chipsets here.

log() { echo "[slimeos/hw-profile:78lmt] $*"; }

log "Applying Gigabyte GA-78LMT-S2P / FX-6100 profile (placeholder — not yet hardware-validated)..."

# ── Kernel parameters ─────────────────────────────────────────────────────────
SLIMEOS_KERNEL_EXTRA="quiet"

# ── Compositor renderer ───────────────────────────────────────────────────────
# AMD 760G integrated graphics (Radeon HD 3000-class) uses the `radeon` DRM
# driver, not amdgpu. Leave empty and let wlroots auto-detect until a real
# boot confirms gles2 works correctly on this chipset.
SLIMEOS_COMPOSITOR_RENDERER=""

# ── FreeRDP performance flags ─────────────────────────────────────────────────
# Conservative codec set until real-hardware RDP performance is measured.
SLIMEOS_FREERDP_EXTRA_FLAGS="/network:broadband /gfx:rfx /bpp:32"

cat > /etc/slimeos/hw-freerdp-flags <<EOF
SLIMEOS_FREERDP_EXTRA_FLAGS="$SLIMEOS_FREERDP_EXTRA_FLAGS"
SLIMEOS_COMPOSITOR_RENDERER="$SLIMEOS_COMPOSITOR_RENDERER"
EOF

# ── Power: disable sleep (kiosk device stays awake) ──────────────────────────
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true

log "78LMT-S2P placeholder profile applied — revisit after first real boot."
