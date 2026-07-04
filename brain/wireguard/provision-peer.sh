#!/usr/bin/env bash
# Slime OS — WireGuard peer provisioner
# Generates a client config for a new Membrane device and prints a QR code.
#
# Usage:
#   docker exec slimeos-wireguard /bin/bash
#   OR on the host: docker exec slimeos-wireguard /config/provision-peer.sh <device-name>
#
# Or run directly on the Brain host after WireGuard is up:
#   ./provision-peer.sh <device-name>
#   e.g. ./provision-peer.sh tommy-h97

set -euo pipefail

PEER_NAME="${1:-membrane-$(date +%s)}"
WG_DIR="/config/wg_confs"
PEER_DIR="/config/peer_${PEER_NAME}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root inside the WireGuard container"

# Read server config
SERVER_CONF="$WG_DIR/wg0.conf"
[[ -f "$SERVER_CONF" ]] || die "Server config not found at $SERVER_CONF. Is WireGuard running?"

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
AllowedIPs = 10.10.0.0/24
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

# Reload WireGuard without downtime
wg addconf wg0 <(wg-quick strip wg0 | grep -A4 "# Peer: ${PEER_NAME}" || true) 2>/dev/null || \
    wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null || true

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
