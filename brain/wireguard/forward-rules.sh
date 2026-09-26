#!/usr/bin/env bash
# Slime OS — WireGuard forwarding isolation (#41)
#
# The linuxserver/wireguard image's default PostUp accepts all forwarding on
# wg0, so every peer could reach every other peer on any port, and a peer
# that added the hub's Docker subnets to its own AllowedIPs could reach
# Redis/Postgres/Authelia. This builds a SLIMEOS-FWD chain, jumped to first
# from FORWARD:
#   - replies to allowed connections pass;
#   - peer -> peer only to a Brain peer's RDP port (3389 tcp+udp);
#   - any other peer -> peer traffic is dropped;
#   - peer -> anything outside the desktop subnet (10.11.0.0/24) is dropped.
# Everything else falls through to the image's own rules (hub -> peers,
# peers -> the desktop container).
#
# Brain peer addresses come from /config/brain-peers (one 10.10.0.x per
# line, on the hub's volume, not in this public repo). provision-peer.sh
# <name> --brain appends to it and re-runs this script.
#
# Runs at every container start (mounted into /custom-cont-init.d) and is
# safe to re-run: the chain is flushed and rebuilt, the jump added once.
set -euo pipefail

BRAIN_PEERS="/config/brain-peers"
DESKTOP_SUBNET="10.11.0.0/24"
CHAIN="SLIMEOS-FWD"

iptables -N "$CHAIN" 2>/dev/null || iptables -F "$CHAIN"

iptables -A "$CHAIN" -i wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
brains=0
if [[ -f "$BRAIN_PEERS" ]]; then
    while IFS= read -r ip || [[ -n "$ip" ]]; do
        ip="${ip%%#*}"; ip="${ip//[[:space:]]/}"
        [[ -z "$ip" ]] && continue
        if [[ ! "$ip" =~ ^10\.10\.0\.[0-9]{1,3}$ ]]; then
            echo "[forward-rules] skipping invalid brain-peers entry: $ip" >&2
            continue
        fi
        iptables -A "$CHAIN" -i wg0 -o wg0 -d "$ip" -p tcp --dport 3389 -j ACCEPT
        iptables -A "$CHAIN" -i wg0 -o wg0 -d "$ip" -p udp --dport 3389 -j ACCEPT
        brains=$((brains + 1))
    done < "$BRAIN_PEERS"
fi
iptables -A "$CHAIN" -i wg0 -o wg0 -j DROP
iptables -A "$CHAIN" -i wg0 ! -d "$DESKTOP_SUBNET" -j DROP

iptables -C FORWARD -j "$CHAIN" 2>/dev/null || iptables -I FORWARD 1 -j "$CHAIN"
echo "[forward-rules] $CHAIN rebuilt ($brains Brain peers)"
