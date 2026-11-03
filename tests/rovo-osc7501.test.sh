#!/usr/bin/env bash
#
# Regression tests for OSC 7501 (Program Status Protocol) support, added so
# the Herdr app recognizes the Rovo pane as an agent. The classic herdr
# daemon has its own protocol (`pane report-agent`, covered by
# report-agent.test.sh and rovo-lifecycle.test.sh) which must keep working
# unchanged side by side with this one - these tests assert BOTH protocols
# fire together from bin/rovo-herdr-hook.
#
# bin/scan-rovo-panes must never attempt an OSC report: it is a detached
# plugin action with no reliable tty of its own, so writing OSC 7501 there
# risks landing on an unrelated terminal that happens to be the scanner's own
# controlling tty, mislabeling it as the Rovo pane. See the regression guard
# at the end of this file.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- tiny assertion helpers ------------------------------------------------
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

assert_eq() { # <actual> <expected> <description>
  if [ "$1" = "$2" ]; then check 0 "$3"; else
    check 1 "$3" "expected: $2\n     got: $1"
  fi
}

assert_contains() { # <haystack-file> <needle> <description>
  if grep -Fq -- "$2" "$1" 2>/dev/null; then check 0 "$3"; else
    check 1 "$3" "expected to find: $2 in:\n$(cat "$1" 2>/dev/null | cat -v)"
  fi
}

assert_absent_or_empty() { # <file> <description>
  if [ ! -s "$1" ]; then check 0 "$2"; else
    check 1 "$2" "expected no bytes, found:\n$(cat -v "$1")"
  fi
}

# --- fake herdr + fresh env per test ---------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/state"

STUB="$WORK/bin/herdr"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_STUB_LOG"
exit 0
STUB_EOF
chmod +x "$STUB"

export HERDR_ROVO_STATE_DIR="$WORK/state"
export HERDR_BIN_PATH="$STUB"
HERDR_STUB_LOG="$WORK/calls.log"
export HERDR_STUB_LOG

# shellcheck source=../bin/herdr-lib.sh
source "$REPO_ROOT/bin/herdr-lib.sh"

# =============================================================================
echo "test: emit_agent_osc7501 - writes the documented OSC 7501 payload"
OSC="$WORK/osc1.raw"
: > "$HERDR_STUB_LOG"
HERDR_OSC_TTY="$OSC" emit_agent_osc7501 "blocked" "question"
assert_contains "$OSC" $'\e]7501;state=blocked:app=rovo-dev:kind=question\e\\' \
  "payload matches herdr.dev's documented 'state=...:app=...' OSC 7501 format"

# =============================================================================
echo "test: emit_agent_osc7501 - kind is omitted when empty"
OSC="$WORK/osc2.raw"
HERDR_OSC_TTY="$OSC" emit_agent_osc7501 "working"
assert_contains "$OSC" $'\e]7501;state=working:app=rovo-dev\e\\' \
  "no stray ':kind=' segment when no kind is given"

# =============================================================================
echo "test: emit_agent_osc7501 - an invalid/unmapped state is never sent"
OSC="$WORK/osc3.raw"
HERDR_OSC_TTY="$OSC" emit_agent_osc7501 "unknown"
assert_absent_or_empty "$OSC" "an invalid 7501 state word is silently dropped, not sent"

# =============================================================================
echo "test: emit_agent_osc7501 - an empty state (not requested by the caller) sends nothing"
OSC="$WORK/osc4.raw"
HERDR_OSC_TTY="$OSC" emit_agent_osc7501 "" ""
assert_absent_or_empty "$OSC" "no osc_state means no OSC report at all"

# =============================================================================
echo "test: emit_agent_osc7501 - no controlling terminal never fails the caller"
rc=0
HERDR_OSC_TTY="/no/such/path/osc.raw" emit_agent_osc7501 "idle" || rc=$?
assert_eq "$rc" 0 "an unwritable OSC target is swallowed, not propagated as a failure"

