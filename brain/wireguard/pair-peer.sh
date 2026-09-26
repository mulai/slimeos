#!/usr/bin/env bash
# Slime OS — WireGuard self-service pairing code generator
#
# Generates a peer (via provision-peer.sh, not duplicated here) and stashes
# its config in Redis behind a short-lived, single-use pairing code, so an
# end user can self-enroll their Membrane device by typing the code into the
# lock screen instead of an admin hand-copying wg0.conf over USB/rescue-mode.
#
# This is part of the open-source, account-free Connect path — it does NOT
# go through Authelia or dashboard.slimeos.com (that's reserved for the
# separate, not-yet-built "Sign in with Slime ID" managed path).
#
# Usage:
#   docker exec slimeos-wireguard /config/pair-peer.sh <device-name>
#
# The resulting code is meant to be relayed to the end user out-of-band
# (voice/chat/etc) and typed into the Membrane's "Pair with a Brain" screen.
#
# Every run mints a new peer, so codes that are never used would pile up
# peers until the /24 runs out (#44). Each code is also recorded as
# pairpending:<code> = "<pubkey> <ip> <expiry>"; brain/enroll deletes that
# record when the code is redeemed. Before minting, remove_expired_peers
# drops any peer whose code expired unredeemed AND that has never completed
# a handshake. Both conditions, so a device that did pair is never cut off.
#
# The Redis password goes in REDISCLI_AUTH and values over stdin (-x), not
# on the command line where any process can read them (#47).

set -euo pipefail

PEER_NAME="${1:-membrane-$(date +%s)}"
PEER_DIR="/config/peer_${PEER_NAME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root inside the WireGuard container"
[[ -n "${REDIS_PASSWORD:-}" ]] || die "REDIS_PASSWORD env var not set — is this running inside the slimeos-wireguard container?"
command -v redis-cli &>/dev/null || die "redis-cli not found — see wireguard/Dockerfile and pairgen/Dockerfile"

CODE_TTL=900
SERVER_CONF="/config/wg_confs/wg0.conf"
export REDISCLI_AUTH="$REDIS_PASSWORD"
redis() { redis-cli -h redis --no-auth-warning "$@"; }

# Removes one peer (by public key) from wg0.conf and the live interface.
remove_peer() {
    local pub="$1" ip="$2" tmp
    tmp=$(mktemp "${SERVER_CONF}.XXXXXX")
    awk -v key="$pub" '
        function flush() { if (!drop) printf "%s", buf; buf = ""; drop = 0 }
        /^# Peer: /  { flush(); buf = $0 "\n"; comment = 1; next }
        /^\[Peer\]/  { if (!comment) flush(); comment = 0; buf = buf $0 "\n"; next }
                     { comment = 0; if ($1 == "PublicKey" && $3 == key) drop = 1; buf = buf $0 "\n" }
        END          { flush() }' "$SERVER_CONF" > "$tmp"
    cat "$tmp" > "$SERVER_CONF"
    rm -f "$tmp"
    wg set wg0 peer "$pub" remove 2>/dev/null || true
    ip route del "$ip/32" dev wg0 2>/dev/null || true
}

remove_expired_peers() {
    local key rec pub ip expiry handshake now
    now=$(date +%s)
    exec 9>>/config/.provision.lock
    for _ in {1..30}; do flock -n 9 && break; sleep 1; done   # BusyBox flock: no -w
    flock -n 9 || { echo "cleanup skipped: provisioning lock busy" >&2; return 0; }
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        rec=$(redis GET "$key") || continue
        read -r pub ip expiry <<<"$rec"
        [[ "$pub" =~ ^[A-Za-z0-9+/]{43}=$ && "$ip" =~ ^10\.10\.0\.[0-9]{1,3}$ && "$expiry" =~ ^[0-9]+$ ]] || { redis DEL "$key" >/dev/null || true; continue; }
        (( now > expiry + 60 )) || continue
        handshake=$(wg show wg0 latest-handshakes | awk -v k="$pub" '$1 == k {print $2}') || continue
        if [[ -z "$handshake" ]]; then
            redis DEL "$key" >/dev/null || true   # peer already gone
        elif [[ "$handshake" == 0 ]]; then
            remove_peer "$pub" "$ip"
            redis DEL "$key" >/dev/null || true
            echo "removed unused peer $ip (code ${key#pairpending:} expired)" >&2
        fi
        # A handshake means the device paired even though the record is
        # still there (e.g. enroll's delete failed): keep the peer.
    done < <(redis --scan --pattern 'pairpending:*')
    exec 9>&-
}

remove_expired_peers

"$SCRIPT_DIR/provision-peer.sh" "$PEER_NAME" >&2

CONFIG_FILE="$PEER_DIR/wg0.conf"
[[ -f "$CONFIG_FILE" ]] || die "provision-peer.sh did not produce $CONFIG_FILE"

# Crockford-safe alphabet (excludes 0/O/1/I/L) -- unambiguous read aloud or
# hand-typed on the kiosk's on-screen/physical keyboard. 8 chars ~= 40 bits
# of entropy; combined with single-use + a short TTL below, that's plenty
# against network brute force -- the TTL is the real control, not the length.
# `set +o pipefail` inside the substitution only (same fix as install.sh's
# RECOVERY_PIN generation): head -c 8 closing early sends tr SIGPIPE, which
# pipefail would otherwise turn into a whole-script abort under set -e.
CODE=$(set +o pipefail; tr -dc 'ABCDEFGHJKMNPQRSTVWXYZ23456789' < /dev/urandom | head -c 8)
CODE_DISPLAY="${CODE:0:4}-${CODE:4:4}"

# TTL 900s (15 min): long enough for an admin to relay the code and the user
# to type it, short enough that a leaked/overheard code is worthless soon
# after. SETEX is a single atomic write -- no separate EXPIRE call. The
# config goes over stdin (-x), not argv: it holds the peer's private key.
redis -x SETEX "pair:${CODE}" "$CODE_TTL" < "$CONFIG_FILE" >/dev/null
CLIENT_PUB=$(awk '$1 == "PrivateKey" {print $3}' "$CONFIG_FILE" | wg pubkey)
CLIENT_IP=$(awk '$1 == "Address" {split($3, a, "/"); print a[1]}' "$CONFIG_FILE")
printf '%s %s %s' "$CLIENT_PUB" "$CLIENT_IP" "$(( $(date +%s) + CODE_TTL ))" \
    | redis -x SET "pairpending:${CODE}" >/dev/null

echo ""
echo "  ✓ Pairing code for '${PEER_NAME}': ${CODE_DISPLAY}"
echo "  ✓ Expires in 15 minutes, single use"
echo ""
echo "  On the Membrane's lock screen, use \"Pair with a Brain\" (gear-adjacent"
echo "  icon) and enter this code plus your enrollment host, e.g.:"
echo "    enroll.slimeos.com"
echo ""
