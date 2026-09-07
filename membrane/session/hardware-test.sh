#!/usr/bin/env bash
# Slime OS — Speaker / Microphone / Camera local test tabs
#
# `source`d by membrane/session/coordinator.sh, same shape as timezone.sh's
# do_timezone() and support.sh's do_support(): relies on coordinator.sh's own
# log()/emit_state()/read_event() helpers, and on the ALSA-card selection
# helpers default_playback_card()/usb_capture_card() from freerdp/connect.sh
# (already `source`d by coordinator.sh before this file). `mode` is always
# "settings" -- none of these three screens has a boot-mode variant, same as
# timezone.sh/support.sh.
#
# These tabs exist so a user can check speaker output, microphone capture,
# and the webcam *locally* -- entirely independent of any Brain/RDP
# connection -- so a hardware fault can be isolated before ever dialing in.
# Everything here runs unprivileged as $SESSION_USER: plain ALSA (amixer/
# aplay/arecord/speaker-test from alsa-utils) and a single-frame webcam grab
# (fswebcam). No sudo/polkit path -- contrast support.sh's root helper.
#
# This device family is pure ALSA (no PipeWire/PulseAudio -- confirmed live
# on the AMD box), so `amixer`/`arecord`/`aplay` talk to the kernel mixer
# directly. Playback and capture cards are picked the same way connect.sh
# picks them for RDP redirection (walk /proc/asound/cards in index order,
# skip a webcam's own mic in favour of a dedicated USB mic) so what a user
# tests here is exactly what a Brain session would use.

