#!/bin/bash
# Auto-reconnect wrapper for moonlight-embedded.
# moonlight-embedded has no built-in reconnect (unlike FreeRDP's +auto-reconnect) -
# it just exits on any disconnect: a Sunshine-side session-state restart (lock/login),
# or a mid-stream packet-loss disconnect. This restarts it with backoff until a stop
# file appears, so a transient disconnect resumes on its own instead of staying dead.
#
# Usage: moonlight-supervisor.sh <host> <app> [extra moonlight args...]

HOST="$1"; APP="$2"; shift 2
STOPFILE="/tmp/moonlight-supervisor.stop"
LOGFILE="/tmp/moonlight-supervisor.log"
MAX_RETRIES=20
BACKOFF=2

rm -f "$STOPFILE"
: > "$LOGFILE"
attempt=0
while [ ! -f "$STOPFILE" ] && [ $attempt -lt $MAX_RETRIES ]; do
  attempt=$((attempt+1))
  start_ts=$(date '+%H:%M:%S')
  echo "[$start_ts] Attempt $attempt: starting moonlight stream $HOST -app $APP $*" >> "$LOGFILE"
  /usr/local/bin/moonlight stream "$HOST" -app "$APP" "$@" >> "$LOGFILE" 2>&1
  code=$?
  end_ts=$(date '+%H:%M:%S')
  echo "[$end_ts] Attempt $attempt: moonlight exited with code $code" >> "$LOGFILE"
  if [ -f "$STOPFILE" ]; then
    echo "[$end_ts] Stop file present, not retrying" >> "$LOGFILE"
    break
  fi
  echo "[$end_ts] Reconnecting in ${BACKOFF}s..." >> "$LOGFILE"
  sleep $BACKOFF
done
echo "[$(date '+%H:%M:%S')] Supervisor exiting after $attempt attempt(s)" >> "$LOGFILE"
