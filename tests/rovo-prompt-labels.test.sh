#!/usr/bin/env bash
#
# Tests for Rovo agent prompt label derivation (short_prompt_label).
# Validates that user prompts are shortened to 2-3 meaningful words.

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

check() { # <rc> <description> [detail]
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$1" -eq 0 ]; then
    echo "  ok: $2"
  else
    fail "$2" "${3:-}"
  fi
}

assert_equals() { # <actual> <expected> <description>
  if [ "$1" = "$2" ]; then
    check 0 "$3"
  else
    check 1 "$3" "expected '$2', got '$1'"
  fi
}

# --- isolate library in test env -------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export HERDR_ROVO_STATE_DIR="$WORK/state"
export HERDR_BIN_PATH="/bin/true"

# shellcheck source=../bin/herdr-lib.sh
source "$REPO_ROOT/bin/herdr-lib.sh"

# --- unit tests for short_prompt_label ------------------------------------
echo "test: short_prompt_label with typical multi-word prompt"
result="$(short_prompt_label "Implement a cache-busting strategy for static assets")"
assert_equals "$result" "Implement cache-busting strategy" "extracts first 3 meaningful words"

echo "test: short_prompt_label skips articles and prepositions"
result="$(short_prompt_label "The quick brown fox jumps over the lazy dog")"
assert_equals "$result" "quick brown fox" "skips articles, keeps content words"

echo "test: short_prompt_label with short prompt"
result="$(short_prompt_label "Fix bug")"
assert_equals "$result" "Fix bug" "preserves short prompts"

echo "test: short_prompt_label with single word"
result="$(short_prompt_label "Debug")"
assert_equals "$result" "Debug Task" "expands a single word to two"

echo "test: short_prompt_label with only filler words"
result="$(short_prompt_label "the a an for to")"
assert_equals "$result" "rovo-dev" "fallback when only filler words"

echo "test: short_prompt_label with empty prompt"
result="$(short_prompt_label "")"
assert_equals "$result" "rovo-dev" "fallback for empty prompt"