# Read the current volume percentage of a mixer control, or fail (1) if the
# control doesn't exist on this card. Tries $2 first, so callers can fall
# back to a second control name (Master -> PCM for playback, Capture -> Mic
# for capture) the same try-this-then-that way the rest of the codebase
# handles hardware variation. `amixer -c <card>` takes a card name OR index;
# default_playback_card()/usb_capture_card() return the name.
hw_mixer_get_pct() {
    local card="$1" ctl="$2" out
    out=$(amixer -c "$card" sget "$ctl" 2>/dev/null) || return 1
    # First "[NN%]" in amixer's output (it prints one per channel; they
    # track together for anything we set here). Bash regex, not a
    # grep|head|tr pipeline -- no pipefail/SIGPIPE surface.
    [[ "$out" =~ \[([0-9]{1,3})%\] ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

# Set a mixer control to a percentage, trying $2 then $3 (same fallback pair
# as hw_mixer_get_pct). Prints nothing; returns amixer's exit status.
hw_mixer_set_pct() {
    local card="$1" ctl_a="$2" ctl_b="$3" pct="$4"
    amixer -c "$card" sset "$ctl_a" "${pct}%" >/dev/null 2>&1 && return 0
    [[ -n "$ctl_b" ]] || return 1
    amixer -c "$card" sset "$ctl_b" "${pct}%" >/dev/null 2>&1
}

# The `plughw:` PCM string for local test playback -- the same output
# connect.sh routes a Brain's audio to (see playback_target() there), so
# "Test speaker" and the mic round-trip play where the user actually hears
# the Brain: a live HDMI/DisplayPort monitor's audio when there is one,
# otherwise the card's analog device. Prints nothing and returns 1 if no
# playback card exists at all.
hw_playback_pcm() {
    local pt dev
    pt=$(playback_target 2>/dev/null) || return 1
    dev=${pt#*|}
    if [[ -n "$dev" ]]; then
        printf 'plughw:CARD=%s,DEV=%s' "${pt%%|*}" "$dev"
    else
        printf 'plughw:CARD=%s' "${pt%%|*}"
    fi
}

# --- Device pickers (Speaker/Microphone/Camera "Device" dropdowns) ------
# Each tab lets the user pin an explicit device when detection guesses
# wrong (the webcam-mic-over-USB-dongle case). The choice persists to
# $DEVICE_PREFS_FILE (a shell KEY="value" fragment in $CRED_DIR, sourced by
# coordinator.sh after config -- same unprivileged-prefs mechanism as
# display-settings.sh) and is honoured by connect.sh's default_playback_card
# / mic_redirect_card and by this file's own resolvers below. Empty value =
# "Automatic".

# "<idx>\t<name>\t<longname>" for every ALSA card. <name> is the bracketed
# short id connect.sh keys on (what an override stores); <longname> is the
# human string after " - " on the card line, for the picker label.
hw_alsa_cards_tsv() {
    awk '
        /^[[:space:]]*[0-9]+[[:space:]]*\[/ {
            idx=$0;  sub(/[[:space:]]*\[.*/, "", idx);        gsub(/[[:space:]]/, "", idx)
            name=$0; sub(/^[^[]*\[/, "", name); sub(/\].*/, "", name); sub(/[[:space:]]+$/, "", name)
            desc=$0; sub(/^[^]]*\][[:space:]]*:[[:space:]]*/, "", desc)
            long=desc; if (long ~ / - /) sub(/^.* - /, "", long)
            print idx "\t" name "\t" long
        }
    ' /proc/asound/cards 2>/dev/null
}

# JSON array of {id,label} for every ALSA card exposing a $1-type substream
# ('p' playback / 'c' capture). "[]" when the box has none. Order matches
# /proc/asound/cards (i.e. the order connect.sh's heuristics walk).
hw_cards_json() {
    local kind="$1" idx name long first=1
    printf '['
    while IFS=$'\t' read -r idx name long; do
        compgen -G "/proc/asound/card${idx}/pcm*${kind}" >/dev/null || continue
        [[ -n "$long" ]] || long="$name"
        (( first )) || printf ','
        first=0
        jq -nc --arg id "$name" --arg label "$long" '{id:$id,label:$label}' | tr -d '\n'
    done < <(hw_alsa_cards_tsv)
    printf ']'
}

# JSON array of {id,label} for every /dev/video* node (id is the full path,
# label the driver's name from sysfs). UVC webcams expose a capture node
# and a metadata node -- both are listed; the first is normally the right
# one and stays the Automatic pick.
hw_video_devices_json() {
    local dev base name first=1
    printf '['
    for dev in /dev/video*; do
        [[ -e "$dev" ]] || continue
        base=${dev##*/}
        name=$(cat "/sys/class/video4linux/${base}/name" 2>/dev/null || true)
        [[ -n "$name" ]] || name="$base"
        (( first )) || printf ','
        first=0
        jq -nc --arg id "$dev" --arg label "$name" '{id:$id,label:$label}' | tr -d '\n'
    done
    printf ']'
}

# The capture card the Microphone tab shows and tests: an explicit
# MIC_CARD_OVERRIDE when set and still present, else the dedicated-USB-mic
# heuristic, else the first onboard capture card. Richer fallback than
# connect.sh's mic_redirect_card on purpose -- the tab always wants
# *something* to show, connect.sh prefers ALSA's own default over pinning
# an onboard card.
hw_mic_card() {
    if [[ -n "${MIC_CARD_OVERRIDE:-}" ]] && card_present_with "$MIC_CARD_OVERRIDE" c; then
        printf '%s' "$MIC_CARD_OVERRIDE"
        return 0
    fi
    usb_capture_card 2>/dev/null && return 0
    hw_first_capture_card 2>/dev/null
}

# The /dev/video* node the Camera preview should open: an explicit,
# still-present CAMERA_DEV_OVERRIDE, else the first node. (RDP webcam
# redirection exposes *every* node to the Brain and Windows picks, so this
# override only steers the local preview -- the tab's blurb says so.)
hw_cam_device() {
    if [[ -n "${CAMERA_DEV_OVERRIDE:-}" && -e "${CAMERA_DEV_OVERRIDE}" ]]; then
        printf '%s' "$CAMERA_DEV_OVERRIDE"
        return 0
    fi
    local d
    for d in /dev/video*; do
        [[ -e "$d" ]] && { printf '%s' "$d"; return 0; }
    done
    return 1
}

# Atomically rewrite $DEVICE_PREFS_FILE with all three override keys from
# the current environment (the caller has already updated whichever one
# changed). Same-dir temp + mv so a crash mid-write can't leave
# coordinator.sh sourcing a half file next boot. Mirrors dp_write_prefs()
# in display-settings.sh.
dev_write_prefs() {
    local tmp
    tmp=$(mktemp "${DEVICE_PREFS_FILE}.XXXXXX") || return 1
    {
        echo "# Slime OS — per-device overrides (Settings > Speaker / Microphone / Camera)."
        echo "# Managed by hardware-test.sh; an empty value means Automatic (detect)."
        echo "SPEAKER_CARD_OVERRIDE=\"${SPEAKER_CARD_OVERRIDE:-}\""
        echo "MIC_CARD_OVERRIDE=\"${MIC_CARD_OVERRIDE:-}\""
        echo "CAMERA_DEV_OVERRIDE=\"${CAMERA_DEV_OVERRIDE:-}\""
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$DEVICE_PREFS_FILE" || { rm -f "$tmp"; return 1; }
}

# Blocking read of one event line, but give up after $1 seconds and return 2
# so the caller can do periodic work (grab a webcam frame) between events.
# Return 1 on real EOF, same as coordinator.sh's read_event(). Used only by
# the camera preview loop below -- every other loop here wants the plain
# unbounded read_event().
hw_read_event_timeout() {
    local line rc=0
    # `|| rc=$?` so a non-zero read (timeout or EOF) doesn't trip `set -e`
    # -- same guarded-read posture as coordinator.sh's read_event().
    IFS= read -r -t "$1" line <&0 || rc=$?
    if (( rc == 0 )); then
        printf '%s' "$line"
        return 0
    fi
    # bash: a >128 exit status from `read` means the -t timeout elapsed;
    # anything else (typically 1) is EOF/closed stdin.
    (( rc > 128 )) && return 2
    return 1
}

do_speaker_settings() {
    local mode="$1"
    local error=""

    while true; do
        local card="" volume=""
        card=$(default_playback_card 2>/dev/null) || card=""
        if [[ -n "$card" ]]; then
            volume=$(hw_mixer_get_pct "$card" Master) \
                || volume=$(hw_mixer_get_pct "$card" PCM) \
                || volume=""
        fi

        emit_state speakerSettings "$(jq -nc --arg mode "$mode" --arg card "$card" \
            --arg volume "$volume" --arg selected "${SPEAKER_CARD_OVERRIDE:-}" \
            --argjson cards "$(hw_cards_json p)" --arg error "$error" \
            '{mode:$mode,
              card:(if $card == "" then null else $card end),
              cards:$cards,
              selected:(if $selected == "" then null else $selected end),
              volume:(if $volume == "" then null else ($volume | tonumber) end),
              error:(if $error == "" then null else $error end)}')"
        error=""

        local line ev_type
        line=$(read_event) || return 0
        ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
        case "$ev_type" in
            speakerVolumeSet)
                local want
                want=$(jq -r '.volume // empty' <<<"$line")
                if [[ -z "$card" ]]; then
                    error="No speaker was found on this device."
                    continue
                fi
                if ! [[ "$want" =~ ^[0-9]{1,3}$ ]] || (( want > 100 )); then
                    log "speakerVolumeSet rejected: '$want' not 0-100"
                    error="Couldn't set that volume."
                    continue
                fi
                log "Speaker volume -> ${want}% on card '$card'"
                if ! hw_mixer_set_pct "$card" Master PCM "$want"; then
                    log "amixer sset failed on card '$card'"
                    error="Couldn't change the speaker volume right now."
                fi
                ;;
            speakerDeviceSet)
                local want
                want=$(jq -r '.device // ""' <<<"$line")
                if [[ -n "$want" ]] && ! card_present_with "$want" p; then
                    log "speakerDeviceSet rejected: '$want' absent or has no playback stream"
                    error="That speaker isn't available."
                    continue
                fi
                SPEAKER_CARD_OVERRIDE="$want"
                if ! dev_write_prefs; then
                    log "speakerDeviceSet: failed to write $DEVICE_PREFS_FILE"
                    error="Couldn't save that choice. Try again."
                    continue
                fi
                log "Speaker device -> '${want:-automatic}'"
                ;;
            speakerTest)
                if [[ -z "$card" ]]; then
                    error="No speaker was found on this device."
                    continue
                fi
                local pcm
                pcm=$(hw_playback_pcm) || pcm="plughw:CARD=${card}"
                log "Speaker test tone on '$pcm'"
                local output exit_code
                set +e
                output=$(speaker-test -D "$pcm" -c2 -twav -l1 2>&1)
                exit_code=$?
                set -e
                if [[ $exit_code -ne 0 ]]; then
                    log "speaker-test failed (exit $exit_code): $output"
                    error="The test tone couldn't be played."
                fi
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

do_microphone_settings() {
    local mode="$1"
    local error="" test_result=""

    while true; do
        local card="" volume=""
        # hw_mic_card(): explicit MIC_CARD_OVERRIDE if still present, else
        # the dedicated-USB-mic heuristic, else the first onboard capture
        # card -- so the tab always has something to show/set even on a
        # webcam-only / onboard-only box.
        card=$(hw_mic_card) || card=""
        if [[ -n "$card" ]]; then
            volume=$(hw_mixer_get_pct "$card" Capture) \
                || volume=$(hw_mixer_get_pct "$card" Mic) \
                || volume=""
        fi

        emit_state microphoneSettings "$(jq -nc --arg mode "$mode" --arg card "$card" \
            --arg volume "$volume" --arg selected "${MIC_CARD_OVERRIDE:-}" \
            --argjson cards "$(hw_cards_json c)" \
            --arg error "$error" --arg testResult "$test_result" \
            '{mode:$mode,
              card:(if $card == "" then null else $card end),
              cards:$cards,
              selected:(if $selected == "" then null else $selected end),
              volume:(if $volume == "" then null else ($volume | tonumber) end),
              testing:false,
              testResult:(if $testResult == "" then null else $testResult end),
              error:(if $error == "" then null else $error end)}')"
        error=""
        test_result=""

        local line ev_type
        line=$(read_event) || return 0
        ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
        case "$ev_type" in
            micVolumeSet)
                local want
                want=$(jq -r '.volume // empty' <<<"$line")
                if [[ -z "$card" ]]; then
                    error="No microphone was found on this device."
                    continue
                fi
                if ! [[ "$want" =~ ^[0-9]{1,3}$ ]] || (( want > 100 )); then
                    log "micVolumeSet rejected: '$want' not 0-100"
                    error="Couldn't set that level."
                    continue
                fi
                log "Mic level -> ${want}% on card '$card'"
                if ! hw_mixer_set_pct "$card" Capture Mic "$want"; then
                    log "amixer sset (capture) failed on card '$card'"
                    error="Couldn't change the microphone level right now."
                fi
                ;;
            micDeviceSet)
                local want
                want=$(jq -r '.device // ""' <<<"$line")
                if [[ -n "$want" ]] && ! card_present_with "$want" c; then
                    log "micDeviceSet rejected: '$want' absent or has no capture stream"
                    error="That microphone isn't available."
                    continue
                fi
                MIC_CARD_OVERRIDE="$want"
                if ! dev_write_prefs; then
                    log "micDeviceSet: failed to write $DEVICE_PREFS_FILE"
                    error="Couldn't save that choice. Try again."
                    continue
                fi
                log "Microphone device -> '${want:-automatic}'"
                ;;
            micTest)
                if [[ -z "$card" ]]; then
                    error="No microphone was found on this device."
                    continue
                fi
                local play_card
                play_card=$(default_playback_card 2>/dev/null) || play_card=""
                if [[ -z "$play_card" ]]; then
                    error="Recorded fine, but there's no speaker to play it back on."
                    continue
                fi
                # Emit an interim "testing" state so the UI can show progress
                # while the ~3s record + playback runs synchronously below.
                emit_state microphoneSettings "$(jq -nc --arg mode "$mode" --arg card "$card" \
                    --arg volume "$volume" \
                    '{mode:$mode, card:$card,
                      volume:(if $volume == "" then null else ($volume | tonumber) end),
                      testing:true, testResult:null, error:null}')"
                local play_pcm
                play_pcm=$(hw_playback_pcm) || play_pcm="plughw:CARD=${play_card}"
                log "Mic test: record 3s from '$card', play back on '$play_pcm'"
                local tmp output exit_code
                tmp=$(mktemp /tmp/slimeos-mictest.XXXXXX.wav)
                set +e
                output=$(arecord -D "plughw:CARD=${card}" -f cd -d 3 -q "$tmp" 2>&1 \
                    && aplay -D "$play_pcm" -q "$tmp" 2>&1)
                exit_code=$?
                set -e
                rm -f "$tmp"
                if [[ $exit_code -ne 0 ]]; then
                    log "mic test failed (exit $exit_code): $output"
                    error="The microphone test didn't work."
                    test_result="error"
                else
                    test_result="ok"
                fi
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

