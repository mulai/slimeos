#!/usr/bin/env bash
# Profile 006 — Apple MacBook / MacBook Pro / MacBook Air (Intel, 2012–2020)
# Matches: DMI vendor/product contains MacBookPro, MacBookAir, or Macmini
#
# Validated families:
#   MacBook Air  2012–2020  (BCM4360/4350 Wi-Fi, Intel HD/Iris GPU)
#   MacBook Pro  2012–2019  (BCM4360/4355 Wi-Fi, Intel + AMD or NVIDIA dGPU)
#   Mac mini     2012–2018  (BCM4331/4360 Wi-Fi, Intel HD GPU)
#
# NOT supported by this profile: Apple Silicon (M1/M2/M3) — requires Asahi Linux.
#
# Install note:
#   Broadcom Wi-Fi firmware is non-free and must be loaded before the adapter works.
#   Use a USB Ethernet adapter or Thunderbolt-to-Ethernet dongle during the initial
#   Debian install so the preseed can download packages. The firmware is then
#   installed post-boot by this profile.

log() { echo "[slimeos/hw-profile:mac-intel] $*"; }

log "Applying Apple Mac Intel profile..."

# ── Broadcom Wi-Fi firmware ───────────────────────────────────────────────────
# Most Intel Macs use BCM4360/4350/4331 — covered by firmware-brcm80211.
# Older models (pre-2012) may need firmware-b43-installer instead.
log "Installing Broadcom Wi-Fi firmware..."
apt-get install -y --no-install-recommends firmware-brcm80211 2>/dev/null || \
    log "WARN: firmware-brcm80211 unavailable — enable non-free-firmware repo and retry"

# Reload the brcmfmac driver if the firmware was just installed
if modinfo brcmfmac &>/dev/null; then
    modprobe -r brcmfmac 2>/dev/null || true
    modprobe brcmfmac 2>/dev/null || true
fi

# ── Intel GPU (i915) ──────────────────────────────────────────────────────────
# All Intel Macs have Intel HD/Iris integrated graphics driven by i915.
# GuC/HuC support varies by generation; keep conservative defaults.
cat > /etc/modprobe.d/slimeos-i915-mac.conf <<'EOF'
# Slime OS: Apple Mac Intel — i915 settings
# FBC saves power on laptops; PSR disabled (causes flicker on some Macs)
options i915 enable_fbc=1 enable_psr=0 fastboot=1
EOF

SLIMEOS_COMPOSITOR_RENDERER="gl"
SLIMEOS_KERNEL_EXTRA="quiet"

# ── Discrete GPU handling ─────────────────────────────────────────────────────
# MacBook Pros with AMD dGPU: let amdgpu/radeon handle it — no action needed.
# MacBook Pros with NVIDIA dGPU (pre-2016): blacklist nouveau to prevent
# conflicts with the Intel integrated GPU used by cage/Wayland.
if lspci | grep -qi "NVIDIA"; then
    log "NVIDIA dGPU detected — blacklisting nouveau (using Intel iGPU only)"
    cat > /etc/modprobe.d/slimeos-blacklist-nouveau.conf <<'EOF'
# Slime OS: Disable NVIDIA dGPU on MacBook Pro — use Intel iGPU for Wayland
blacklist nouveau
options nouveau modeset=0
EOF
    SLIMEOS_KERNEL_EXTRA="quiet nouveau.modeset=0"
fi

# ── Apple keyboard — function key mapping ─────────────────────────────────────
# By default Mac keyboards require Fn+F1-F12 for function keys.
# fnmode=2 makes F1-F12 act as standard function keys (Fn inverts).
cat > /etc/modprobe.d/slimeos-hid-apple.conf <<'EOF'
# Slime OS: Apple keyboard — F1–F12 as standard function keys
options hid_apple fnmode=2
EOF
modprobe -r hid_apple 2>/dev/null || true
modprobe hid_apple 2>/dev/null || true

# ── Fan control ───────────────────────────────────────────────────────────────
# mbpfan reads Apple SMC fan data and sets safe fan speeds under Linux.
if apt-get install -y --no-install-recommends mbpfan 2>/dev/null; then
    systemctl enable mbpfan 2>/dev/null || true
    systemctl start mbpfan 2>/dev/null || true
    log "mbpfan enabled"
else
    log "WARN: mbpfan unavailable — fans will run at firmware default speed"
fi

# ── Power management ──────────────────────────────────────────────────────────
# tlp provides sane battery/CPU power defaults on laptops
if apt-get install -y --no-install-recommends tlp 2>/dev/null; then
    systemctl enable tlp 2>/dev/null || true
    log "tlp enabled"
fi

# Disable sleep/hibernate — kiosk device stays awake
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true

# ── FreeRDP performance flags ─────────────────────────────────────────────────
# Intel HD/Iris on Mac supports H.264 decode via VA-API (i965/iHD driver).
# Using GFX pipeline with AVC; fallback to RFX if the server doesn't offer AVC.
SLIMEOS_FREERDP_EXTRA_FLAGS="/network:lan /gfx /gfx:avc420 /bpp:32 /rfx"

cat > /etc/slimeos/hw-freerdp-flags <<EOF
SLIMEOS_FREERDP_EXTRA_FLAGS="$SLIMEOS_FREERDP_EXTRA_FLAGS"
SLIMEOS_COMPOSITOR_RENDERER="$SLIMEOS_COMPOSITOR_RENDERER"
EOF

# ── Kernel parameters (written to /etc/slimeos for grub update later) ────────
cat > /etc/slimeos/kernel-extra-params <<EOF
SLIMEOS_KERNEL_EXTRA="$SLIMEOS_KERNEL_EXTRA"
EOF

log "Apple Mac Intel profile applied."
