#!/usr/bin/env bash
#
# Regression tests for the Rovo lifecycle hook (bin/rovo-herdr-hook) driving
# the real hook event sequence end-to-end against a fake `herdr` binary.
#
# Live symptom this locks in a fix for: in a fresh pane, `acli rovodev run`
# starts unknown; the first prompt activates hooks; on a simple no-tool
# response, Herdr reports idle/done via the on_complete hook while the Rovo
# TUI still visibly says "Rovo Dev is thinking" - the final response renders
# several seconds later. A backend polling Herdr for "done" then reads a
# still-partial pane. Two things must hold:
#
#   1. on_complete must not synchronously report idle/done - it must hand off
#      to an async settle step that only reports once the pane's own rendered
#      output actually stops looking like it's still working, not on a blind
#      timer.
#   2. Hook ownership (the "this pane is hook-active" marker) must be
#      established before the FIRST externally-visible state report for a
#      pane, so scan-rovo-panes' scraping fallback can never race in and
#      re-derive/clobber state during the ownership hand-off window.
#   3. A late settle from a superseded prompt must never clobber a newer
#      prompt's already-correct "working" state.
#   4. Only an actual "idle" reading can trigger the completion report -
#      "working"/"unknown" keep polling (bounded), but "blocked" or
#      exhausting the poll budget without ever observing idle must both
#      leave the last hook-reported state alone rather than guessing done.
#
# No real Herdr server (or the captain's session) is ever touched.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- tiny assertion helpers (mirrors report-agent.test.sh) ------------------
TESTS_RUN=0
TESTS_FAILED=0

fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "  FAIL: $1" >&2
  [ -n "${2:-}" ] && echo "        $2" >&2
}

check() { # <condition-rc> <description> [detail]
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$1" -eq 0 ]; then
    echo "  ok: $2"
  else
    fail "$2" "${3:-}"
  fi
}

assert_contains() { # <haystack-file> <needle> <description>
  if grep -Fq -- "$2" "$1" 2>/dev/null; then check 0 "$3"; else
    check 1 "$3" "expected to find: $2 in:\n$(cat "$1" 2>/dev/null)"
  fi
}

assert_absent() { # <haystack-file> <needle> <description>
  if grep -Fq -- "$2" "$1" 2>/dev/null; then
    check 1 "$3" "did NOT expect to find: $2 in:\n$(cat "$1" 2>/dev/null)"
  else check 0 "$3"; fi
}

# Wait (bounded) until <needle> appears in <haystack-file>, polling quickly.
# Prints 0 (found) or 1 (timed out) to stdout via return code.
wait_for() { # <haystack-file> <needle> <timeout-seconds>
  local file="$1" needle="$2" timeout="${3:-2}" waited=0 step="0.05"
  local iterations
  iterations=$(awk -v t="$timeout" -v s="$step" 'BEGIN{printf "%d", (t/s)+1}')
  local i=0
  while [ "$i" -lt "$iterations" ]; do
    grep -Fq -- "$needle" "$file" 2>/dev/null && return 0
    sleep "$step"
    i=$((i + 1))
  done
  grep -Fq -- "$needle" "$file" 2>/dev/null
}

# --- fake herdr + fresh env per test ----------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STUB="$WORK/bin/herdr"
mkdir -p "$WORK/bin"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
# Fake herdr: records every invocation, serves a controllable `pane read`
# screen buffer (so classify_state sees whatever the test wants Rovo's TUI to
# currently look like), and - for `pane report-agent` calls only - records
# whether this pane's hook-ownership marker file already exists at the
# moment of the call, so tests can catch a report landing before ownership
# is established.
printf '%s\n' "$*" >> "$HERDR_STUB_LOG"

if [ "${1:-}" = "pane" ] && [ "${2:-}" = "read" ]; then
  cat "${HERDR_STUB_SCREEN:-/dev/null}" 2>/dev/null
  exit 0
fi

if [ "${1:-}" = "pane" ] && [ "${2:-}" = "report-agent" ]; then
  pane_id="${3:-}"
  marker="${HERDR_ROVO_STATE_DIR:-}/hooked/$(printf '%s' "$pane_id" | tr '/' '_')"
  if [ -e "$marker" ]; then
    echo "MARKER:present $pane_id" >> "${HERDR_STUB_MARKER_LOG:-/dev/null}"
  else
    echo "MARKER:absent $pane_id" >> "${HERDR_STUB_MARKER_LOG:-/dev/null}"
  fi
fi

exit 0
STUB_EOF
chmod +x "$STUB"

