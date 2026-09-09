#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/state"
LOG="$WORK/herdr.log"

cat > "$WORK/bin/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_STUB_LOG"
exit 0
STUB
chmod +x "$WORK/bin/herdr"

run_hook() {
  local event="$1" session="$2"
  printf '{"hook_event_name":"%s","session_id":"%s","cwd":"/tmp","attributes":{}}' "$event" "$session" | env \
    PATH="$WORK/bin:$PATH" \
    HERDR_BIN_PATH="$WORK/bin/herdr" \
    HERDR_STUB_LOG="$LOG" \
    HERDR_ROVO_STATE_DIR="$WORK/state" \
    HERDR_PANE_ID="w1:p3" \
    HERDR_TAB_ID="w1:t3" \
    bash "$REPO_ROOT/bin/rovo-herdr-hook"
}

status=0
run_hook on_session_start session-1
run_hook on_user_prompt session-1
run_hook on_complete session-1

last_report="$(grep -F 'pane report-agent w1:p3' "$LOG" | tail -n1)"
if ! printf '%s' "$last_report" | grep -Fq -- '--state idle'; then
  echo "FAIL: completion should leave the agent idle" >&2
  status=1
fi
if ! grep -F "pane report-metadata w1:p3" "$LOG" | tail -n1 | grep -Fq -- '--state-label idle=done'; then
  echo "FAIL: completion should mark unseen work done" >&2
  status=1
fi

run_hook on_user_prompt session-2
last_report="$(grep -F 'pane report-agent w1:p3' "$LOG" | tail -n1)"
if ! printf '%s' "$last_report" | grep -Fq -- '--state working'; then
  echo "FAIL: a newer prompt should supersede the prior completion state" >&2
  status=1
fi
if ! printf '%s' "$last_report" | grep -Fq -- '--agent-session-id session-2'; then
  echo "FAIL: working state should belong to the newer session" >&2
  status=1
fi

exit "$status"