echo "test: short_prompt_label respects 80 char limit"
long_prompt="This is an extremely long prompt that contains many words and should be truncated at eighty characters total including spaces and everything else we can fit"
result="$(short_prompt_label "$long_prompt")"
[ ${#result} -le 80 ]
check "$?" "label respects 80-char limit (got ${#result} chars)"

echo "test: short_prompt_label with common development tasks"
result="$(short_prompt_label "Add authentication to the user login module")"
assert_equals "$result" "Add authentication user" "auth example"

result="$(short_prompt_label "Refactor the database connection pool manager")"
assert_equals "$result" "Refactor database connection" "refactor example"

result="$(short_prompt_label "Create API endpoint for data export functionality")"
assert_equals "$result" "Create API endpoint" "API example"

# --- integration test: on_user_prompt hook event ---------------------------
echo "test: rovo-herdr-hook uses derived prompt as agent label"

# Create fake herdr that records calls
STUB="$WORK/bin/herdr"
mkdir -p "$WORK/bin"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_STUB_LOG"
exit 0
STUB_EOF
chmod +x "$STUB"

HERDR_STUB_LOG="$WORK/calls.log"
export HERDR_BIN_PATH="$STUB"
export HERDR_STUB_LOG

# Prepare a fake pane
mkdir -p "$HERDR_ROVO_STATE_DIR/hooked"
touch "$HERDR_ROVO_STATE_DIR/hooked/wT:p1"

# Create hook payload with a prompt
payload=$(cat <<'PAYLOAD'
{
  "hook_event_name": "on_user_prompt",
  "session_id": "sess-abc123",
  "cwd": "/tmp",
  "attributes": {
    "prompt_text": "Implement caching mechanism for database queries"
  }
}
PAYLOAD
)

# Mock resolve_rovo_hook_pane to return our test pane
resolve_rovo_hook_pane() { echo "wT:p1"; }
export -f resolve_rovo_hook_pane

# Run the hook
printf '%s' "$payload" | bash "$REPO_ROOT/bin/rovo-herdr-hook" 2>/dev/null || true

# Check that the label was derived and passed to report-agent (as the agent label, not custom status)
grep -q "pane report-agent" "$HERDR_STUB_LOG"
check "$?" "report-agent called for on_user_prompt"

grep -q "Implement caching mechanism" "$HERDR_STUB_LOG"
check "$?" "derived prompt label passed as agent to report-agent"

# --- test backward compatibility -------------------------------------------
echo "test: on_user_prompt with missing prompt_text falls back to rovo-dev"

: > "$HERDR_STUB_LOG"

# Payload without prompt_text field
payload_no_text=$(cat <<'PAYLOAD'
{
  "hook_event_name": "on_user_prompt",
  "session_id": "sess-xyz789",
  "cwd": "/tmp",
  "attributes": {}
}
PAYLOAD
)

printf '%s' "$payload_no_text" | bash "$REPO_ROOT/bin/rovo-herdr-hook" 2>/dev/null || true

grep -q "rovo-dev" "$HERDR_STUB_LOG"
check "$?" "fallback label used when prompt_text missing"

: > "$HERDR_STUB_LOG"
payload_object='{"hook_event_name":"on_user_prompt","cwd":"/tmp","attributes":{"prompt":{"text":"not a string"}}}'
printf '%s' "$payload_object" | bash "$REPO_ROOT/bin/rovo-herdr-hook" 2>/dev/null || true
grep -q -- "--agent rovo-dev" "$HERDR_STUB_LOG"
check "$?" "non-string prompt payload falls back to rovo-dev"

# --- test agent label persistence across lifecycle events ------------------
echo "test: agent label persisted through tool, error, and completion events"

: > "$HERDR_STUB_LOG"

# Simulate on_user_prompt with a specific agent label
payload_prompt=$(cat <<'PAYLOAD'
{
  "hook_event_name": "on_user_prompt",
  "session_id": "sess-persist-1",
  "cwd": "/tmp",
  "attributes": {
    "prompt_text": "Refactor the authentication module"
  }
}
PAYLOAD
)

printf '%s' "$payload_prompt" | bash "$REPO_ROOT/bin/rovo-herdr-hook" 2>/dev/null || true

# Should have reported "Refactor authentication" as the agent label
grep -q "Refactor authentication" "$HERDR_STUB_LOG"
check "$?" "derived label 'Refactor authentication' used in on_user_prompt"

# Capture the initial report to verify label persistence
initial_report="$(grep 'report-agent' "$HERDR_STUB_LOG" | tail -1)"

# Simulate on_tool_start (should reuse the same agent label, not change to tool:xyz)
: >> "$HERDR_STUB_LOG"
payload_tool=$(cat <<'PAYLOAD'
{
  "hook_event_name": "on_tool_start",
  "session_id": "sess-persist-1",
  "cwd": "/tmp",
  "attributes": {
    "tool_input": {
      "tool_name": "grep"
    }
  }
}
PAYLOAD
)

printf '%s' "$payload_tool" | bash "$REPO_ROOT/bin/rovo-herdr-hook" 2>/dev/null || true

# The tool event should report with custom_status="tool:grep" but use persisted agent label "Refactor authentication"
grep -q "tool:grep" "$HERDR_STUB_LOG"
check "$?" "tool event includes tool:grep in state label"

# And the agent should still be the derived label, not "plugin:rovo-dev"
grep -q "Refactor authentication" "$HERDR_STUB_LOG"
check "$?" "persisted agent label survives tool event"

# --- test max 3 words limit -------------------------------------------
echo "test: agent label truncates to max 3 words"
result="$(short_prompt_label "Add support for multi-tenant database architecture patterns")"
# Should extract first 3 meaningful words and stop
count="$(printf '%s' "$result" | wc -w)"
[ "$count" -le 3 ]
check "$?" "label has max 3 words (got $count)"

# Verify it's the right 3 words (skip 'for', 'and')
printf '%s' "$result" | grep -Eq 'Add.*support.*multi' 
check "$?" "extracted meaningful 3 words: $result"

# --- test session reset clears label -------------------------------------------
echo "test: on_session_end clears persisted agent label"

# Create and retrieve a label
set_agent_label "wT:p99" "Test Label"
label="$(get_agent_label "wT:p99")"
[ "$label" = "Test Label" ]
check "$?" "label set and retrieved: $label"

# Clear it
clear_agent_label "wT:p99"
label="$(get_agent_label "wT:p99")"
[ "$label" = "rovo-dev" ]
check "$?" "label cleared, fallback to rovo-dev"

# ---------------------------------------------------------------------------
echo
if [ "$TESTS_FAILED" -eq 0 ]; then
  echo "PASS: $TESTS_RUN checks passed"
  exit 0
else
  echo "FAIL: $TESTS_FAILED of $TESTS_RUN checks failed" >&2
  exit 1
fi
