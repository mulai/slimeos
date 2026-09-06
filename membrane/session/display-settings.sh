#!/usr/bin/env bash
# Slime OS — Display & Sound settings tab
#
# `source`d by membrane/session/coordinator.sh, same shape as timezone.sh's
# do_timezone(): relies on coordinator.sh's own log()/emit_state()/
# read_event()/send_status() helpers, and on compute_res_flags() +
# $DISPLAY_PREFS_FILE which coordinator.sh defines. `mode` is always
# "settings" -- there is no boot-mode variant of this screen.
#
# Three knobs, all persisted to $DISPLAY_PREFS_FILE (a shell KEY="value"
# fragment coordinator.sh sources after /etc/slimeos/config, so a choice
# made here wins over the admin default):
#
#   MEMBRANE_UI_SCALE   1 | 1.25 | 1.5 | 2   -- size of the Membrane's own
#       UI. Applied immediately as a CSS zoom by the page (send_status
#       carries it); no reconnect or restart. The fix for a Membrane
#       driving a 4K TV where 1:1 text is unreadably small.
#   RDP_WIDTH / RDP_HEIGHT   ""(auto/fullscreen) | 1920x1080 | 1280x720
#       -- the Brain session's resolution. compute_res_flags() rebuilds
#       RES_FLAGS from these; takes effect on the next connect.
#   AUDIO_OUTPUT   auto | analog | hdmi   -- where a Brain's sound goes
#       (see playback_target() in connect.sh). Next connect.
#
# Why the prefs file lives in $CRED_DIR and not next to /etc/slimeos/config:
# config is root:$SESSION_USER 0640 (admin-writable only), and the session
# runs unprivileged. $CRED_DIR is the one directory install.sh hands to
# $SESSION_USER outright (it already writes per-Brain .cred files there), so
# a write here needs no new sudo/polkit grant and works on every
# already-installed device, not just fresh 0.3.6+ ones.

# Allowed UI scales -- kept in lockstep with renderDisplaySettings() in
# index.html. "1" means "no zoom".
DP_SCALES=("1" "1.25" "1.5" "2")

# resolution id -> "WIDTH HEIGHT" ("" = fullscreen/auto). Order here is the
# order the <select> shows them.
dp_resolution_dims() {
    case "$1" in
        auto)      printf '' ;;
        1920x1080) printf '1920 1080' ;;
        1280x720)  printf '1280 720' ;;
        *)         return 1 ;;
    esac
}

# Current resolution id derived from the live RDP_WIDTH/RDP_HEIGHT.
dp_current_resolution() {
    case "${RDP_WIDTH:-}x${RDP_HEIGHT:-}" in
        1920x1080) printf '1920x1080' ;;
        1280x720)  printf '1280x720' ;;
        *)         printf 'auto' ;;
    esac
}

# JSON array of the sound-output ids that make sense on this hardware:
# always auto + analog; hdmi only when the card playback_target() would
# pick actually carries an HDMI/DP output (so the option isn't offered on
# a box whose speakers are a separate analog-only card, e.g. the AMD box).
dp_audio_outputs_json() {
    local card
    card=$(default_playback_card 2>/dev/null) || card=""
    if [[ -n "$card" ]] && aplay -l 2>/dev/null | grep -q ": $card \[.*], device .*: HDMI "; then
        printf '["auto","analog","hdmi"]'
    else
        printf '["auto","analog"]'
    fi
}

dp_in_list() {
    local needle="$1"; shift
    local x
    for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
    return 1
}