export HERDR_ROVO_STATE_DIR="$WORK/state"
export HERDR_BIN_PATH="$STUB"
export HERDR_STUB_SCREEN="$WORK/screen.txt"
export HERDR_STUB_MARKER_LOG="$WORK/markers.log"
: > "$HERDR_STUB_MARKER_LOG"

# Keep settling fast and deterministic for tests without relying on a blind
# sleep in the code under test - the hook's own poll cadence is what's under
# test, so tune it down rather than stubbing it out.
export ROVO_SETTLE_POLL_INTERVAL="0.03"
export ROVO_SETTLE_MAX_ITERATIONS="60"

reset_stub() {
  HERDR_STUB_LOG="$WORK/calls.log"
  : > "$HERDR_STUB_LOG"
  export HERDR_STUB_LOG
}

thinking_screen() { printf 'Rovo Dev is thinking..\nEsc to interrupt\n' > "$HERDR_STUB_SCREEN"; }
idle_screen() { printf '> agent mode: default\n? for shortcuts\n' > "$HERDR_STUB_SCREEN"; }
unknown_screen() { printf 'garbled render buffer\n' > "$HERDR_STUB_SCREEN"; } # matches none of classify_state's patterns
blocked_screen() { printf 'Do you want to proceed? [y/n]\n' > "$HERDR_STUB_SCREEN"; }

run_hook() { # <event_name> <session_id> <pane_id>
  local event="$1" session="$2" pane="$3"
  local json
  json="$(printf '{"hook_event_name":"%s","session_id":"%s","cwd":"/work"}' "$event" "$session")"
  printf '%s' "$json" | HERDR_PANE_ID="$pane" "$REPO_ROOT/bin/rovo-herdr-hook"
}

now_ms() {
  local t
  t="$(date +%s%N 2>/dev/null || true)"
  case "$t" in
    *N | '') date +%s000 ;; # no nanosecond support (e.g. some BSD date builds): fall back to whole seconds
    *) printf '%s' "$((t / 1000000))" ;;
  esac
}

# =============================================================================
echo "test: on_complete does not synchronously report idle/done before the pane visibly settles"
reset_stub
PANE="wT:complete1"
thinking_screen
run_hook on_session_start sess-a "$PANE" >/dev/null 2>&1
run_hook on_user_prompt sess-a "$PANE" >/dev/null 2>&1

t0="$(now_ms)"
run_hook on_complete sess-a "$PANE" >/dev/null 2>&1
t1="$(now_ms)"
elapsed=$((t1 - t0))
check "$([ "$elapsed" -lt 1500 ] && echo 0 || echo 1)" \
  "on_complete hook returns quickly without blocking (took ${elapsed}ms)"

assert_absent "$HERDR_STUB_LOG" "Rovo Dev completed" \
  "idle/done is NOT reported synchronously while the pane still looks like it's thinking"

sleep 0.15
assert_absent "$HERDR_STUB_LOG" "Rovo Dev completed" \
  "still not reported a moment later, still mid-render"

idle_screen
if wait_for "$HERDR_STUB_LOG" "Rovo Dev completed" 3; then
  check 0 "async settle reports idle/done once the pane actually looks idle"
else
  check 1 "async settle reports idle/done once the pane actually looks idle" \
    "never appeared in:\n$(cat "$HERDR_STUB_LOG")"
fi
assert_contains "$HERDR_STUB_LOG" "pane report-agent $PANE" "settle report targets the right pane"

# =============================================================================
echo
echo "test: hook ownership is established before the pane's first externally-visible report"
reset_stub
: > "$HERDR_STUB_MARKER_LOG"
PANE="wT:marker1"
idle_screen
run_hook on_session_start sess-b "$PANE" >/dev/null 2>&1

assert_absent "$HERDR_STUB_MARKER_LOG" "MARKER:absent" \
  "no report-agent call ever lands before the hook-active marker is written"
assert_contains "$HERDR_STUB_MARKER_LOG" "MARKER:present $PANE" \
  "the (only) report-agent call saw the marker already present"

# =============================================================================
echo
echo "test: a late settle from a superseded prompt does not clobber a newer prompt's working state"
reset_stub
PANE="wT:gen1"
thinking_screen
run_hook on_session_start sess-c "$PANE" >/dev/null 2>&1
run_hook on_user_prompt sess-c1 "$PANE" >/dev/null 2>&1
run_hook on_complete sess-c1 "$PANE" >/dev/null 2>&1   # settle #1 starts polling; screen still "thinking"

sleep 0.1
run_hook on_user_prompt sess-c2 "$PANE" >/dev/null 2>&1  # prompt #2 supersedes it

idle_screen   # now let settle #1 observe an "idle-looking" screen, as if it were still relevant

