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

payload='{"hook_event_name":"on_user_prompt","session_id":"session-1","cwd":"/tmp","attributes":{"user_prompt":"Can you improve the Herdr agent names please?"}}'
printf '%s' "$payload" | env \
  PATH="$WORK/bin:$PATH" \
  HERDR_BIN_PATH="$WORK/bin/herdr" \
  HERDR_STUB_LOG="$LOG" \
  HERDR_ROVO_STATE_DIR="$WORK/state" \
  HERDR_PANE_ID="w1:p3" \
  HERDR_TAB_ID="w1:t3" \
  bash "$REPO_ROOT/bin/rovo-herdr-hook"

status=0
if ! grep -F "pane report-metadata w1:p3" "$LOG" | grep -Fq -- "--token task_name=improve Herdr agent"; then
  echo "FAIL: latest prompt should set the sidebar task_name token" >&2
  status=1
fi
if grep -Fq -- "--display-agent" "$LOG"; then
  echo "FAIL: task naming should not use the non-sidebar display-agent field" >&2
  status=1
fi
if grep -Fq "tab rename" "$LOG"; then
  echo "FAIL: prompt naming should not overwrite the Herdr tab name" >&2
  status=1
fi
if ! grep -F "pane report-agent w1:p3" "$LOG" | grep -Fq -- "--agent rovo-dev"; then
  echo "FAIL: lifecycle identity should remain rovo-dev" >&2
  status=1
fi

exit "$status"
