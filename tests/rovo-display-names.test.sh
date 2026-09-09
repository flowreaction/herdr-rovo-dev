#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/state" "$WORK/sessions/session-1"
LOG="$WORK/herdr.log"

cat > "$WORK/bin/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_STUB_LOG"
exit 0
STUB
chmod +x "$WORK/bin/herdr"

cat > "$WORK/sessions/session-1/metadata.json" <<'JSON'
{"title":"Agent Display Names","is_manual_title":false}
JSON

run_hook() {
  local payload="$1" pane_id="$2" tab_id="$3"
  printf '%s' "$payload" | env \
    PATH="$WORK/bin:$PATH" \
    HERDR_BIN_PATH="$WORK/bin/herdr" \
    HERDR_STUB_LOG="$LOG" \
    HERDR_ROVO_STATE_DIR="$WORK/state" \
    ROVO_SESSIONS_DIR="$WORK/sessions" \
    HERDR_PANE_ID="$pane_id" \
    HERDR_TAB_ID="$tab_id" \
    ROVO_SETTLE_TIMEOUT=0 \
    bash "$REPO_ROOT/bin/rovo-herdr-hook"
}

status=0
run_hook '{"hook_event_name":"on_session_start","session_id":"session-1","cwd":"/tmp","attributes":{}}' "w1:p3" "w1:t3"
if ! grep -F "pane report-metadata w1:p3" "$LOG" | grep -Fq -- "--source plugin:rovo-dev:title"; then
  echo "FAIL: title metadata should use a source separate from lifecycle state" >&2
  status=1
fi
if ! grep -F "pane report-metadata w1:p3" "$LOG" | grep -Fq -- "--display-agent Agent Display Names"; then
  echo "FAIL: restored session should replace the visible agent name" >&2
  status=1
fi
if ! grep -Fq "tab rename w1:t3 Agent Display Names" "$LOG"; then
  echo "FAIL: restored session should rename its tab" >&2
  status=1
fi

cat > "$WORK/sessions/session-1/metadata.json" <<'JSON'
{"title":"Updated Semantic Session Title","is_manual_title":false}
JSON
run_hook '{"hook_event_name":"on_complete","session_id":"session-1","cwd":"/tmp","attributes":{}}' "w1:p3" "w1:t3"
if ! grep -F "pane report-metadata w1:p3" "$LOG" | grep -Fq -- "--display-agent Updated Semantic Session Title"; then
  echo "FAIL: completion should refresh the visible agent name" >&2
  status=1
fi
if ! grep -Fq "tab rename w1:t3 Updated Semantic Session Title" "$LOG"; then
  echo "FAIL: completion should refresh the tab name" >&2
  status=1
fi

run_hook '{"hook_event_name":"on_session_start","session_id":"session-2","cwd":"/tmp","attributes":{}}' "w1:p4" "w1:t4"
if ! grep -F "pane report-metadata w1:p4" "$LOG" | grep -Fq -- "--display-agent Rovo Dev"; then
  echo "FAIL: sessions without a title should keep a visible fallback" >&2
  status=1
fi
if grep -Fq "tab rename w1:t4" "$LOG"; then
  echo "FAIL: missing semantic titles should not overwrite tab names" >&2
  status=1
fi

exit "$status"
