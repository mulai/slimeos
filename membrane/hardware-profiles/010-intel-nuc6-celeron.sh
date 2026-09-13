#!/usr/bin/env bash
# Profile 010 — Intel NUC6CAxx (NUC6CAYH validated) / Celeron J3455
# Validated device: NUC6CAYH, Tommy's real-hardware test/lab machine
#
# Specs (confirmed on-device):
#   Board: NUC6CAYB (Intel NUC6CAYH kit)
#   CPU:   Intel Celeron J3455 @ 1.50GHz, quad-core, no Hyper-Threading
#   GPU:   Intel HD Graphics 500 (Apollo Lake)
#
# ── FreeRDP performance flags ─────────────────────────────────────────────────
# github.com/mulai/slimeos#14: default /gfx:AVC444 made YouTube playback on
# this board visibly choppy. Root-caused (2026-09-12) to xfreerdp3's AVC444
# decode being single-threaded -- it pins ONE core at ~110-125% for the
# whole video, while the other 3 sit ~90% idle (confirmed live via `top`/
# `vmstat`, load average ~2.0 of a possible 4.0). This board's weak
# single-thread performance (1.5GHz Atom-class Celeron, no boost) makes
# that one core the real bottleneck, not aggregate CPU or network.
# /gfx:AVC420 (chroma 4:2:0, cheaper H.264 decode) fixes it -- confirmed
# smooth playback across several fullscreen-video connect/disconnect
# cycles, live on this exact board, 2026-09-13. Held back from shipping
# until 2026-09-13 by github.com/mulai/slimeos#17 (a resize like this one
# does as a side effect could leave the Membrane stuck showing a
# quarter-frame Brain picker) -- that's now fixed at the connect.sh/
# slimeos-power layer (stale-session cleanup on disconnect), not by
# avoiding resizes, so AVC420 is safe to ship here.
# /rfx -- RemoteFX fallback alongside /gfx:AVC420, same belt-and-suspenders
# pairing profiles 001/006/008 already use for a lossy WiFi link.
# +video -- MS-RDPEVOR video-optimized channel, see coordinator.sh's
# SLIMEOS_FREERDP_EXTRA_FLAGS comment. Intel HD 500 has real VAAPI H.264
# decode capability in principle, but mainline FreeRDP's Linux client
# doesn't wire up hardware-accelerated decode -- the win here is still the
# channel split, not hardware decode.
# +auto-reconnect -- see coordinator.sh's SLIMEOS_FREERDP_EXTRA_FLAGS
# comment. This profile's own flags fully replace that default (sourced
# from hw-freerdp-flags below), so the flag has to be repeated here too.

log() { echo "[slimeos/hw-profile:nuc6ca] $*"; }

log "Applying Intel NUC6CAxx / Celeron J3455 profile..."

# ── Kernel parameters ─────────────────────────────────────────────────────────
SLIMEOS_KERNEL_EXTRA="quiet"

# ── Compositor renderer ───────────────────────────────────────────────────────
# Intel HD Graphics 500 (Apollo Lake) uses the `i915` DRM driver -- leave
# empty and let wlroots auto-detect (gles2 works correctly on this chipset,
# confirmed by every real-hardware session on this exact device).
SLIMEOS_COMPOSITOR_RENDERER=""

SLIMEOS_FREERDP_EXTRA_FLAGS="/gfx:AVC420 /bpp:32 /rfx +video +auto-reconnect"

cat > /etc/slimeos/hw-freerdp-flags <<EOF
SLIMEOS_FREERDP_EXTRA_FLAGS="$SLIMEOS_FREERDP_EXTRA_FLAGS"
SLIMEOS_COMPOSITOR_RENDERER="$SLIMEOS_COMPOSITOR_RENDERER"
EOF

# ── Power: disable sleep (kiosk device stays awake) ──────────────────────────
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true

log "NUC6CAxx / Celeron J3455 profile applied."
