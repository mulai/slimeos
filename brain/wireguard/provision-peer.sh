#!/usr/bin/env bash
# Slime OS — WireGuard peer provisioner
# Generates a client config for a new Membrane device and prints a QR code.
#
# Usage:
#   docker exec slimeos-wireguard /bin/bash
#   OR on the host: docker exec slimeos-wireguard /config/provision-peer.sh <device-name> [--brain]
#
# --brain: this peer is a Brain (serves RDP). Its address is added to
# /config/brain-peers so forward-rules.sh lets other peers reach its port
# 3389; without it, Membranes can't connect to it (#41). Membranes (and
# pairgen's codes) don't pass it.
#
# Or run directly on the Brain host after WireGuard is up:
#   ./provision-peer.sh <device-name>
#   e.g. ./provision-peer.sh tommy-h97

set -euo pipefail

PEER_NAME="${1:-membrane-$(date +%s)}"
IS_BRAIN=false
[[ "${2:-}" == "--brain" ]] && IS_BRAIN=true
WG_DIR="/config/wg_confs"
PEER_DIR="/config/peer_${PEER_NAME}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root inside the WireGuard container"

# Read server config
SERVER_CONF="$WG_DIR/wg0.conf"
[[ -f "$SERVER_CONF" ]] || die "Server config not found at $SERVER_CONF. Is WireGuard running?"

# One provisioning at a time (#44): pairgen serves requests concurrently, and
# two runs picking the next free IP from the same wg0.conf would hand two
# peers the same /32 (WireGuard then routes it to whichever loaded last).
# pair-peer.sh takes the same lock to remove expired peers. On the shared
# /config volume, so both containers see it.
command -v flock >/dev/null || die "flock not found"
exec 9>>/config/.provision.lock
flock -w 30 9 || die "another peer is being provisioned; try again"

SERVER_PUBKEY=$(grep "^PrivateKey" "$SERVER_CONF" | awk '{print $3}' | wg pubkey)

# SERVERURL/SERVERPORT are the same env vars docker-compose.yml passes into
# this container (WG_SERVER_URL/WG_PORT) — the linuxserver/wireguard image
# uses them internally but never writes them back into wg_confs/wg0.conf, so
# grepping the server config for them (the old approach) always returned
# empty and silently produced an unusable "Endpoint = :51820".
[[ -n "${SERVERURL:-}" ]] || die "SERVERURL env var not set — is this running inside the slimeos-wireguard container?"
SERVER_ENDPOINT="${SERVERURL}:${SERVERPORT:-51820}"
DNS=$(grep "^DNS" "$SERVER_CONF" | awk '{print $3}' || echo "1.1.1.1")

# Determine next available IP in 10.10.0.0/24
USED_IPS=$(grep "AllowedIPs" "$SERVER_CONF" | grep -oP '10\.10\.0\.\K\d+' | sort -n)
NEXT_IP=2
for ip in $USED_IPS; do
    [[ $ip -eq $NEXT_IP ]] && (( NEXT_IP++ ))
done
(( NEXT_IP <= 254 )) || die "no free address left in 10.10.0.0/24"
CLIENT_IP="10.10.0.${NEXT_IP}/32"

# Generate client keypair
mkdir -p "$PEER_DIR"
wg genkey | tee "$PEER_DIR/private.key" | wg pubkey > "$PEER_DIR/public.key"
wg genpsk > "$PEER_DIR/preshared.key"

CLIENT_PRIVKEY=$(cat "$PEER_DIR/private.key")
CLIENT_PUBKEY=$(cat "$PEER_DIR/public.key")
PSK=$(cat "$PEER_DIR/preshared.key")

# Write client config
cat > "$PEER_DIR/wg0.conf" <<EOF
# Slime OS — WireGuard Client Config
# Device: ${PEER_NAME}
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Copy this to /etc/wireguard/wg0.conf on the Membrane device.

[Interface]
PrivateKey = ${CLIENT_PRIVKEY}
Address = ${CLIENT_IP}
DNS = ${DNS}

[Peer]
PublicKey = ${SERVER_PUBKEY}
PresharedKey = ${PSK}
Endpoint = ${SERVER_ENDPOINT}
# 10.10.0.0/24 = WireGuard peer subnet; 10.11.0.0/24 = vpnnet, where the
# desktop container actually lives (10.11.0.10:3389). Without the second
# range, RDP traffic never routes into the tunnel and connects just time out.
AllowedIPs = 10.10.0.0/24, 10.11.0.0/24
PersistentKeepalive = 25
EOF

chmod 600 "$PEER_DIR/wg0.conf" "$PEER_DIR/private.key"

# Add peer to server config
cat >> "$SERVER_CONF" <<EOF