# First ALSA card in index order that exposes a capture substream -- the
# onboard-mic fallback for the Microphone tab when usb_capture_card() finds
# nothing. Mirrors default_playback_card()'s structure (connect.sh), just
# looking for a "pcm*c" node instead of "pcm*p".
hw_first_capture_card() {
    local idx name
    while read -r idx name; do
        if compgen -G "/proc/asound/card${idx}/pcm*c" >/dev/null; then
            printf '%s' "$name"
            return 0
        fi
    done < <(awk '{gsub(/\[/, "", $2); print $1, $2}' /proc/asound/cards 2>/dev/null)
    return 1
}

# Stop a running `fswebcam --loop` preview process. Safe to call with an
# empty/stale pid. Kept out of do_camera_settings so every one of its
# return paths can tear the process down the same way (no traps used
# anywhere else in this file set).
hw_cam_kill() {
    local pid="$1"
    [[ -n "$pid" ]] || return 0
    kill "$pid" 2>/dev/null || :
    wait "$pid" 2>/dev/null || :
}

# True if $1 is a complete JPEG (ends with the FFD9 end-of-image marker) --
# guards against reading a frame `fswebcam --loop` is halfway through
# rewriting. `od` is coreutils, always present.
hw_frame_complete() {
    local f="$1" sz
    sz=$(stat -c%s "$f" 2>/dev/null) || return 1
    (( sz >= 4 )) || return 1
    [[ "$(od -An -tx1 -j $((sz - 2)) "$f" 2>/dev/null | tr -d ' \n')" == "ffd9" ]]
}

