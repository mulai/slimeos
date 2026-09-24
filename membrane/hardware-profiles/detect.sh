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

    # DMI vendor is "VMware, Inc." on Workstation/Fusion/ESXi guests. Must
    # match before the generic fallback: vmwgfx needs the pixman renderer
    # (dmabuf import is broken), which generic deliberately doesn't force.
    elif echo "$DMI_VENDOR" | grep -qi "VMware"; then
        echo "009-vmware-guest.sh"

    # NUC6CAxx family (Celeron J3xxx/J4xxx, quad-core, no HT) — weak
    # single-thread performance makes xfreerdp3's single-threaded AVC444
    # decode the real bottleneck for video playback (see profile 010's own
    # header for detail). Board prefix, not exact model, to also cover
    # untested siblings (NUC6CAYS etc.) in the same low-power tier.
    elif echo "$DMI_BOARD" | grep -qi "NUC6CA"; then
        echo "010-intel-nuc6-celeron.sh"

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

# ── FreeRDP package sync ──────────────────────────────────────────────────────
# The patched FreeRDP build (camera + keyboard fixes + the UDP transport,
# +slimeos7) ships as ordinary OTA bundle files under hardware-profiles/freerdp/,
# already sha256-verified by update.sh. They live under hardware-profiles/ on
# purpose: apply-update-helper.sh re-runs this script as root whenever a file
# there lands, and that helper can't update itself, so this is the only root
# hook an already-installed device has for installing packages. Idempotent:
# does nothing when the bundled version is already installed. Leaves test
# builds (version contains "research") and anything newer alone; a newer
# Debian point release would drop the camera/keyboard/UDP patches, see
# install.sh section 1b.
FREERDP_DEB_DIR="$PROFILE_DIR/freerdp"
FREERDP_DEBS=(freerdp3-x11.deb libfreerdp-client3-3.deb libfreerdp3-3.deb libwinpr3-3.deb)

sync_freerdp() {
    [[ "$(dpkg --print-architecture 2>/dev/null)" == "amd64" ]] || { log "FreeRDP sync: not amd64, skipping"; return 0; }
    local deb want have
    for deb in "${FREERDP_DEBS[@]}"; do
        [[ -f "$FREERDP_DEB_DIR/$deb" ]] || { log "FreeRDP sync: $deb not in the bundle, skipping"; return 0; }
    done
    want=$(dpkg-deb -f "$FREERDP_DEB_DIR/freerdp3-x11.deb" Version) || return 1
    have=$(dpkg-query -W -f='${Version}' freerdp3-x11 2>/dev/null || true)
    if [[ "$have" == "$want" ]]; then
        log "FreeRDP sync: $have already installed"
        return 0
    fi
    if [[ "$have" == *research* ]]; then
        log "FreeRDP sync: test build $have installed, leaving it (bundle has $want)"
        return 0
    fi
    if [[ -n "$have" ]] && dpkg --compare-versions "$have" gt "$want"; then
        log "FreeRDP sync: newer $have installed, not downgrading to $want"
        return 0
    fi
    log "FreeRDP sync: ${have:-none} -> $want"
    dpkg -i "${FREERDP_DEBS[@]/#/$FREERDP_DEB_DIR/}"
}

sync_freerdp || log "FreeRDP sync failed (non-fatal, retried on the next update)"