# =============================================================================
echo "test: report_agent - reports to the legacy herdr CLI AND the Herdr app (OSC) together"
OSC="$WORK/osc5.raw"
: > "$HERDR_STUB_LOG"
rc=0
HERDR_OSC_TTY="$OSC" report_agent "wT:p1" "working" "mode:plan" "" "" "working" || rc=$?
assert_eq "$rc" 0 "report_agent still returns 0 on success"
assert_contains "$HERDR_STUB_LOG" "pane report-agent wT:p1" \
  "legacy herdr daemon still gets 'pane report-agent' (old system keeps working)"
assert_contains "$OSC" $'\e]7501;state=working:app=rovo-dev\e\\' \
  "new Herdr app gets the OSC 7501 report too"

# =============================================================================
echo "test: report_agent - OSC report still happens when the legacy herdr CLI call fails"
OSC="$WORK/osc6.raw"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_STUB_LOG"
exit 2
STUB_EOF
rc=0
HERDR_OSC_TTY="$OSC" report_agent "wT:p2" "blocked" "error" "" "" "error" 2>/dev/null || rc=$?
check "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
  "report_agent still surfaces the legacy CLI failure (unchanged contract)"
assert_contains "$OSC" $'\e]7501;state=error:app=rovo-dev\e\\' \
  "a Herdr-app-only environment (no working herdr CLI) still gets the OSC report"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_STUB_LOG"
exit 0
STUB_EOF

# =============================================================================
echo "test: report_agent - callers that pass no osc_state (e.g. scan-rovo-panes) send no OSC report"
OSC="$WORK/osc7.raw"
: > "$HERDR_STUB_LOG"
HERDR_OSC_TTY="$OSC" report_agent "wT:p3" "working" "mode:plan" >/dev/null 2>&1
assert_absent_or_empty "$OSC" \
  "a 3-arg report_agent call (no osc_state) never risks writing OSC to an unrelated tty"

