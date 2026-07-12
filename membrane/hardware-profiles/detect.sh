#!/usr/bin/env bash
# hardware-profiles/detect.sh
# Detects the current machine and applies the matching hardware profile.
# Safe to run multiple times (idempotent).
# Called by install.sh on first boot and by slimeos-update.

set -euo pipefail

PROFILE_DIR="$(dirname "$(realpath "$0")")"
APPLIED_MARKER="/etc/slimeos/hw-profile-applied"

log() { echo "[slimeos/hw-detect] $*"; }

# ── Read machine identifiers ──────────────────────────────────────────────────
# DMI/SMBIOS (x86 BIOS/UEFI) and the device-tree (ARM/other firmware-less
# boards, e.g. Raspberry Pi) are mutually exclusive — a board exposes one or
# the other, never both — so read both and let whichever exists match.
ARCH=$(uname -m)
DMI_VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "unknown")
DMI_PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "unknown")
DMI_BOARD=$(cat /sys/class/dmi/id/board_name 2>/dev/null || echo "unknown")
DT_MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "unknown")
DT_COMPAT=$(tr -d '\0' < /proc/device-tree/compatible 2>/dev/null || echo "unknown")
CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs || echo "unknown")
GPU_CLASS=$(lspci 2>/dev/null | grep -iE "VGA|3D|Display" | head -1 || echo "")

# Combined string for family matching — covers both DMI and device-tree boards.
MATCH_STR="$DMI_VENDOR $DMI_PRODUCT $DMI_BOARD $DT_MODEL $DT_COMPAT"

log "Arch:    $ARCH"
log "Vendor:  $DMI_VENDOR"
log "Product: $DMI_PRODUCT"
log "Board:   $DMI_BOARD"
log "DT model: $DT_MODEL"
log "CPU:     $CPU_MODEL"
log "GPU:     $GPU_CLASS"

# ── Match profile ─────────────────────────────────────────────────────────────
select_profile() {
    # Profile matching is intentionally broad — match family, not exact model.
    # Add new elif blocks as new devices are validated.

    if echo "$DMI_BOARD" | grep -qi "H97"; then
        echo "001-gigabyte-h97.sh"

    elif echo "$MATCH_STR" | grep -qi "ThinkPad T450\|ThinkPad T460\|ThinkPad T470"; then
        echo "002-lenovo-thinkpad-t4x.sh"

    elif echo "$MATCH_STR" | grep -qi "ThinkPad X220\|ThinkPad X230\|ThinkPad X240"; then
        echo "003-lenovo-thinkpad-x2x.sh"

    elif echo "$MATCH_STR" | grep -qi "Dell.*Latitude\|Dell.*OptiPlex"; then
        echo "004-dell-latitude-optiplex.sh"

    elif echo "$MATCH_STR" | grep -qi "HP.*EliteBook\|HP.*ProBook\|HP.*Compaq"; then
        echo "005-hp-elitebook.sh"

    elif echo "$MATCH_STR" | grep -qi "MacBookPro\|MacBookAir\|Macmini"; then
        echo "006-apple-mac-intel.sh"

    elif echo "$MATCH_STR" | grep -qi "Raspberry"; then
        echo "007-raspberry-pi.sh"

    elif echo "$DMI_BOARD" | grep -qi "78LMT"; then
        echo "008-gigabyte-78lmt-s2p.sh"

    else
        # Fallback: generic — works on most machines, conservative settings
        echo "000-generic.sh"
    fi
}

PROFILE=$(select_profile)
PROFILE_PATH="$PROFILE_DIR/$PROFILE"

if [[ ! -f "$PROFILE_PATH" ]]; then
    log "Profile $PROFILE not found, falling back to 000-generic.sh"
    PROFILE="000-generic.sh"
    PROFILE_PATH="$PROFILE_DIR/000-generic.sh"
fi

log "Selected profile: $PROFILE"

# ── Apply profile ─────────────────────────────────────────────────────────────
# shellcheck source=/dev/null
source "$PROFILE_PATH"

# Record what was applied
mkdir -p /etc/slimeos
cat > "$APPLIED_MARKER" <<EOF
profile=$PROFILE
arch=$ARCH
vendor=$DMI_VENDOR
product=$DMI_PRODUCT
board=$DMI_BOARD
dt_model=$DT_MODEL
cpu=$CPU_MODEL
applied_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

log "Profile applied. Marker written to $APPLIED_MARKER"
