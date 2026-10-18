#!/usr/bin/env bash
# Slime OS — WireGuard tunnel watchdog (root)
#
# Run by slimeos-tunnel-watchdog.service (install.sh section 9c; existing
# devices get the unit from remote-support-toggle.sh's boot-time `off`).
#
# Why: some home routers turn a NAT mapping one-way. The Membrane's packets
# still reach the hub, the hub's replies never come back, and the tunnel
# stays dead for as long as the router keeps that mapping (10+ minutes seen
# on 2026-10-17, from the same router as the AMD box). The kernel tunnel
# keeps its UDP port for good, so nothing on the device ever recovers by
# itself; only a reboot did. The Android app's SlimeTunnel watchdog (f9917e1)
# fixed the same thing on the tablet.
#
# How: ping the hub over the tunnel every CHECK_EVERY seconds. After
# FAILS_TO_ACT misses in a row, while the device still has a route to the
# hub's public endpoint (no point while it's simply offline), move wg0 to a
# new random UDP port. That makes the router create a fresh mapping; the hub
# follows the new source port by itself (WireGuard roaming), and ufw lets the
# replies in through conntrack like it does for the current random port.
# If the hub keeps not answering (hub down, not the router), wait twice as
# long before each next move, up to MAX_BACKOFF checks.
set -uo pipefail

HUB_IP="${SLIMEOS_HUB_WG_IP:-10.10.0.1}"
CHECK_EVERY=15
FAILS_TO_ACT=2
MAX_BACKOFF=20   # checks, so 5 min

log() { echo "[tunnel-watchdog] $*"; }

hub_endpoint_routable() {
    local ep
    ep=$(wg show wg0 endpoints 2>/dev/null | awk 'NR==1 {print $2}')
    [[ -n "$ep" && "$ep" != "(none)" ]] || return 1
    ep="${ep%:*}"; ep="${ep#[}"; ep="${ep%]}"
    ip route get "$ep" &>/dev/null
}

fails=0
act_after=$FAILS_TO_ACT
moved=false # moved the tunnel since the hub last answered
while sleep "$CHECK_EVERY"; do
    if ! ip link show wg0 &>/dev/null || ! hub_endpoint_routable; then
        fails=0
        act_after=$FAILS_TO_ACT
        continue
    fi
    if ping -c1 -W3 "$HUB_IP" &>/dev/null; then
        { $moved || (( fails >= FAILS_TO_ACT )); } && log "hub answers again"
        moved=false
        fails=0
        act_after=$FAILS_TO_ACT
        continue
    fi
    fails=$((fails + 1))
    (( fails < act_after )) && continue

    old_port=$(wg show wg0 listen-port 2>/dev/null)
    new_port=$(shuf -i 20000-60999 -n 1)
    log "no answer from the hub for $((fails * CHECK_EVERY)) s: moving the tunnel from port ${old_port:-?} to $new_port"
    wg set wg0 listen-port "$new_port" || log "wg set listen-port $new_port failed"
    moved=true
    act_after=$(( act_after * 2 > MAX_BACKOFF ? MAX_BACKOFF : act_after * 2 ))
    fails=0
done