# =============================================================================
echo "test: bin/scan-rovo-panes never passes an osc_state/osc_kind to report_agent"
# Regression guard for the design decision above: scan-rovo-panes runs
# detached from the pane's own tty, so it must stick to the legacy-only,
# 3-arg report_agent calls (pane_id, state, custom_status). A future edit
# adding a 6th/7th arg there would start emitting OSC 7501 onto whatever tty
# happens to be attached to the scanner process - almost certainly not the
# Rovo pane it is reporting about. Each call's full argument list fits on its
# own source line, so counting quoted tokens on that line is an exact,
# non-fragile proxy for its argument count.
call_lines="$(grep -n 'report_agent "' "$REPO_ROOT/bin/scan-rovo-panes" | cut -d: -f1)"
call_count=0
bad_count=0
while IFS= read -r lineno; do
  [ -n "$lineno" ] || continue
  call_count=$((call_count + 1))
  content="$(sed -n "${lineno}p" "$REPO_ROOT/bin/scan-rovo-panes")"
  n_args="$(printf '%s' "$content" | grep -oE '"[^"]*"' | wc -l | tr -d ' ')"
  if [ "$n_args" -ne 3 ]; then
    bad_count=$((bad_count + 1))
    echo "        scan-rovo-panes:$lineno has $n_args quoted args (expected 3): $content" >&2
  fi
done <<< "$call_lines"
check "$([ "$call_count" -ge 1 ] && echo 0 || echo 1)" \
  "found at least one report_agent call site in scan-rovo-panes to check" \
  "no 'report_agent \"' call found at all - update this test if the source moved"
assert_eq "$bad_count" "0" \
  "every report_agent call in scan-rovo-panes stays legacy-only (exactly 3 args, no OSC override)"

# =============================================================================
echo "test: bin/rovo-herdr-hook - every registered Rovo event reaches a valid OSC state"
# install-rovo-hooks registers exactly these 8 event names with Rovo (see its
# EVENTS array). This locks in, end to end through the real hook script (not
# just by reading its case statement), that each one maps to a valid OSC 7501
# state - the catch-all "*" branch (no registered event ever reaches it) is
# intentionally excluded.
HOOK_WORK="$(mktemp -d)"
mkdir -p "$HOOK_WORK/bin" "$HOOK_WORK/state" "$HOOK_WORK/sessions/sess-e2e"
cat > "$HOOK_WORK/bin/herdr" <<'HOOK_STUB'
#!/usr/bin/env bash
exit 0
HOOK_STUB
chmod +x "$HOOK_WORK/bin/herdr"

run_hook_e2e() { # <event_name> <osc_target_file> [tool_name]
  local event="$1" osc_target="$2" tool_name="${3:-}"
  printf '{"hook_event_name":"%s","session_id":"sess-e2e","cwd":"/tmp","attributes":{"tool_input":{"tool_name":"%s"}}}' \
    "$event" "$tool_name" | env \
    PATH="$HOOK_WORK/bin:$PATH" \
    HERDR_BIN_PATH="$HOOK_WORK/bin/herdr" \
    HERDR_ROVO_STATE_DIR="$HOOK_WORK/state" \
    ROVO_SESSIONS_DIR="$HOOK_WORK/sessions" \
    HERDR_PANE_ID="eT:p9" \
    HERDR_OSC_TTY="$osc_target" \
    bash "$REPO_ROOT/bin/rovo-herdr-hook" >/dev/null 2>&1
}

check_event_osc() { # <event_name> <expected-state> [tool_name]
  local event="$1" expected="$2" tool_name="${3:-}"
  local osc="$HOOK_WORK/osc-$event.raw"
  run_hook_e2e "$event" "$osc" "$tool_name"
  assert_contains "$osc" "state=${expected}:app=rovo-dev" \
    "$event reaches the Herdr app with OSC state '$expected'"
}

check_event_osc "on_session_start" "idle"
check_event_osc "on_user_prompt" "working"
check_event_osc "on_tool_start" "working" "some_other_tool"
check_event_osc "on_tool_permission" "blocked"
check_event_osc "on_tool_end" "working"
check_event_osc "on_error" "error"
check_event_osc "on_session_end" "idle"
check_event_osc "on_complete" "done"

# on_tool_start with tool_name=ask_user_questions takes the interactive-wait
# path instead of the generic "working" branch - it must report blocked, not
# working, since Rovo is asking the user a question.
osc="$HOOK_WORK/osc-interactive-wait.raw"
run_hook_e2e "on_tool_start" "$osc" "ask_user_questions"
assert_contains "$osc" "state=blocked:app=rovo-dev:kind=question" \
  "on_tool_start(ask_user_questions) reaches the Herdr app as blocked/question, not working"

# =============================================================================
echo "test: bin/rovo-herdr-hook - on_session_start resends OSC after a short delay"
# Confirmed live: the very first OSC write for a freshly created pane can
# race the Herdr app's own terminal listener attaching to that pane's tty and
# get silently dropped, while a later event (e.g. on_user_prompt) reports
# fine once the listener has attached. schedule_delayed_osc_retry closes that
# one-time window with a background resend. Deletes the immediate write, then
# waits past ROVO_OSC_RETRY_DELAY_SECONDS=0 and asserts the resend lands -
# this exercises the real background write, not merely the call that starts it.
# The preceding ask_user_questions test left pane eT:p9 marked as waiting for
# input; clear it first so this test observes on_session_start's own mapping.
run_hook_e2e "on_user_prompt" "$HOOK_WORK/osc-clear-wait.raw" >/dev/null 2>&1

osc="$HOOK_WORK/osc-retry-full.raw"
ROVO_OSC_RETRY_DELAY_SECONDS=0.2 run_hook_e2e "on_session_start" "$osc"
assert_contains "$osc" "state=idle:app=rovo-dev" \
  "on_session_start's immediate OSC report lands (pane_id resolved)"
rm -f "$osc"
sleep 0.6
assert_contains "$osc" "state=idle:app=rovo-dev" \
  "on_session_start's delayed resend re-lands after the immediate report is lost"

# =============================================================================
echo "test: bin/rovo-herdr-hook - OSC still reports when no pane_id can be resolved at all"
# Simulates a pane Herdr's own CLI registry does not know about yet (confirmed
# live for a freshly created Space/split pane): no HERDR_PANE_ID, and every
# `pane get`/`pane current` call reports pane_not_found, so
# resolve_rovo_hook_pane exhausts every path and returns nothing. OSC 7501
# needs no pane_id (see rovo_event_osc_state), so it must still fire; the
# legacy `pane report-agent` CLI call must NOT be attempted (there is no
# pane_id to target it at).
NOPANE_WORK="$(mktemp -d)"
mkdir -p "$NOPANE_WORK/bin" "$NOPANE_WORK/state" "$NOPANE_WORK/sessions/sess-nopane"
NOPANE_LOG="$NOPANE_WORK/calls.log"
cat > "$NOPANE_WORK/bin/herdr" <<'NOPANE_STUB'
#!/usr/bin/env bash
printf '%s
' "$*" >> "$NOPANE_LOG"
case "$1 $2" in
  "pane get"|"pane current")
    echo '{"error":{"code":"pane_not_found","message":"pane not found"}}'
    exit 1
    ;;
  "pane list")
    echo '{"result":{"panes":[]}}'
    ;;
  *)
    exit 0
    ;;
