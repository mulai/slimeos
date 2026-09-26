#!/usr/bin/env bash
# Slime OS — privileged update-apply helper (root)
#
# Invoked as `apply-update-helper.sh` with NO arguments, via `sudo -n` by
# membrane/session/update.sh's do_apply_update() (running unprivileged, as
# $SESSION_USER). /etc/sudoers.d/51-slimeos-update scopes the NOPASSWD
# grant to exactly this one script -- same precedent as
# remote-support-toggle.sh.
#
# Downloads and verifies EVERYTHING ITSELF, as root, into a fresh root-only
# directory (#39). Until 0.3.45 the session user downloaded + checked the
# files into its own /etc/slimeos/update-staging and this script installed
# whatever was there, so any code running as the session user could plant
# files and have them installed as root. Nothing the session user can write
# is read here any more: the manifest URL is hardcoded, and every file
# (dest-map.txt included) must match the manifest's sha256 before use.
#
# The manifest itself is signed (#39 step 2): manifest.json.sig next to it,
# made with `ssh-keygen -Y sign` by membrane/update/sign-manifest.sh on the
# maintainer's machine. The keys allowed to sign are pinned below in
# RELEASE_SIGNERS, in this root-only file, so a new key can only arrive
# through an update the current keys signed. An unsigned manifest is
# refused. (0.3.49 only checked a signature if one was there, so the first
# signed release could land through the old helper.)
#
# Exit codes read by update.sh: 3 = couldn't download/verify (retry later),
# 4 = the manifest isn't newer than what's installed. A line starting with
# "[apply-update] verified" on stdout means every file checked out and the
# install is starting (update.sh shows the reboot overlay on it).
#
# Since 0.3.45 this script and update.sh are ordinary manifest/dest-map
# entries: the helper already on a device installs the next one, so the
# "v1 can't update itself" limit below only applies to the sudoers grant.
#
# Destination mapping is READ FROM STAGED DATA (dest-map.txt, part of the
# regular bundle, see membrane/update/dest-map.txt), not hardcoded --
# real incident, 2026-08-16 (v0.3.0): a hardcoded bash array here meant
# adding changelog.sh to the bundle required this script's own CODE to
# change, but this script is deliberately excluded from the auto-update
# manifest (same "v1 can't update itself" limitation as update.sh) -- so
# every already-provisioned device kept running its OLD, frozen array,
# silently never copying the new file into place even though it was
# correctly downloaded and verified into staging. coordinator.sh (which
# DOES update normally) shipped a `source changelog.sh` line pointing at a
# file that never arrived -- crash-looped every 2s on both the UTM VM and
# the AMD box. Moving the MAPPING (not the copy logic) into the same
# generic, checksummed staging pipeline every other file already goes
# through means a future new file only ever needs a new line in
# dest-map.txt, which flows to every device automatically. Checksum
# verification (fetch_verified, below) only ever covers file
# CONTENT, never where a file claims it should go -- now that the mapping
# itself is untrusted data, DEST_SAFE below is the thing that closes that
# gap: any `dest` containing `..` or starting with `/` is rejected outright,
# so a bad dest-map.txt can corrupt what gets installed but never *where*
# it lands (still confined under $INSTALL_DIR).
#
# File replacement uses `install` (unlink + recreate, i.e. rename
# semantics) rather than in-place truncation: both coordinator.sh
# (currently being interpreted by this script's own calling process) and
# the running slimeos-bridge binary keep executing their already-open
# inode after this runs, same guarantee any Unix package manager relies on.
#
# Applies via a full reboot rather than individually restarting
# slimeos-session.service/slimeos-bridge.service: this script runs as a
# descendant of slimeos-bridge.service's own cgroup (sudo'd from
# coordinator.sh, itself a child of the bridge), so restarting THAT service
# first would SIGTERM this script before it could also restart the session
# service -- KillMode=control-group is the systemd default and neither unit
# overrides it. Reboot sidesteps the ordering hazard entirely and reuses
# the already-proven boot/Plymouth path instead of inventing a live
# two-service bounce (cog/WPE only ever reads index.html once at process
# start regardless, so a session restart is unavoidable for UI changes no
# matter which path is taken).
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
[[ $# -eq 0 ]] || { echo "usage: $0 (no arguments)" >&2; exit 2; }

REPO_BASE="https://raw.githubusercontent.com/mulai/slimeos/main"
MANIFEST_URL="$REPO_BASE/membrane/update/manifest.json"
INSTALL_DIR="/opt/slimeos"
CONFIG_DIR="/etc/slimeos"
PREVIOUS_DIR="$CONFIG_DIR/update-previous"
# Session-user-owned staging dir from before 0.3.45. Never read; removed.
LEGACY_STAGING_DIR="$CONFIG_DIR/update-staging"

# allowed_signers format (ssh-keygen(1) ALLOWED SIGNERS). Primary key on the
# maintainer's Mac, backup key offline. sign-manifest.sh reads these lines
# back out of this file, so keep each on one line starting "release@slimeos".
REQUIRE_SIGNATURE=true
SIGNER_ID="release@slimeos"
SIG_NAMESPACE="slimeos-update"
RELEASE_SIGNERS=$(cat <<'SIGNERS'
release@slimeos namespaces="slimeos-update" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII2jAGOaJjWF2XwvZ1xZGhmNI0OSe7PHxH+eboqZIVZp slimeos-release-primary
release@slimeos namespaces="slimeos-update" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB6PpDXPJ++m9NoOM32Ow/Oahc+HabEFwKNy0pLscx0Y slimeos-release-backup
SIGNERS
)

fail() { echo "[apply-update] $*" >&2; exit 3; }

# Same X.Y.Z compare as update.sh's. Returns 0 if $1 > $2.
version_gt() {
    local a="$1" b="$2" i an bn
    local -a av bv
    IFS='.' read -r -a av <<<"$a"
    IFS='.' read -r -a bv <<<"$b"
    for i in 0 1 2; do
        an="${av[$i]:-0}"; bn="${bv[$i]:-0}"
        (( 10#$an > 10#$bn )) && return 0
        (( 10#$an < 10#$bn )) && return 1
    done
    return 1
}

rm -rf "${LEGACY_STAGING_DIR:?}" 2>/dev/null || true

# mktemp -d under root-owned /var/lib: created 0700 root, a fresh name
# every run, so nothing can be pre-planted in it.
STAGING_DIR=$(mktemp -d /var/lib/slimeos-update.XXXXXX)
trap 'rm -rf "$STAGING_DIR"' EXIT

# Saved to a file, not a variable: the signature covers the exact bytes.
curl -fsS -m 15 "$MANIFEST_URL" -o "$STAGING_DIR/manifest.json" || fail "manifest fetch failed"
sig_status=$(curl -sS -m 15 -o "$STAGING_DIR/manifest.json.sig" -w '%{http_code}' "$MANIFEST_URL.sig") || fail "signature fetch failed"
case "$sig_status" in
    200)
        printf '%s\n' "$RELEASE_SIGNERS" > "$STAGING_DIR/allowed_signers"
        ssh-keygen -Y verify -f "$STAGING_DIR/allowed_signers" -I "$SIGNER_ID" -n "$SIG_NAMESPACE" \
            -s "$STAGING_DIR/manifest.json.sig" < "$STAGING_DIR/manifest.json" >/dev/null 2>&1 \
            || fail "manifest signature is not valid"
        echo "[apply-update] manifest signature ok"
        ;;
    404)
        $REQUIRE_SIGNATURE && fail "manifest is not signed"
        echo "[apply-update] WARNING: manifest is not signed (accepted until signatures are required)" >&2
        ;;
    *) fail "signature fetch failed (HTTP $sig_status)" ;;
esac
manifest=$(<"$STAGING_DIR/manifest.json")
remote_version=$(jq -r '.version // empty' <<<"$manifest" 2>/dev/null) || remote_version=""
[[ "$remote_version" =~ ^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$ ]] || fail "manifest has no valid version"
local_version=$(cat "$CONFIG_DIR/version" 2>/dev/null || echo "0.0.0")
if ! version_gt "$remote_version" "$local_version"; then
    echo "[apply-update] manifest $remote_version is not newer than installed $local_version" >&2
    exit 4
fi

# Downloads $1 (a path under membrane/ in the repo) to $3 and checks it
# against sha256 $2. Staged by basename, same as update.sh always did.
fetch_verified() {
    local src="$1" sha="$2" out="$3"
    [[ "$src" =~ ^[A-Za-z0-9._/-]+$ && "$src" != *..* && "$src" != /* ]] || fail "unsafe path in manifest: $src"
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || fail "bad sha256 for $src"
    curl -fsS -m 120 "$REPO_BASE/membrane/$src" -o "$out" || fail "download failed for $src"
    echo "$sha  $out" | sha256sum -c - >/dev/null 2>&1 || fail "checksum mismatch for $src"
}

echo "[apply-update] downloading $remote_version"
while IFS=$'\t' read -r src sha256; do
    [[ -z "$src" ]] && continue
    fetch_verified "$src" "$sha256" "$STAGING_DIR/$(basename "$src")"
done < <(jq -r '.files[] | [.src, .sha256] | @tsv' <<<"$manifest")

bridge_arch=$(dpkg --print-architecture)
bridge_src=$(jq -r --arg a "$bridge_arch" '.bridge[$a].src // empty' <<<"$manifest")
bridge_sha=$(jq -r --arg a "$bridge_arch" '.bridge[$a].sha256 // empty' <<<"$manifest")
[[ -n "$bridge_src" ]] || fail "no bridge binary listed for arch $bridge_arch"
fetch_verified "$bridge_src" "$bridge_sha" "$STAGING_DIR/slimeos-bridge"

# Never executed, only copied into $CONFIG_DIR below.
echo "$remote_version" > "$STAGING_DIR/version"
jq -r '.changelog // ""' <<<"$manifest" > "$STAGING_DIR/changelog" || true
jq -r '.released_at // ""' <<<"$manifest" > "$STAGING_DIR/changelog-released-at" || true

[[ -f "$STAGING_DIR/dest-map.txt" ]] || fail "manifest lists no dest-map.txt -- refusing to guess destinations"
echo "[apply-update] verified $remote_version, installing"

# Build the name -> destination map from staged, just-verified data.
# Both fields are validated before either is trusted with anything -- name
# is used to locate the STAGED source file ($STAGING_DIR/$name), dest the
# INSTALLED destination ($INSTALL_DIR/$dest), so both need the same
# "must be a plain relative path, no traversal" guard, not just dest.
# Reject outright rather than merely warn: a rejected entry just means
# that one file doesn't get copied this round (caught immediately by a
# human watching this output), not a silent wrong-location read or write.
declare -A DEST_FOR=()
while IFS=: read -r name dest; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    if [[ -z "$dest" || "$name" == /* || "$name" == *..* || "$dest" == /* || "$dest" == *..* ]]; then
        echo "[apply-update] REJECTED unsafe dest-map.txt entry: $name -> $dest" >&2
        continue
    fi
    DEST_FOR["$name"]="$INSTALL_DIR/$dest"
done < "$STAGING_DIR/dest-map.txt"
[[ ${#DEST_FOR[@]} -gt 0 ]] || { echo "dest-map.txt parsed to zero safe entries" >&2; exit 1; }

echo "[apply-update] snapshotting current bundle to $PREVIOUS_DIR (rescue-mode restore target only, no automatic rollback)"
rm -rf "$PREVIOUS_DIR"
mkdir -p "$PREVIOUS_DIR"
for name in "${!DEST_FOR[@]}"; do
    src="${DEST_FOR[$name]}"
    [[ -f "$src" ]] && cp -p "$src" "$PREVIOUS_DIR/$name"
done

echo "[apply-update] applying staged files"
applied_any=false
hw_profile_changed=false
for name in "${!DEST_FOR[@]}"; do
    staged="$STAGING_DIR/$name"
    [[ -f "$staged" ]] || continue
    dest="${DEST_FOR[$name]}"
    mkdir -p "$(dirname "$dest")"
    case "$name" in
        apply-update-helper.sh) mode=0700 ;;
        *.sh|slimeos-bridge) mode=0755 ;;
        *) mode=0644 ;;
    esac
    install -m "$mode" -o root -g root "$staged" "$dest"
    applied_any=true
    [[ "$dest" == "$INSTALL_DIR/hardware-profiles/"* ]] && hw_profile_changed=true
done

if ! $applied_any; then
    echo "[apply-update] nothing staged, aborting without touching version or rebooting" >&2
    exit 1
fi

# hardware-profiles/*.sh are ordinary bundle entries like everything else
# above, but a profile change only takes effect once detect.sh re-runs and
# re-sources the matched profile -- detect.sh is explicitly documented as
# idempotent and safe to call from here (see its own header comment).
if $hw_profile_changed; then
    echo "[apply-update] hardware-profiles changed -- re-running detect.sh"
    bash "$INSTALL_DIR/hardware-profiles/detect.sh" || echo "[apply-update] WARNING: detect.sh failed, keeping previous profile" >&2
fi

# Purely informational (see changelog.sh's Settings tab) -- doesn't gate
# anything the way version below does, but written here, before version,
# so version stays the true "did this fully land" marker either way.
if [[ -f "$STAGING_DIR/changelog" ]]; then
    install -m 0644 -o root -g root "$STAGING_DIR/changelog" "$CONFIG_DIR/changelog"
fi
if [[ -f "$STAGING_DIR/changelog-released-at" ]]; then
    install -m 0644 -o root -g root "$STAGING_DIR/changelog-released-at" "$CONFIG_DIR/changelog-released-at"
fi

# Written last, only after every file above has landed -- a helper that
# dies partway through the loop above never advances this, so the next
# _updateTick's do_update_check() sees the still-old version and retries
# the whole cycle from scratch (idempotent, self-healing).
if [[ -f "$STAGING_DIR/version" ]]; then
    install -m 0644 -o root -g root "$STAGING_DIR/version" "$CONFIG_DIR/version"
fi

echo "[apply-update] rebooting to complete the update"
systemctl reboot
