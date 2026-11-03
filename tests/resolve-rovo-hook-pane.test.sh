#!/usr/bin/env bash
#
# Regression tests for resolve_rovo_hook_pane's session-pane cache fallback in
# bin/herdr-lib.sh.
#
# These lock in the fix for a bug where a long-running Rovo session stopped
# being reported to Herdr partway through: HERDR_PANE_ID is inherited once at
# Rovo's own process start and goes stale if Herdr reassigns pane/tab ids
# afterwards, and the cwd+foreground-process heuristic only holds while Rovo
# itself is the pane's foreground process - a coding agent's own tool calls
# routinely take over that role instead, in a different cwd. Without a cache,
# both paths can fail at once and the hook silently exits before ever
# reporting the pane's status (see bin/rovo-herdr-hook's early
# `[ -n "$pane_id" ] || exit 0`).
#
# The tests drive the real library function against a fake `herdr` binary, so
# no real Herdr server is ever touched.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Fake herdr: `pane list` and `pane get <id>` are driven from files the test
# writes into $WORK, so each test can stage exactly the panes it needs without
# a real Herdr server.
STUB="$WORK/bin/herdr"
mkdir -p "$WORK/bin"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pane list")
    cat "$HERDR_STUB_PANE_LIST_FILE" 2>/dev/null || echo '{"result":{"panes":[]}}'
    ;;
  "pane get")
    if [ -f "$WORK_DIR/pane-notfound-$3" ]; then
      echo '{"error":{"code":"pane_not_found","message":"pane not found"}}'
    else
      cat "$WORK_DIR/pane-get-$3.json" 2>/dev/null || echo '{"result":{"pane":{}}}'
    fi
    ;;
  "pane current")
    cat "$WORK_DIR/pane-current.json" 2>/dev/null || echo '{"result":{"pane":{}}}'
    ;;
  *)
    exit 0
    ;;
esac
STUB_EOF
chmod +x "$STUB"

export HERDR_ROVO_STATE_DIR="$WORK/state"
export HERDR_BIN_PATH="$STUB"
export WORK_DIR="$WORK"
unset HERDR_PANE_ID

# shellcheck source=../bin/herdr-lib.sh
source "$REPO_ROOT/bin/herdr-lib.sh"

stage_pane() { # <pane_id> <cwd>
  local pane_id="$1" cwd="$2"
  printf '{"result":{"pane":{"foreground_cwd":"%s"}}}' "$cwd" \
    > "$WORK/pane-get-$pane_id.json"
}

set_pane_list() { # <pane_id>...
  local ids=("$@") json="[" first=1
  for id in "${ids[@]}"; do
    [ "$first" -eq 1 ] || json+=","
    json+="{\"pane_id\":\"$id\"}"
    first=0
  done
  json+="]"
  HERDR_STUB_PANE_LIST_FILE="$WORK/pane-list.json"
  printf '{"result":{"panes":%s}}' "$json" > "$HERDR_STUB_PANE_LIST_FILE"
  export HERDR_STUB_PANE_LIST_FILE
}

stage_current_pane() { # <pane_id>
  printf '{"result":{"pane":{"pane_id":"%s"}}}' "$1" > "$WORK/pane-current.json"
}

stage_pane_not_found() { # <pane_id>
  : > "$WORK/pane-notfound-$1"
}

