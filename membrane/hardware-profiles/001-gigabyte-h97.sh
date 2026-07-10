#!/usr/bin/env bash
# Profile 001 — Gigabyte H97-Gaming 3 / Intel i7-4790 (Haswell, LGA1150)
# Validated device: Tommy's reference test machine
#
# Specs:
#   CPU:  Intel Core i7-4790 @ 3.6 GHz (4C/8T, Haswell)
#   RAM:  16 GB DDR3
#   GPU:  Intel HD Graphics 4600 (integrated) — or discrete if fitted
#   NIC:  Intel I218-V (1 GbE)
#   USB:  USB 3.0 (xHCI), USB 2.0
#   Boot: UEFI + Legacy BIOS (CSM)
#
# Notes:
#   - i915 (Intel GPU) driver is in kernel; no proprietary blob needed.
#   - The H97 PCH supports Intel Quick Sync — useful if we ever add local
#     hardware video decode acceleration for the RDP stream.
#   - The Intel I218-V NIC uses the e1000e driver (mainline kernel).
#   - No switchable/discrete GPU quirks on this board in most configs.

log() { echo "[slimeos/hw-profile:h97] $*"; }

log "Applying Gigabyte H97-Gaming 3 / i7-4790 profile..."

# ── Intel GPU driver preferences ──────────────────────────────────────────────
# Use the i915 DRM driver. Modesetting X driver is best for Wayland/cage.
if lspci | grep -q "Intel.*HD Graphics 4600"; then
    log "Intel HD 4600 detected — enabling i915 optimisations"
    cat > /etc/modprobe.d/slimeos-i915.conf <<'EOF'
# Slime OS: i7-4790 Intel HD 4600
# Enable GuC/HuC firmware for better power management on Haswell
# (Note: Haswell GuC support is limited; this is a no-op on older firmware but harmless)
options i915 enable_fbc=1 enable_psr=0 fastboot=1
EOF
fi

# ── Kernel parameters ─────────────────────────────────────────────────────────
# pcie_aspm=off: prevents intermittent PCIe link instability seen on some H97 boards
# intel_iommu=on: future-proofs for VM passthrough
SLIMEOS_KERNEL_EXTRA="quiet pcie_aspm=off intel_iommu=on iommu=pt"

# ── Network tuning — Intel I218-V NIC ────────────────────────────────────────
if lspci | grep -qi "I218-V\|I218V\|Ethernet.*Intel"; then
    log "Intel I218-V NIC detected — applying low-latency ethtool settings"
    cat > /etc/slimeos/nic-tune.sh <<'NICS'
#!/usr/bin/env bash
# Run at startup by slimeos-network-tune.service
NIC=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -1)
if [[ -n "$NIC" ]]; then
    # Reduce IRQ coalescing for lower RDP latency
    ethtool -C "$NIC" rx-usecs 50 tx-usecs 50 2>/dev/null || true
    # Increase ring buffers
    ethtool -G "$NIC" rx 4096 tx 4096 2>/dev/null || true
fi
NICS
    chmod +x /etc/slimeos/nic-tune.sh
fi

# ── FreeRDP performance flags ─────────────────────────────────────────────────
# H97 / Haswell has Intel Quick Sync (h264/h265 decode) — enable GFX pipeline
# /cache:codec:rfx is the FreeRDP 3 spelling — FreeRDP 2's /codec-cache was
# removed and gets the whole command line rejected (exit 23, usage dump).
SLIMEOS_FREERDP_EXTRA_FLAGS="/network:lan /gfx /gfx:avc444 /bpp:32 /rfx /cache:codec:rfx"

# ── Compositor renderer ───────────────────────────────────────────────────────
# cage uses wlroots; valid WLR_RENDERER values are gles2/pixman/vulkan -- "gl"
# is not one of them. Intel GPU with i915 supports gles2.
SLIMEOS_COMPOSITOR_RENDERER="gles2"

cat > /etc/slimeos/hw-freerdp-flags <<EOF
SLIMEOS_FREERDP_EXTRA_FLAGS="$SLIMEOS_FREERDP_EXTRA_FLAGS"
SLIMEOS_COMPOSITOR_RENDERER="$SLIMEOS_COMPOSITOR_RENDERER"
EOF

# ── Power: disable sleep (kiosk device stays awake) ──────────────────────────
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true

# ── Install ethtool if missing ────────────────────────────────────────────────
if ! command -v ethtool &>/dev/null; then
    apt-get install -y --no-install-recommends ethtool 2>/dev/null || true
fi

log "H97 profile applied."