do_camera_settings() {
    local mode="$1"
    local error="" previewing="false" frame_data_url=""
    local have_tool="true" cam_pid="" framefile="/tmp/slimeos-camframe.$$.jpg"
    command -v fswebcam >/dev/null 2>&1 || have_tool="false"

    while true; do
        local available="false"
        compgen -G "/dev/video*" >/dev/null && available="true"
        # A camera that's present but has no snapshot tool installed yet
        # (already-provisioned devices predate fswebcam being in install.sh's
        # package list) reads as "unavailable" for preview purposes, with an
        # error explaining why rather than a silent dead button.
        if [[ "$available" == "true" && "$have_tool" == "false" && -z "$error" ]]; then
            error="Camera preview needs a component that isn't installed on this device yet."
        fi

        # fswebcam's loop process went away on its own (camera unplugged,
        # driver hiccup) -- surface it instead of showing a frozen frame.
        if [[ "$previewing" == "true" && -n "$cam_pid" ]] && ! kill -0 "$cam_pid" 2>/dev/null; then
            log "camera preview: fswebcam loop exited unexpectedly"
            hw_cam_kill "$cam_pid"; cam_pid=""; rm -f "$framefile"
            previewing="false"; frame_data_url=""
            [[ -n "$error" ]] || error="Lost the camera feed."
        fi

        emit_state cameraSettings "$(jq -nc --arg mode "$mode" \
            --argjson available "$available" --argjson previewing "$previewing" \
            --argjson devices "$(hw_video_devices_json)" --arg selected "${CAMERA_DEV_OVERRIDE:-}" \
            --arg frame "$frame_data_url" --arg error "$error" \
            '{mode:$mode, available:$available, previewing:$previewing,
              devices:$devices,
              selected:(if $selected == "" then null else $selected end),
              frameDataUrl:(if $frame == "" then null else $frame end),
              error:(if $error == "" then null else $error end)}')"
        error=""

        # While previewing, a single `fswebcam --loop 1` process (spawned on
        # cameraPreviewStart) holds the camera open and rewrites $framefile
        # once a second -- so the LED stays on and there's no per-frame
        # open/warm-up stutter, unlike grabbing a fresh fswebcam each tick.
        # This loop just re-reads that file ~1x/sec between events. Still ~1
        # fps: it's a "does the camera work" check, not a video pipe (WPE's
        # WebKit here is built without MediaStream, so <video> can't).
        local line ev_type rc=0
        if [[ "$previewing" == "true" ]]; then
            # `|| rc=$?` -- a non-zero return from the timeout read must not
            # trip `set -e` before we get to inspect it.
            line=$(hw_read_event_timeout 1) || rc=$?
            if (( rc == 1 )); then
                hw_cam_kill "$cam_pid"; rm -f "$framefile"
                return 0
            elif (( rc == 2 )); then
                # Tick: re-read the newest complete frame, if any.
                if [[ -s "$framefile" ]] && hw_frame_complete "$framefile"; then
                    local b64=""
                    set +e
                    b64=$(base64 -w0 "$framefile" 2>/dev/null)
                    set -e
                    [[ -n "$b64" ]] && frame_data_url="data:image/jpeg;base64,${b64}"
                fi
                continue
            fi
        else
            line=$(read_event) || { hw_cam_kill "$cam_pid"; rm -f "$framefile"; return 0; }
        fi

        ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
        case "$ev_type" in
            cameraPreviewStart)
                if [[ "$have_tool" == "false" ]]; then
                    error="Camera preview needs a component that isn't installed on this device yet."
                    continue
                fi
                if ! compgen -G "/dev/video*" >/dev/null; then
                    error="No camera was found on this device."
                    continue
                fi
                # Clear any prior process/file, then start the loop grabber
                # on the chosen (or first) /dev/video node.
                hw_cam_kill "$cam_pid"; cam_pid=""; rm -f "$framefile"
                local cam_dev
                cam_dev=$(hw_cam_device) || cam_dev="/dev/video0"
                set +e
                fswebcam -q -d "$cam_dev" -r 640x480 --no-banner --jpeg 80 \
                    --loop 1 "$framefile" >/dev/null 2>&1 &
                cam_pid=$!
                set -e
                previewing="true"
                frame_data_url=""
                ;;
            cameraPreviewStop)
                hw_cam_kill "$cam_pid"; cam_pid=""; rm -f "$framefile"
                previewing="false"
                frame_data_url=""
                ;;
            cameraDeviceSet)
                local want
                want=$(jq -r '.device // ""' <<<"$line")
                if [[ -n "$want" ]] && { [[ ! "$want" =~ ^/dev/video[0-9]+$ ]] || [[ ! -e "$want" ]]; }; then
                    log "cameraDeviceSet rejected: '$want' not a present /dev/video node"
                    error="That camera isn't available."
                    continue
                fi
                CAMERA_DEV_OVERRIDE="$want"
                if ! dev_write_prefs; then
                    log "cameraDeviceSet: failed to write $DEVICE_PREFS_FILE"
                    error="Couldn't save that choice. Try again."
                    continue
                fi
                # A running preview is on the old node -- drop it so the next
                # Start preview opens the newly chosen one.
                if [[ "$previewing" == "true" ]]; then
                    hw_cam_kill "$cam_pid"; cam_pid=""; rm -f "$framefile"
                    previewing="false"; frame_data_url=""
                fi
                log "Camera device -> '${want:-automatic}'"
                ;;
            settingsTab)
                [[ "$mode" == "settings" ]] || continue
                SETTINGS_NEXT_TAB=$(jq -r '.tab // empty' <<<"$line")
                if [[ -n "$SETTINGS_NEXT_TAB" ]]; then
                    hw_cam_kill "$cam_pid"; rm -f "$framefile"
                    return 0
                fi
                ;;
            back|forceBack)
                hw_cam_kill "$cam_pid"; rm -f "$framefile"
                return 0
                ;;
            *)
                try_handle_power_event "$ev_type" || :
                try_handle_crash_report "$ev_type" "$line" || :
                ;;
        esac
    done
}