# Give the stale settle task a bounded window to wake up and (incorrectly, if
# unfixed) report done.
sleep 0.6

assert_absent "$HERDR_STUB_LOG" "Rovo Dev completed" \
  "the stale (generation-1) completion never reports at all once superseded"
last_report="$(grep -F "pane report-agent $PANE" "$HERDR_STUB_LOG" | tail -1)"
printf '%s' "$last_report" | grep -Fq -- "--state working" \
  && check 0 "the pane's last reported state is still prompt #2's working" \
  || check 1 "the pane's last reported state is still prompt #2's working" "last report line: $last_report"
printf '%s' "$last_report" | grep -Fq -- "--agent-session-id sess-c2" \
  && check 0 "...specifically attributed to the newer prompt's session" \
  || check 1 "...specifically attributed to the newer prompt's session" "last report line: $last_report"

# =============================================================================
echo
echo "test: settle keeps polling through a transient 'unknown' read and still reports once truly idle"
reset_stub
PANE="wT:unknown1"
unknown_screen
run_hook on_session_start sess-u "$PANE" >/dev/null 2>&1
run_hook on_user_prompt sess-u "$PANE" >/dev/null 2>&1
run_hook on_complete sess-u "$PANE" >/dev/null 2>&1

sleep 0.15
assert_absent "$HERDR_STUB_LOG" "Rovo Dev completed" \
  "not reported while the pane read is merely unknown (a transient miss, not idle)"

idle_screen
if wait_for "$HERDR_STUB_LOG" "Rovo Dev completed" 3; then
  check 0 "settle reports idle/done once the pane moves from unknown to actually idle"
else
  check 1 "settle reports idle/done once the pane moves from unknown to actually idle" \
    "never appeared in:\n$(cat "$HERDR_STUB_LOG")"
fi

# =============================================================================
echo
echo "test: settle gives up without reporting once the pane reads as blocked, not idle"
reset_stub
PANE="wT:blocked1"
thinking_screen
run_hook on_session_start sess-bl "$PANE" >/dev/null 2>&1
run_hook on_user_prompt sess-bl "$PANE" >/dev/null 2>&1
run_hook on_complete sess-bl "$PANE" >/dev/null 2>&1   # settle starts polling; screen still "thinking"

sleep 0.1
blocked_screen   # Rovo turns out to be waiting on something else, not finishing up

# Bounded window for settle to observe "blocked" and give up.
sleep 0.4

assert_absent "$HERDR_STUB_LOG" "Rovo Dev completed" \
  "never reports done once the pane reads as blocked instead of idle"
last_report="$(grep -F "pane report-agent $PANE" "$HERDR_STUB_LOG" | tail -1)"
printf '%s' "$last_report" | grep -Fq -- "--state working" \
  && check 0 "the last hook-reported state (working, from the prompt) is left untouched" \
  || check 1 "the last hook-reported state (working, from the prompt) is left untouched" "last report line: $last_report"

# =============================================================================
echo
echo "test: exhausting the poll budget without ever seeing idle reports nothing (no blind-guess done)"
reset_stub
PANE="wT:timeout1"
thinking_screen
run_hook on_session_start sess-to "$PANE" >/dev/null 2>&1
run_hook on_user_prompt sess-to "$PANE" >/dev/null 2>&1

(
  # Small, local poll budget so this settle genuinely exhausts it fast - the
  # screen is deliberately left "thinking" (never idle) for the whole test.
  export ROVO_SETTLE_MAX_ITERATIONS=3
  export ROVO_SETTLE_POLL_INTERVAL=0.02
  run_hook on_complete sess-to "$PANE" >/dev/null 2>&1
)

# Bounded margin well beyond the ~60ms poll budget for the settle task to
# actually exhaust it and exit.
sleep 0.4

assert_absent "$HERDR_STUB_LOG" "Rovo Dev completed" \
  "never reports done after exhausting the poll budget without observing idle"
last_report="$(grep -F "pane report-agent $PANE" "$HERDR_STUB_LOG" | tail -1)"
printf '%s' "$last_report" | grep -Fq -- "--state working" \
  && check 0 "the last hook-reported state (working, from the prompt) is left untouched" \
  || check 1 "the last hook-reported state (working, from the prompt) is left untouched" "last report line: $last_report"

# ---------------------------------------------------------------------------
echo
if [ "$TESTS_FAILED" -eq 0 ]; then
  echo "PASS: $TESTS_RUN checks passed"
  exit 0
else
  echo "FAIL: $TESTS_FAILED of $TESTS_RUN checks failed" >&2
  exit 1
fi