# Peer: ${PEER_NAME}
[Peer]
PublicKey = ${CLIENT_PUBKEY}
PresharedKey = ${PSK}
AllowedIPs = ${CLIENT_IP}
EOF

# Reload WireGuard without downtime. `wg syncconf` reconciles the live
# kernel state to match wg0.conf on disk, keyed by pubkey -- switched to
# this from the old `wg addconf` + `grep -A4 "# Peer: ${PEER_NAME}"`
# approach because a re-provisioned PEER_NAME (pairgen mints a new peer
# per code request, same device_name every time -- see pair-peer.sh)
# leaves multiple "# Peer: ${PEER_NAME}" blocks in the file, and grep -A4
# matches ALL of them, feeding wg addconf a garbled multi-peer blob.
# The bigger problem this whole block used to hide: every failure here
# was swallowed by `2>/dev/null || ... || true`, so a peer could sit in
# the config file forever, valid-looking, and NEVER load into the kernel
# -- the client held a config that could never handshake, and every layer
# above this (pair-peer.sh, pairgen, the dashboard) reported success.
# Confirmed live 2026-08-10: exactly this happened to a self-service
# pairing-code peer.
#
# `wg-quick strip wg0` (bare interface name) resolves to /etc/wireguard/
# wg0.conf by wg-quick's own convention -- that path only exists inside the
# wireguard container's filesystem (populated by the linuxserver/wireguard
# image's own init). pairgen execs this same script from a SEPARATE
# container that shares wg0's network namespace but not that filesystem
# path, so the bare-name form fails there with "does not exist" and takes
# the live interface down to zero peers mid-syncconf (confirmed live
# 2026-08-15: every peer vanished from `wg show wg0` and the listening
# port randomized until manually resynced). Pass $SERVER_CONF explicitly --
# a real path ending in .conf is used literally by wg-quick, so this works
# identically from any container that has /config mounted, not just this one.
if ! wg syncconf wg0 <(wg-quick strip "$SERVER_CONF"); then
    die "wg syncconf failed -- peer '${PEER_NAME}' was written to $SERVER_CONF but NOT loaded into the live interface. Do not hand out this pairing code."
fi

# Confirm the peer actually made it into the live kernel state -- syncconf
# can no-op on malformed input without a nonzero exit.
if ! wg show wg0 | grep -qF "peer: ${CLIENT_PUBKEY}"; then
    die "peer '${PEER_NAME}' (${CLIENT_PUBKEY}) still missing from live wg0 after syncconf. Do not hand out this pairing code."
fi

# wg syncconf registers the peer in the kernel but does NOT install a route
# to its IP -- wg-quick only creates per-peer routes for peers present when
# the interface comes up. Without this, the tunnel handshakes fine but all
# return traffic to the new client exits via the container's default route
# and vanishes: rx grows, tx stays flat, and every ping/RDP attempt times out.
if ! ip route add "${CLIENT_IP}" dev wg0 2>/dev/null; then
    # The route already exists when an IP is reused after a peer was removed.
    # Capture the table first: `ip route show | grep -q` under pipefail kills
    # `ip` with SIGPIPE (exit 141) once grep exits early on a long table, which
    # falsely reported every reused IP as unreachable (found 2026-09-23).
    routes=$(ip route show)
    grep -qF "${CLIENT_IP%/32} " <<<"$routes" || die "failed to add route for ${CLIENT_IP} -- peer is live but unreachable. Do not hand out this pairing code."
fi

if $IS_BRAIN; then
    grep -qxF "${CLIENT_IP%/32}" /config/brain-peers 2>/dev/null || echo "${CLIENT_IP%/32}" >> /config/brain-peers
    /config/forward-rules.sh || die "peer '${PEER_NAME}' is live but forward-rules.sh failed -- Membranes can't reach this Brain yet."
fi

echo ""
echo "  ✓ Peer '${PEER_NAME}' provisioned"
echo "  ✓ Client IP: ${CLIENT_IP}"
echo "  ✓ Config: $PEER_DIR/wg0.conf"
echo ""
echo "  To install on the Membrane device:"
echo "    scp $PEER_DIR/wg0.conf slime@<device-ip>:/tmp/"
echo "    sudo mv /tmp/wg0.conf /etc/wireguard/wg0.conf"
echo "    sudo chmod 600 /etc/wireguard/wg0.conf"
echo "    sudo systemctl enable --now wg-quick@wg0"
echo ""

# QR code for easy mobile/visual config
if command -v qrencode &>/dev/null; then
    echo "  QR Code (scan with WireGuard app):"
    qrencode -t ansiutf8 < "$PEER_DIR/wg0.conf"
fi