# Atomically rewrite $DISPLAY_PREFS_FILE with the four keys. Same-dir temp
# + mv so a crash mid-write can't leave coordinator.sh sourcing a half
# file on the next boot. Returns non-zero (and writes nothing) on failure.
dp_write_prefs() {
    local scale="$1" res_w="$2" res_h="$3" audio="$4" tmp
    tmp=$(mktemp "${DISPLAY_PREFS_FILE}.XXXXXX") || return 1
    {
        echo "# Slime OS — Display & Sound preferences (Settings > Display & Sound)."
        echo "# Managed by display-settings.sh; hand-editing is fine but will be"
        echo "# overwritten the next time the tab saves."
        echo "MEMBRANE_UI_SCALE=\"${scale}\""
        echo "RDP_WIDTH=\"${res_w}\""
        echo "RDP_HEIGHT=\"${res_h}\""
        echo "AUDIO_OUTPUT=\"${audio}\""
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$DISPLAY_PREFS_FILE" || { rm -f "$tmp"; return 1; }
}

do_display_settings() {
    local mode="$1"
    local error=""

    while true; do
        local scale="${MEMBRANE_UI_SCALE:-1}"
        dp_in_list "$scale" "${DP_SCALES[@]}" || scale="1"
        local resolution audio outputs_json
        resolution=$(dp_current_resolution)
        audio="${AUDIO_OUTPUT:-auto}"
        outputs_json=$(dp_audio_outputs_json)
        # Fall back cleanly if a stale prefs file names an output this
        # hardware can't do (e.g. moved between boxes).
        grep -q "\"$audio\"" <<<"$outputs_json" || audio="auto"

        emit_state displaySettings "$(jq -nc \
            --arg mode "$mode" --arg scale "$scale" --arg resolution "$resolution" \
            --arg audio "$audio" --argjson outputs "$outputs_json" \
            --arg error "$error" \
            '{mode:$mode, uiScale:$scale, resolution:$resolution,
              audioOutput:$audio, audioOutputs:$outputs,
              error:(if $error == "" then null else $error end)}')"
        error=""

        local line ev_type
        line=$(read_event) || return 0
        ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
        case "$ev_type" in
            displaySet)
                local want_scale want_res want_audio res_dims res_w res_h
                want_scale=$(jq -r '.uiScale // empty' <<<"$line")
                want_res=$(jq -r '.resolution // empty' <<<"$line")
                want_audio=$(jq -r '.audioOutput // empty' <<<"$line")

                if ! dp_in_list "$want_scale" "${DP_SCALES[@]}"; then
                    log "displaySet rejected: uiScale '$want_scale'"
                    error="Couldn't apply that display size."
                    continue
                fi
                if ! res_dims=$(dp_resolution_dims "$want_res"); then
                    log "displaySet rejected: resolution '$want_res'"
                    error="Couldn't apply that resolution."
                    continue
                fi
                if ! grep -q "\"$want_audio\"" <<<"$(dp_audio_outputs_json)"; then
                    log "displaySet rejected: audioOutput '$want_audio'"
                    error="That sound output isn't available on this device."
                    continue
                fi
                res_w="${res_dims% *}"; res_h="${res_dims#* }"
                [[ -n "$res_dims" ]] || { res_w=""; res_h=""; }

                if ! dp_write_prefs "$want_scale" "$res_w" "$res_h" "$want_audio"; then
                    log "displaySet: failed to write $DISPLAY_PREFS_FILE"
                    error="Couldn't save the change. Try again."
                    continue
                fi

                # Make the running coordinator see the new values now:
                # MEMBRANE_UI_SCALE / AUDIO_OUTPUT are read live on the next
                # send_status / connect, RES_FLAGS is rebuilt here.
                MEMBRANE_UI_SCALE="$want_scale"
                RDP_WIDTH="$res_w"
                RDP_HEIGHT="$res_h"
                AUDIO_OUTPUT="$want_audio"
                compute_res_flags
                log "Display & Sound: uiScale=$want_scale resolution=${want_res} audioOutput=$want_audio"
                # Pushes the new uiScale to the page (it zooms immediately);
                # same explicit-send reasoning as timezone.sh's clock.
                send_status
                ;;
            settingsTab)
                [[ "$mode" == "settings" ]] || continue
                SETTINGS_NEXT_TAB=$(jq -r '.tab // empty' <<<"$line")
                [[ -n "$SETTINGS_NEXT_TAB" ]] && return 0
                ;;
            back) return 0 ;;
            forceBack) return 0 ;;
            *)
                try_handle_power_event "$ev_type" || :
                try_handle_crash_report "$ev_type" "$line" || :
                ;;
        esac
    done
}
