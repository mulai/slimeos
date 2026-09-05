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
            --arg volume "$volume" --arg error "$error" \
            '{mode:$mode,
              card:(if $card == "" then null else $card end),
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
            speakerTest)
                if [[ -z "$card" ]]; then
                    error="No speaker was found on this device."
                    continue
                fi
                log "Speaker test tone on card '$card'"
                local output exit_code
                set +e
                output=$(speaker-test -D "plughw:CARD=${card}" -c2 -twav -l1 2>&1)
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
        card=$(usb_capture_card 2>/dev/null) || card=""
        # usb_capture_card() only ever returns a USB capture card; fall back
        # to the onboard capture card the same index-order way connect.sh's
        # mic path implicitly does via ALSA's own default when no USB mic is
        # present. Here we make it explicit so the tab still has something to
        # show (and set) on a webcam-only / onboard-only box.
        [[ -n "$card" ]] || card=$(hw_first_capture_card 2>/dev/null) || card=""
        if [[ -n "$card" ]]; then
            volume=$(hw_mixer_get_pct "$card" Capture) \
                || volume=$(hw_mixer_get_pct "$card" Mic) \
                || volume=""
        fi

        emit_state microphoneSettings "$(jq -nc --arg mode "$mode" --arg card "$card" \
            --arg volume "$volume" --arg error "$error" --arg testResult "$test_result" \
            '{mode:$mode,
              card:(if $card == "" then null else $card end),
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
                log "Mic test: record 3s from '$card', play back on '$play_card'"
                local tmp output exit_code
                tmp=$(mktemp /tmp/slimeos-mictest.XXXXXX.wav)
                set +e
                output=$(arecord -D "plughw:CARD=${card}" -f cd -d 3 -q "$tmp" 2>&1 \
                    && aplay -D "plughw:CARD=${play_card}" -q "$tmp" 2>&1)
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
            --arg frame "$frame_data_url" --arg error "$error" \
            '{mode:$mode, available:$available, previewing:$previewing,
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
                # Clear any prior process/file, then start the loop grabber.
                hw_cam_kill "$cam_pid"; cam_pid=""; rm -f "$framefile"
                set +e
                fswebcam -q -d /dev/video0 -r 640x480 --no-banner --jpeg 80 \
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
