#!/usr/bin/env bash
# Slime OS — Connect screen
# The "Connect" path of the Membrane login screen: lets the user save one or
# more Brain IP addresses and pick which to connect to. This is the open
# source path (no Slime account required).
#
# "Sign in with Slime ID" (the managed-service path) is planned but not yet
# built — see docs/architecture.md.
#
# Launched by cage as its sole Wayland client. On first run it re-execs
# itself inside weston-terminal so whiptail has a tty to draw into; that
# terminal instance is what cage actually manages as its client.

set -euo pipefail

CONFIG_DIR="/etc/slimeos"
INSTALL_DIR="/opt/slimeos"
BRAINS_FILE="$CONFIG_DIR/brains.json"
CRED_DIR="$CONFIG_DIR/brains"
LOG_FILE="/var/log/slimeos-session.log"

log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [brain-select] $*" >> "$LOG_FILE"; }

# ── Become the Wayland client ────────────────────────────────────────────────
if [[ "${SLIMEOS_UI:-0}" != "1" ]]; then
    exec weston-terminal --fullscreen \
        --command="SLIMEOS_UI=1 exec $INSTALL_DIR/brain-select.sh"
fi

mkdir -p "$CRED_DIR"
chmod 700 "$CRED_DIR"
[[ -f "$BRAINS_FILE" ]] || echo '[]' > "$BRAINS_FILE"

add_brain() {
    local name host port id tmp
    name=$(whiptail --title "Slime OS — Add Brain" \
        --inputbox "Name this Brain (e.g. Home Office)" 10 60 3>&1 1>&2 2>&3) || return 0
    [[ -n "$name" ]] || return 0

    host=$(whiptail --title "Slime OS — Add Brain" \
        --inputbox "Brain IP address or hostname" 10 60 3>&1 1>&2 2>&3) || return 0
    [[ -n "$host" ]] || return 0

    port=$(whiptail --title "Slime OS — Add Brain" \
        --inputbox "RDP port" 10 60 "3389" 3>&1 1>&2 2>&3) || return 0
    port="${port:-3389}"

    id=$(cat /proc/sys/kernel/random/uuid)
    tmp=$(mktemp)
    jq --arg id "$id" --arg name "$name" --arg host "$host" --arg port "$port" \
        '. += [{id: $id, name: $name, host: $host, port: $port, username: ""}]' \
        "$BRAINS_FILE" > "$tmp" && mv "$tmp" "$BRAINS_FILE"
    log "Added brain '$name' ($host:$port) id=$id"
}

remove_brain() {
    local id="$1" tmp
    tmp=$(mktemp)
    jq --arg id "$id" 'map(select(.id != $id))' "$BRAINS_FILE" > "$tmp" && mv "$tmp" "$BRAINS_FILE"
    rm -f "$CRED_DIR/${id}.cred"
    log "Removed brain id=$id"
}

# ── Main menu loop ────────────────────────────────────────────────────────────
while true; do
    count=$(jq 'length' "$BRAINS_FILE")

    if [[ "$count" -eq 0 ]]; then
        whiptail --title "Slime OS" \
            --msgbox "Welcome to Slime OS.\n\nNo Brains saved yet — let's add one to connect to." 10 60
        add_brain
        continue
    fi

    menu_args=()
    while IFS=$'\t' read -r id name host; do
        menu_args+=("$id" "$name  ($host)")
    done < <(jq -r '.[] | [.id, .name, .host] | @tsv' "$BRAINS_FILE")
    menu_args+=("__add__" "+ Add new Brain")

    choice=$(whiptail --title "Slime OS — Connect" \
        --menu "Choose a Brain to connect to:" 20 70 10 \
        "${menu_args[@]}" 3>&1 1>&2 2>&3) || continue

    if [[ "$choice" == "__add__" ]]; then
        add_brain
        continue
    fi

    brain_name=$(jq -r --arg id "$choice" '.[] | select(.id == $id) | .name' "$BRAINS_FILE")
    action=$(whiptail --title "$brain_name" --menu "" 12 60 3 \
        "connect" "Connect" \
        "remove"  "Remove this Brain" \
        "back"    "Back" 3>&1 1>&2 2>&3) || continue

    case "$action" in
        connect)
            log "Connecting to brain id=$choice ($brain_name)"
            exec "$INSTALL_DIR/connect.sh" "$choice"
            ;;
        remove)
            whiptail --yesno "Remove '$brain_name'? This also deletes its saved password." 10 60 \
                && remove_brain "$choice"
            ;;
        *) continue ;;
    esac
done