# Stub out pane_is_rovo for this test file: real-world process-matching is
# already covered by other tests, and is orthogonal to the cache logic under
# test here. Panes named with a "rovo-" prefix are treated as Rovo panes.
pane_is_rovo() {
  case "$1" in
    rovo-*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
echo "test: HERDR_PANE_ID short-circuits and populates the cache"
export HERDR_PANE_ID="wT:p1"
stage_pane "wT:p1" "/doesnt/matter"
got="$(resolve_rovo_hook_pane "/doesnt/matter" "sess-a")"
[ "$got" = "wT:p1" ]; check $? "resolves via HERDR_PANE_ID (got '$got')"
unset HERDR_PANE_ID
got="$(cached_session_pane "sess-a")"
[ "$got" = "wT:p1" ]; check $? "HERDR_PANE_ID resolution is cached for the session (got '$got')"

echo "test: HERDR_PANE_ID set but the pane no longer exists -> falls through to cwd match"
# Simulates a torn-down pane/workspace: Rovo's process still carries the old
# HERDR_PANE_ID, but Herdr itself now reports pane_not_found for it - the
# live-confirmed failure mode this check exists for.
export HERDR_PANE_ID="stale:p1"
stage_pane_not_found "stale:p1"
set_pane_list "rovo-p5"
stage_pane "rovo-p5" "/proj5"
got="$(resolve_rovo_hook_pane "/proj5" "sess-stale")"
[ "$got" = "rovo-p5" ]; check $? \
  "falls through past a stale HERDR_PANE_ID to cwd+process match (got '$got')"
unset HERDR_PANE_ID

echo "test: HERDR_PANE_ID set but the pane no longer exists, no cwd match -> focused-pane fallback"
export HERDR_PANE_ID="stale:p2"
stage_pane_not_found "stale:p2"
set_pane_list "other-p10"
stage_pane "other-p10" "/unrelated"
stage_current_pane "wF:p9"
got="$(resolve_rovo_hook_pane "/proj-no-match" "sess-stale2")"
[ "$got" = "wF:p9" ]; check $? \
  "stale HERDR_PANE_ID with no cwd match falls through to the focused-pane fallback (got '$got')"
unset HERDR_PANE_ID

echo "test: cwd + foreground-process match resolves and caches"
set_pane_list "rovo-p2"
stage_pane "rovo-p2" "/proj"
got="$(resolve_rovo_hook_pane "/proj" "sess-b")"
[ "$got" = "rovo-p2" ]; check $? "resolves via live cwd+process match (got '$got')"
got="$(cached_session_pane "sess-b")"
[ "$got" = "rovo-p2" ]; check $? "live match is cached for the session (got '$got')"

echo "test: cwd drifted away from Rovo's cwd -> falls back to session cache"
# Simulate a coding agent's tool call: the pane's foreground cwd no longer
# matches Rovo's own cwd (a child shell took over, in a different dir), so the
# live heuristic cannot resolve - but session_id "sess-b" was already cached
# above by an earlier, successful event for this same session.
stage_pane "rovo-p2" "/some/unrelated/tool/cwd"
got="$(resolve_rovo_hook_pane "/proj" "sess-b")"
[ "$got" = "rovo-p2" ]; check $? \
  "falls back to the session's cached pane when live resolution fails (got '$got')"

echo "test: no HERDR_PANE_ID, no live match, no cache -> fails closed"
set_pane_list "other-p3"
stage_pane "other-p3" "/unrelated"
if got="$(resolve_rovo_hook_pane "/proj" "sess-never-seen" 2>/dev/null)"; then
  check 1 "unresolvable session returns failure" "unexpectedly resolved '$got'"
else
  check 0 "unresolvable session returns failure"
fi

echo "test: clear_session_pane removes a session's cache entry"
cache_session_pane "sess-c" "wT:p4"
clear_session_pane "sess-c"
if got="$(cached_session_pane "sess-c" 2>/dev/null)"; then
  check 1 "cache entry is gone after clear_session_pane" "unexpectedly found '$got'"
else
  check 0 "cache entry is gone after clear_session_pane"
fi

echo "test: focused-pane fallback resolves and caches when no other path can"
# Simulates a session relayed through Herdr's managed-agent subsystem: no
# HERDR_PANE_ID was ever inherited, and the pane's real foreground process is
# never Rovo, so neither of the two stronger paths, nor a prior cache entry,
# can ever resolve this session.
set_pane_list "other-p9"
stage_pane "other-p9" "/unrelated"
stage_current_pane "wF:p1"
got="$(resolve_rovo_hook_pane "/proj" "sess-relayed")"
[ "$got" = "wF:p1" ]; check $? "resolves via the focused-pane fallback (got '$got')"
got="$(cached_session_pane "sess-relayed")"
[ "$got" = "wF:p1" ]; check $? "focused-pane fallback result is cached (got '$got')"

echo "test: focused-pane fallback refuses a pane another live session already claimed"
cache_session_pane "sess-owner" "wF:p2"
stage_current_pane "wF:p2"
if got="$(resolve_rovo_hook_pane "/proj" "sess-other" 2>/dev/null)"; then
  check 1 "refuses a pane claimed by a different session" "unexpectedly resolved '$got'"
else
  check 0 "refuses a pane claimed by a different session"
fi
if got="$(cached_session_pane "sess-other" 2>/dev/null)"; then
  check 1 "does not cache a refused pane for the new session" "unexpectedly found '$got'"
else
  check 0 "does not cache a refused pane for the new session"
fi

# ---------------------------------------------------------------------------
echo
echo "$TESTS_RUN tests run, $TESTS_FAILED failed."
[ "$TESTS_FAILED" -eq 0 ]