esac
NOPANE_STUB
chmod +x "$NOPANE_WORK/bin/herdr"

run_hook_nopane() { # <event_name> <osc_target_file>
  local event="$1" osc_target="$2"
  printf '{"hook_event_name":"%s","session_id":"sess-nopane","cwd":"/tmp","attributes":{}}' \
    "$event" | env \
    PATH="$NOPANE_WORK/bin:$PATH" \
    HERDR_BIN_PATH="$NOPANE_WORK/bin/herdr" \
    HERDR_ROVO_STATE_DIR="$NOPANE_WORK/state" \
    ROVO_SESSIONS_DIR="$NOPANE_WORK/sessions" \
    NOPANE_LOG="$NOPANE_LOG" \
    HERDR_OSC_TTY="$osc_target" \
    bash "$REPO_ROOT/bin/rovo-herdr-hook" >/dev/null 2>&1
}

: > "$NOPANE_LOG"
osc="$NOPANE_WORK/osc-session-start.raw"
run_hook_nopane "on_session_start" "$osc"
assert_contains "$osc" "state=idle:app=rovo-dev" \
  "on_session_start still reaches the Herdr app via OSC with no resolvable pane_id"

osc="$NOPANE_WORK/osc-complete.raw"
run_hook_nopane "on_complete" "$osc"
assert_contains "$osc" "state=done:app=rovo-dev" \
  "on_complete still reaches the Herdr app via OSC with no resolvable pane_id"

if grep -q "report-agent" "$NOPANE_LOG"; then
  check 1 "the legacy 'pane report-agent' CLI call is never attempted without a pane_id" \
    "$(cat "$NOPANE_LOG")"
else
  check 0 "the legacy 'pane report-agent' CLI call is never attempted without a pane_id"
fi

echo "test: bin/rovo-herdr-hook - on_session_start resends OSC via the no-pane_id bypass too"
osc="$NOPANE_WORK/osc-retry-nopane.raw"
ROVO_OSC_RETRY_DELAY_SECONDS=0.2 run_hook_nopane "on_session_start" "$osc"
assert_contains "$osc" "state=idle:app=rovo-dev" \
  "on_session_start's immediate bypass OSC report lands (no pane_id)"
rm -f "$osc"
sleep 0.6
assert_contains "$osc" "state=idle:app=rovo-dev" \
  "on_session_start's delayed resend re-lands via the bypass path too"

rm -rf "$NOPANE_WORK"

rm -rf "$HOOK_WORK"

# ---------------------------------------------------------------------------
echo
if [ "$TESTS_FAILED" -eq 0 ]; then
  echo "PASS: $TESTS_RUN checks passed"
  exit 0
else
  echo "FAIL: $TESTS_FAILED of $TESTS_RUN checks failed" >&2
  exit 1
fi
