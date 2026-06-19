#!/usr/bin/env bash
# hardware-profiles/detect.sh
# Detects the current machine and applies the matching hardware profile.
# Safe to run multiple times (idempotent).
# Called by install.sh on first boot and by slimeos-update.

set -euo pipefail

PROFILE_DIR="$(dirname "$(realpath "$0")")"
APPLIED_MARKER="/etc/slimeos/hw-profile-applied"

log() { echo "[slimeos/hw-detect] $*"; }

# ── Read DMI identifiers ──────────────────────────────────────────────────────
DMI_VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "unknown")
DMI_PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "unknown")
DMI_BOARD=$(cat /sys/class/dmi/id/board_name 2>/dev/null || echo "unknown")
CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs || echo "unknown")
GPU_CLASS=$(lspci 2>/dev/null | grep -iE "VGA|3D|Display" | head -1 || echo "")

log "Vendor:  $DMI_VENDOR"
log "Product: $DMI_PRODUCT"
log "Board:   $DMI_BOARD"
log "CPU:     $CPU_MODEL"
log "GPU:     $GPU_CLASS"

# ── Match profile ─────────────────────────────────────────────────────────────
select_profile() {
    # Profile matching is intentionally broad — match family, not exact model.
    # Add new elif blocks as new devices are validated.

    if echo "$DMI_BOARD" | grep -qi "H97"; then
        echo "001-gigabyte-h97.sh"

    elif echo "$DMI_VENDOR$DMI_PRODUCT" | grep -qi "ThinkPad T450\|ThinkPad T460\|ThinkPad T470"; then
        echo "002-lenovo-thinkpad-t4x.sh"

    elif echo "$DMI_VENDOR$DMI_PRODUCT" | grep -qi "ThinkPad X220\|ThinkPad X230\|ThinkPad X240"; then
        echo "003-lenovo-thinkpad-x2x.sh"

    elif echo "$DMI_VENDOR$DMI_PRODUCT" | grep -qi "Dell.*Latitude\|Dell.*OptiPlex"; then
        echo "004-dell-latitude-optiplex.sh"

    elif echo "$DMI_VENDOR$DMI_PRODUCT" | grep -qi "HP.*EliteBook\|HP.*ProBook\|HP.*Compaq"; then
        echo "005-hp-elitebook.sh"

    elif echo "$DMI_VENDOR$DMI_PRODUCT" | grep -qi "MacBookPro\|MacBookAir\|Macmini"; then
        echo "006-apple-mac-intel.sh"

    elif echo "$DMI_VENDOR$DMI_PRODUCT" | grep -qi "Raspberry\|RPi"; then
        echo "007-raspberry-pi.sh"

    else
        # Fallback: generic x86_64 — works on most machines, conservative settings
        echo "000-generic-x86_64.sh"
    fi
}

PROFILE=$(select_profile)
PROFILE_PATH="$PROFILE_DIR/$PROFILE"

if [[ ! -f "$PROFILE_PATH" ]]; then
    log "Profile $PROFILE not found, falling back to 000-generic-x86_64.sh"
    PROFILE="000-generic-x86_64.sh"
    PROFILE_PATH="$PROFILE_DIR/000-generic-x86_64.sh"
fi

log "Selected profile: $PROFILE"

# ── Apply profile ─────────────────────────────────────────────────────────────
# shellcheck source=/dev/null
source "$PROFILE_PATH"

# Record what was applied
mkdir -p /etc/slimeos
cat > "$APPLIED_MARKER" <<EOF
profile=$PROFILE
vendor=$DMI_VENDOR
product=$DMI_PRODUCT
board=$DMI_BOARD
cpu=$CPU_MODEL
applied_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

log "Profile applied. Marker written to $APPLIED_MARKER"
