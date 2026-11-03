#!/usr/bin/env bash
# Shared helpers for the Rovo Dev Herdr detector plugin.
#
# This file is meant to be sourced, not executed directly. It centralizes the
# Herdr CLI invocation, Rovo process detection, output-based state
# classification, and the small amount of persisted state the scanner needs.

# Stable identifiers used when reporting agents to Herdr.
readonly ROVO_SOURCE="plugin:rovo-dev"
readonly ROVO_TITLE_SOURCE="plugin:rovo-dev:title"
readonly ROVO_AGENT="rovo-dev"

# Number of trailing output lines to FETCH from Herdr when classifying pane
# state. This is scrollback context, not what's necessarily actually on
# screen right now - see ROVO_STATE_SLICE_LINES below, which controls how
# much of this fetched window classify_state actually looks at.
readonly ROVO_READ_LINES="${ROVO_READ_LINES:-60}"

# Number of lines, counted from the BOTTOM of the fetched output, that
# classify_state actually pattern-matches against. Deliberately much smaller
# than ROVO_READ_LINES: a pane's scrollback can carry now-stale status text
# (e.g. a "Rovo Dev is thinking" or an active-tool line from an earlier,
# already-finished turn) that has scrolled up but is still within the fetched
# window. Matching against the whole fetched window lets that stale text
# outvote a current, genuinely idle bottom-of-screen prompt and misreport a
# quiet pane as "working" - observed live for old panes that predate hook
# installation, which have enough scrollback for this to bite (hooked panes
# are unaffected; the scanner trusts their hook reports and never calls
# classify_state for them at all). Restricting matching to a small slice near
# the bottom approximates "what's actually on screen right now" from a plain
# scrollback read.
#
# 15 was still too generous: a live audit pane (w1:p3) was visibly idle but
# had its own assistant message mention the phrase "Rovo Dev is thinking"
# 14 lines from the bottom - inside a 15-line slice, so it still misreported
# as working. Separately measuring real working/idle footer markers across
# active and idle panes (w1:p2, w2) found all of them within the bottom 8
# lines, so the default is pinned there instead. Kept overridable for tests.
readonly ROVO_STATE_SLICE_LINES="${ROVO_STATE_SLICE_LINES:-8}"

# Resolve the Herdr binary. Inside a plugin/pane, HERDR_BIN_PATH is injected;
# fall back to `herdr` on PATH for manual runs.
herdr_bin() {
  printf '%s' "${HERDR_BIN_PATH:-herdr}"
}

# Directory used to remember which panes we have marked as Rovo agents, so we
# can reset them to idle once Rovo is no longer the foreground process, and to
# record which panes have an actively-firing hook pipeline (see hooked_dir
# below).
#
# This MUST resolve to the same path regardless of invocation context:
#
#   - scan-rovo-panes runs as a Herdr-invoked plugin command, so Herdr injects
#     the plugin-scoped HERDR_PLUGIN_STATE_DIR into its environment.
#   - rovo-herdr-hook runs as a child process of Rovo itself, inheriting the
#     Rovo pane's environment. That environment carries pane-scoped variables
#     (HERDR_PANE_ID, HERDR_BIN_PATH) but there is no plugin invocation
#     happening for it to inherit HERDR_PLUGIN_STATE_DIR from.
#
# Previously this read HERDR_PLUGIN_STATE_DIR with a ${TMPDIR}/herdr-rovo-dev
# fallback, which meant the scanner and the hook resolved to two different
# directories: the hook would write its "pane is hooked" marker under
# ${TMPDIR}/herdr-rovo-dev, but the scanner would only ever look under the
# Herdr-provided plugin state dir, so it never saw the marker and could
# reclassify (and reset) a pane that hooks were already reporting on
# correctly. Using a single deterministic, XDG-style path instead means both
# call sites agree without depending on which one happens to run in a
# Herdr-plugin context. HERDR_ROVO_STATE_DIR remains as an override for tests.
state_dir() {
  local dir="${HERDR_ROVO_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-rovo-dev}"
  mkdir -p "$dir" 2>/dev/null || true
  printf '%s' "$dir"
}

# Path to the file tracking panes we currently consider Rovo agents.
tracked_file() {
  printf '%s/tracked-panes' "$(state_dir)"
}

# --- Hook-priority tracking ------------------------------------------------
#
# When Rovo's event hooks (rovo-herdr-hook) are installed and actively firing
# for a pane, they are a far more reliable source of truth than re-deriving
# state from scraped terminal output: they carry structured, semantic event
# names straight from Rovo's own lifecycle, immune to any future wording/UI
# changes in the CLI. The scan-based fallback (scan-rovo-panes) exists only to
# (a) bootstrap panes that predate hook installation or whose hooks are not
# (yet) firing, and (b) detect that Rovo has exited a pane entirely, which
# hooks cannot self-report if the process dies uncleanly.
#
# To avoid the scanner's heuristics fighting with - and potentially
# clobbering - an already-accurate hook-reported state, each pane that has
# received at least one hook event is marked "hooked" here. The scanner
# checks this marker and, once set, trusts the hook layer completely for that
# pane's state/custom-status, skipping its own regex-based reclassification.
hooked_dir() {
  local dir
  dir="$(state_dir)/hooked"
  mkdir -p "$dir" 2>/dev/null || true
  printf '%s' "$dir"
}

# Filesystem-safe marker filename for a pane id (defensive; pane ids observed
# in practice are already safe, e.g. "wT:p1", but avoid any path traversal).
hook_marker_file() {
  local pane_id="$1"
  printf '%s/%s' "$(hooked_dir)" "$(printf '%s' "$pane_id" | tr '/' '_')"
}

# Record that a pane has an actively-firing hook pipeline.
mark_pane_hooked() {
  local pane_id="$1"
  touch "$(hook_marker_file "$pane_id")" 2>/dev/null || true
}

# Return 0 if the pane has a recorded active hook pipeline.
pane_hook_active() {
  local pane_id="$1"
  [ -e "$(hook_marker_file "$pane_id")" ]
}

# Forget a pane's hook-active marker (session ended, or Rovo is no longer the
# foreground process). A pane id can be reused by a later, unrelated session,
# which should have to re-earn hook trust from its own first event.
clear_pane_hooked() {
  local pane_id="$1"
  rm -f "$(hook_marker_file "$pane_id")" 2>/dev/null || true
}

interactive_wait_file() {
  local pane_id="$1"
  printf '%s/interactive-wait-%s' "$(state_dir)" "$(printf '%s' "$pane_id" | tr '/' '_')"
}

mark_interactive_wait() {
  touch "$(interactive_wait_file "$1")" 2>/dev/null || true
}

interactive_wait_active() {
  [ -e "$(interactive_wait_file "$1")" ]
}

clear_interactive_wait() {
  rm -f "$(interactive_wait_file "$1")" 2>/dev/null || true
}

# --- Session -> pane cache --------------------------------------------------
#
# resolve_rovo_hook_pane (below) normally identifies the calling pane from
# HERDR_PANE_ID, or failing that, by matching the event's cwd against a live
# pane's foreground cwd + foreground process. Both can stop working partway
# through a long-running session:
#
#   - HERDR_PANE_ID is inherited once, at Rovo's own process start. If Herdr
#     reassigns pane/tab ids afterwards (e.g. the pane is moved, or the
#     workspace is reorganized), Rovo's hooks keep seeing the OLD value for
#     the rest of that process's life - observed live, not hypothetical.
#   - The cwd+foreground-process match only holds while Rovo itself is the
#     pane's foreground process. A coding agent's own tool calls routinely
#     become the foreground process instead, often in a different cwd, which
#     makes this heuristic fail for the rest of that tool call.
#   - A session relayed through Herdr's own managed-agent subsystem
#     (herdr-core, e.g. an `herdr agent start`-style launch) never receives
#     HERDR_PANE_ID at all, and is never the pane's OS-visible foreground
#     process either - both paths above are unresolvable for its entire
#     life, not just partway through. For this case only,
#     resolve_rovo_hook_pane falls back to Herdr's own documented guidance
#     (`herdr --skill`: an ambient-pane-id-less caller should target the
#     focused pane), guarded against concurrently-running sessions by
#     refusing a pane another live session already claimed.
#
# Once any path above resolves a pane for a given session_id, that mapping is
# cached here and reused as a fallback on a later event where the stronger
# paths fail. A session id is Rovo's own, process-lifetime-scoped identifier,
# so this cannot leak a pane assignment across unrelated Rovo processes.
session_pane_dir() {
  local dir
  dir="$(state_dir)/session-pane"
  mkdir -p "$dir" 2>/dev/null || true
  printf '%s' "$dir"
}

session_pane_file() {
  local session_id="$1"
  printf '%s/%s' "$(session_pane_dir)" "$(printf '%s' "$session_id" | tr '/' '_')"
}

# Remember pane_id as the resolved pane for session_id. Best-effort: a failure
# to persist this just means a future fallback lookup misses, same as never
# having cached it.
cache_session_pane() {
  local session_id="$1" pane_id="$2"
  [ -n "$session_id" ] && [ -n "$pane_id" ] || return 0
  printf '%s' "$pane_id" > "$(session_pane_file "$session_id")" 2>/dev/null || true
}

# Print the pane_id previously cached for session_id, if any. Returns 1 (and
# prints nothing) when there is no cache entry.
cached_session_pane() {
  local session_id="$1" pane_id
  [ -n "$session_id" ] || return 1
  pane_id="$(cat "$(session_pane_file "$session_id")" 2>/dev/null || true)"
  [ -n "$pane_id" ] || return 1
  printf '%s' "$pane_id"
}

# Forget a session's cached pane (session ended; a reused session_id - should
# one ever occur - must re-earn its mapping rather than inherit a stale one).
clear_session_pane() {
  local session_id="$1"
  [ -n "$session_id" ] || return 0
  rm -f "$(session_pane_file "$session_id")" 2>/dev/null || true
}

# True when some OTHER live session's cache entry already points at pane_id.
# Used to guard the focused-pane fallback below: refuses to claim a pane that
# a different, concurrently-running Rovo session has already resolved to,
# so two sessions running at once cannot both be attributed to one pane.
pane_claimed_by_other_session() {
  local pane_id="$1" session_id="$2" dir f own_file other_pane
  [ -n "$pane_id" ] || return 1
  dir="$(session_pane_dir)"
  own_file="$(session_pane_file "$session_id")"
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    [ "$f" = "$own_file" ] && continue
    other_pane="$(cat "$f" 2>/dev/null || true)"
    [ "$other_pane" = "$pane_id" ] && return 0
  done
  return 1
}

# True when pane_id is confirmed to still exist. Used to guard trusting a
# possibly-stale HERDR_PANE_ID (see resolve_rovo_hook_pane below): confirmed
# live that a pane/workspace torn down after Rovo's process started leaves
# HERDR_PANE_ID pointing at an id `herdr pane get` now reports as
# {"error":{"code":"pane_not_found",...}}.
#
# Deliberately fails OPEN (treats the pane as existing) on anything other
# than that specific, confirmed error code - an unparseable response, an
# unreachable Herdr socket, or an older Herdr CLI without this exact error
# shape all leave this helper unable to tell, and HERDR_PANE_ID is the most
# reliable path resolve_rovo_hook_pane has when it is not positively known to
# be wrong. This also matches every existing stub herdr used by other tests,
# none of which model `pane get` at all.
pane_exists() {
  local pane_id="$1" pane_json error_code
  [ -n "$pane_id" ] || return 1
  pane_json="$("$(herdr_bin)" pane get "$pane_id" 2>/dev/null)"
  error_code="$(printf '%s' "$pane_json" | jq -r '.error.code // empty' 2>/dev/null)"
  [ "$error_code" != "pane_not_found" ]
}

# --- Exit-reset debounce ---------------------------------------------------
#
# The scanner resets a previously-tracked pane to idle/"exited" once it is no
# longer detected as Rovo. Foreground-process detection is momentary, though: a
# single scan can miss a live session - e.g. a child process briefly owns the
# pane's controlling terminal during a tool call, or a one-off process-info
# read fails. Resetting on the very first miss would wrongly flip an active,
# still-working (and possibly hook-reporting) pane to "exited". So misses are
# counted per pane and the reset only fires once a pane has been missing for
# ROVO_MISS_THRESHOLD scans in a row; any scan that re-detects the pane clears
# its counter. This still catches a genuinely-gone pane (its count climbs past
# the threshold) while tolerating transient blips.
readonly ROVO_MISS_THRESHOLD="${ROVO_MISS_THRESHOLD:-2}"

misses_dir() {
  local dir
  dir="$(state_dir)/misses"
  mkdir -p "$dir" 2>/dev/null || true
  printf '%s' "$dir"
}

miss_count_file() {
  local pane_id="$1"
  printf '%s/%s' "$(misses_dir)" "$(printf '%s' "$pane_id" | tr '/' '_')"
}

# Print a pane's current consecutive-miss count (0 when none/unset/corrupt).
get_miss_count() {
  local count
  count="$(cat "$(miss_count_file "$1")" 2>/dev/null || true)"
  case "$count" in
    '' | *[!0-9]*) printf '0' ;;
    *) printf '%s' "$count" ;;
  esac
}

# Increment, persist, and print a pane's consecutive-miss count.
bump_miss_count() {
  local pane_id="$1" next
  next="$(( $(get_miss_count "$pane_id") + 1 ))"
  printf '%s' "$next" > "$(miss_count_file "$pane_id")" 2>/dev/null || true
  printf '%s' "$next"
}

# Reset a pane's consecutive-miss count (it was re-detected, or has been reset).
clear_miss_count() {
  local pane_id="$1"
  rm -f "$(miss_count_file "$pane_id")" 2>/dev/null || true
}

# jq must be available for JSON parsing.
require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "herdr-rovo-dev: jq is required but was not found on PATH" >&2
    return 1
  fi
}

# List all pane ids, one per line.
# Herdr's `pane list` already emits JSON on stdout (no --json flag).
list_pane_ids() {
  "$(herdr_bin)" pane list 2>/dev/null \
    | jq -r '.result.panes[]?.pane_id // .panes[]?.pane_id // empty'
}

# Emit the foreground command line(s) for a pane, one argv0/cmdline per line.
# `pane process-info` also emits JSON on stdout by default.
pane_foreground_cmdlines() {
  local pane_id="$1"
  "$(herdr_bin)" pane process-info --pane "$pane_id" 2>/dev/null \
    | jq -r '
        (.result.process_info // .process_info) as $pi
        | $pi.foreground_processes[]?
        | if ((.cmdline // "") != "") then
            .cmdline
          elif (((.argv // []) | length) > 0) then
            (.argv | join(" "))
          else
            (.argv0 // empty)
          end
      '
}

# Return 0 if the pane is running a Rovo CLI or Rovo Dev CLI session in the
# foreground. Supports both the legacy Rovo Dev CLI and the new Rovo CLI:
#
#   Rovo Dev CLI (legacy): `acli rovodev run`, `atlassian_cli_rovodev run`
#   Rovo CLI (new):        `rovo` (bare TUI launch; the `rovo` launcher execs a
#                          binary that may itself be named `rovo` or
#                          `atlassian_cli_rovodev`), also `rovo run`, and
#                          `rovo --restore <session-id>` (reattaching a prior
#                          session) or other flags/args. The new CLI's real
#                          foreground process can also be the bare binary
#                          itself with NO subcommand at all, e.g.
#                          `atlassian_cli_rovodev` or
#                          `atlassian_cli_rovodev --restore <session-id>`, with
#                          no `rovo` launcher anywhere in the process tree.
#
# Non-interactive `serve` sessions (e.g. the IDE-embedded
# `atlassian_cli_rovodev serve ...`) are deliberately NOT matched - they are not
# interactive TUI panes and should not be reported as agents.
pane_is_rovo() {
  local pane_id="$1"
  local cmds
  cmds="$(pane_foreground_cmdlines "$pane_id")" || return 1

  # Exclude non-interactive serve mode outright, then match either CLI.
  #
  # The positive match only requires the "rovo"/"... run" token to be
  # followed by whitespace-or-end (rather than anchoring the whole command to
  # the end of the line), so trailing flags/args - e.g. `rovo --restore
  # <session-id>` when reattaching a session - do not prevent detection.
  # Without this, such panes are treated as "no longer Rovo" and get
  # force-reset to idle on every scan, regardless of their actual state.
  #
  # The `atlassian_cli_rovodev` alternative matches the binary regardless of
  # what (if anything) follows it, rather than requiring a literal trailing
  # `run`: the new Rovo CLI's real foreground process is frequently the bare
  # binary with no subcommand at all. The preceding serve-exclusion filter
  # already strips `atlassian_cli_rovodev serve` lines before this positive
  # match runs, so broadening this alternative does not start matching serve
  # sessions.
  printf '%s\n' "$cmds" \
    | grep -Ev '(atlassian_cli_rovodev|acli[[:space:]]+rovodev|(^|/|[[:space:]])rovo)[[:space:]]+serve([[:space:]]|$)' \
    | grep -Eq \
      '(^|/|[[:space:]])rovo([[:space:]]+run)?([[:space:]]|$)|atlassian_cli_rovodev([[:space:]]|$)|(acli[[:space:]]+rovodev[[:space:]]+run)'
}

# Classify the semantic state of a Rovo pane from its recent visible output.
# Prints one of: working | blocked | idle | unknown
classify_state() {
  local pane_id="$1"
  local out slice
  out="$("$(herdr_bin)" pane read "$pane_id" --source recent-unwrapped \
    --lines "$ROVO_READ_LINES" 2>/dev/null)" || {
    printf 'unknown'
    return 0
  }

  # Pattern-match only the bottom slice (see ROVO_STATE_SLICE_LINES above),
  # never the whole fetched window - the whole window can contain stale
  # status text from an earlier, already-finished turn that no longer
  # reflects the pane's current state.
  slice="$(printf '%s' "$out" | tail -n "$ROVO_STATE_SLICE_LINES")"

  # Working: Rovo is actively thinking or executing a tool call.
  #
  # NOTE: the new Rovo CLI dropped "Dev" from its status wording (it now
  # prints "Rovo is thinking.." rather than "Rovo Dev is thinking"), and
  # replaced the old "Esc to interrupt" hint with a
  # "Enter to queue, Ctrl+Enter to steer" input box while a run is in
  # flight. The "Dev" branding is matched optionally so this keeps working
  # for the legacy Rovo Dev CLI too. Without this, the working-state check
  # never matches on the new CLI and every session falls through to the
  # idle-state check below, which matches the "? for shortcuts" footer that
  # is *always* visible regardless of whether Rovo is actively working -
  # causing working sessions to be misreported as idle.
  if printf '%s' "$slice" | grep -Eq \
    'Rovo( Dev)? is (thinking|working|running)|(Esc to interrupt)|(Enter to queue,? Ctrl\+Enter to steer)|(▶[^|]+\|[[:space:]]*[a-z_]+[[:space:]]*$)'; then
    printf 'working'
    return 0
  fi

  # Blocked: Rovo is waiting on the user for a decision or input.
  if printf '%s' "$slice" | grep -Eq \
    '\[y/n\]|\(y/n\)|Do you want to|Waiting for (your )?(input|confirmation)|Approve|Allow this|Choose an option|Select an option|Press Enter to'; then
    printf 'blocked'
    return 0
  fi

  # Idle: an interactive prompt is present and nothing is in flight.
  if printf '%s' "$slice" | grep -Eq '\? for shortcuts|agent mode:'; then
    printf 'idle'
    return 0
  fi

  printf 'unknown'
}

# Derive a short custom-status from the Rovo status line (e.g. the agent mode),
# printed on stdout. Empty output means "no custom status".
derive_custom_status() {
  local pane_id="$1"
  local out mode
  out="$("$(herdr_bin)" pane read "$pane_id" --source recent-unwrapped \
    --lines "$ROVO_READ_LINES" 2>/dev/null)" || return 0
  mode="$(printf '%s' "$out" \
    | grep -oE 'agent mode:[[:space:]]*[a-zA-Z-]+' \
    | tail -1 \
    | sed -E 's/agent mode:[[:space:]]*//' || true)"
  if [ -n "$mode" ]; then
    printf 'mode:%s' "$mode"
  fi
  return 0
}

# Carry a pane's custom status (e.g. Rovo's agent mode or the current tool) to
# Herdr as a state label, via `pane report-metadata`.
#
# This MUST be a separate call from report_agent's `pane report-agent`: the
# `report-agent` verb has no flag for a custom status. Passing an unknown flag
# like `--custom-status` makes the Herdr CLI reject the *entire* invocation
# (`unknown option`, non-zero exit) before it reaches the server, so the agent
# state itself never lands and the Rovo pane silently never appears in Herdr's
# agents list. Custom status is decorative, so a failure here must never fail
# the caller's state report - this always returns 0, but logs to stderr (which
# Herdr captures into the plugin log) so a future CLI-contract break stays
# diagnosable instead of vanishing.
report_custom_status() {
  local pane_id="$1" state="$2" custom_status="$3" seq="${4:-}"
  [ -n "$custom_status" ] || return 0
  local meta=(pane report-metadata "$pane_id"
    --source "$ROVO_SOURCE"
    --agent "$ROVO_AGENT"
    --state-label "$state=$custom_status")
  [ -n "$seq" ] && meta+=(--seq "$seq")
  local err
  if ! err="$("$(herdr_bin)" "${meta[@]}" 2>&1 >/dev/null)"; then
    echo "herdr-rovo-dev: 'pane report-metadata' (custom status) failed for pane $pane_id: ${err:-<no output>}" >&2
  fi
  return 0
}

# Report a pane as a Rovo agent with the given state and optional custom status.
# Returns the exit status of the core `report-agent` call (non-zero when Herdr
# rejected it), so callers can tell a real report from a failed one. The custom
# status, if any, is reported best-effort via report_custom_status and never
# affects this return code.
# Return 0 if $1 is a state word the Herdr app's OSC 7501 (Program Status
# Protocol) understands, 1 otherwise. Core stores status as reported and
# never guesses, so an invalid word here must never be sent.
is_valid_osc_state() {
  case "$1" in
    idle | working | done | blocked | error) return 0 ;;
    *) return 1 ;;
  esac
}

# Report this pane's status directly to the Herdr app via OSC 7501, the
# Program Status Protocol (see https://herdr.dev/core/). Unlike the legacy
# `herdr pane report-agent` CLI call below (which talks to the old herdr
# daemon), this writes the escape sequence straight to the controlling
# terminal, which only works when the caller actually shares a tty with the
# Rovo pane - true for bin/rovo-herdr-hook (a child process of Rovo itself),
# but NOT for bin/scan-rovo-panes (a detached plugin action with no reliable
# tty of its own). Callers that cannot vouch for sharing the pane's tty must
# leave $1 empty rather than guess, or they risk writing another pane's
# status onto an unrelated terminal.
#
# Always best-effort: never fails the caller, and silently does nothing when
# there is no controlling terminal or the state is empty/invalid.
# HERDR_OSC_TTY overrides the write target (tests only).
emit_agent_osc7501() {
  local state="$1" kind="${2:-}"
  [ -n "$state" ] || return 0
  is_valid_osc_state "$state" || return 0
  local target="${HERDR_OSC_TTY:-/dev/tty}"
  local payload="state=${state}:app=${ROVO_AGENT}"
  [ -n "$kind" ] && payload="${payload}:kind=${kind}"
  { printf '\e]7501;%s\e\\' "$payload" > "$target"; } 2>/dev/null || true
}

# Resend an OSC 7501 report after a short delay, as a detached background
# job that never blocks the caller's own return.
#
# Used only for on_session_start: confirmed live that the very first OSC
# report can race the Herdr app's own terminal listener attaching to a
# freshly created pane's tty, silently dropping that first write - a later
# event (e.g. on_user_prompt) then reports fine, since the listener has
# attached by then. A short resend closes that one-time startup window
# without delaying session start itself (bin/rovo-herdr-hook must return
# immediately either way).
#
# ROVO_OSC_RETRY_DELAY_SECONDS overrides the delay (tests only), so a test
# can wait for the real background write to land instead of a production
# scale delay.
schedule_delayed_osc_retry() {
  local osc_state="$1" osc_kind="$2" delay="${ROVO_OSC_RETRY_DELAY_SECONDS:-1}"
  ( sleep "$delay"; emit_agent_osc7501 "$osc_state" "$osc_kind" ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

# Map a Rovo hook event name to the OSC 7501 state/kind pair the Herdr app
# understands, printed as "osc_state[ osc_kind]" (osc_kind only present when
# non-empty; osc_state empty means no 7501 equivalent for this event).
#
# Deliberately independent of any pane_id: OSC 7501 is a tty-local protocol
# (see emit_agent_osc7501 above), unlike the legacy `pane report-agent` CLI
# call, which needs a pane_id to target. This lets bin/rovo-herdr-hook still
# report via OSC alone for an event whose pane_id cannot be resolved at all -
# confirmed live for a pane Herdr's own CLI registry does not know about yet
# (e.g. a freshly created Space/split pane: `herdr pane get`/`pane current`
# both report pane_not_found for it), as long as the hook process genuinely
# shares a tty with that pane.
#
# Deliberately does NOT cover the interactive-wait "blocked/question"
# override bin/rovo-herdr-hook applies on top of on_tool_start for the
# ask_user_questions tool: that override depends on a per-pane persisted
# marker (mark_interactive_wait/interactive_wait_active), which has no key to
# read or write without a resolved pane_id. A caller with no pane_id gets
# this function's plain on_tool_start mapping ("working") for that case
# instead - a reporting precision loss, not a correctness bug.
rovo_event_osc_state() {
  case "$1" in
    on_session_start | on_session_end) printf 'idle' ;;
    on_user_prompt | on_tool_start | on_tool_end) printf 'working' ;;
    on_tool_permission) printf 'blocked permission' ;;
    on_error) printf 'error' ;;
    on_complete) printf 'done' ;;
    *) printf '' ;;
  esac
}

# Report a pane's agent state to both Herdr generations:
#
#   - The new Herdr app, via OSC 7501 (emit_agent_osc7501 above). Only
#     attempted when the caller passes a non-empty, valid $6/$7 - see that
#     function's caveat about sharing the pane's tty.
#   - The classic herdr daemon, via the `pane report-agent` CLI below.
#
# The OSC report happens first and independently of the legacy CLI call, so
# it still works in an environment that only has the new Herdr app installed
# (where the `herdr` CLI may be missing or may error out).
#
# Returns the exit status of the legacy `report-agent` call (non-zero when
# Herdr rejected it), so callers can tell a real report from a failed one,
# matching this function's pre-existing contract. The OSC report's success or
# failure never affects this return code.
report_agent() {
  local pane_id="$1" state="$2" custom_status="$3"
  local agent_session_id="${4:-}"
  local message="${5:-}"
  local osc_state="${6:-}"
  local osc_kind="${7:-}"
  local seq
  seq="$(python3 -c 'import time; print(time.time_ns())' 2>/dev/null || true)"

  emit_agent_osc7501 "$osc_state" "$osc_kind"

  local args=(pane report-agent "$pane_id"
    --source "$ROVO_SOURCE"
    --agent "$ROVO_AGENT"
    --state "$state")
  [ -n "$agent_session_id" ] && args+=(--agent-session-id "$agent_session_id")
  [ -n "$message" ] && args+=(--message "$message")
  [ -n "$seq" ] && args+=(--seq "$seq")

  # Report the core agent state. Capture stderr (not silently discard it) so a
  # rejected call is visible in the plugin log rather than failing invisibly.
  local err rc
  if err="$("$(herdr_bin)" "${args[@]}" 2>&1 >/dev/null)"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    echo "herdr-rovo-dev: 'pane report-agent' failed (exit $rc) for pane $pane_id: ${err:-<no output>}" >&2
    return "$rc"
  fi

  report_custom_status "$pane_id" "$state" "$custom_status" "$seq"
  return 0
}

# Resolve the pane associated with a Rovo hook invocation, trying in order:
#   1. HERDR_PANE_ID, inherited from the Herdr pane environment, confirmed via
#      pane_exists - the reliable path when it is still accurate for this
#      process (see caveat below). Confirmed live that a torn-down
#      pane/workspace leaves this pointing at an id Herdr no longer knows
#      about at all, not merely a reassigned one; pane_exists catches that
#      specific case and lets resolution fall through instead of reporting a
#      dead pane.
#   2. A live match of the event's cwd against a pane's foreground cwd and
#      foreground process (manual tests, unusual launchers, or a recovery
#      path for #3 below).
#   3. The session-pane cache (see above), when #1 is stale and #2 cannot
#      currently see Rovo as the pane's foreground process/cwd.
#   4. Herdr's focused pane, guarded against concurrently-running sessions -
#      the only path that can ever resolve a session relayed through Herdr's
#      managed-agent subsystem, which has neither a usable HERDR_PANE_ID nor
#      an OS-visible foreground process to match on (see above).
resolve_rovo_hook_pane() {
  local cwd="${1:-}"
  local session_id="${2:-}"

  if [ -n "${HERDR_PANE_ID:-}" ] && pane_exists "$HERDR_PANE_ID"; then
    cache_session_pane "$session_id" "$HERDR_PANE_ID"
    printf '%s' "$HERDR_PANE_ID"
    return 0
  fi

  if [ -n "$cwd" ]; then
    local pane_id pane_json pane_cwd
    while IFS= read -r pane_id; do
      [ -n "$pane_id" ] || continue
      pane_json="$("$(herdr_bin)" pane get "$pane_id" 2>/dev/null)" || continue
      pane_cwd="$(printf '%s' "$pane_json" \
        | jq -r '.result.pane.foreground_cwd // .result.pane.cwd // empty' 2>/dev/null)" || continue
      if [ "$pane_cwd" = "$cwd" ] && pane_is_rovo "$pane_id"; then
        cache_session_pane "$session_id" "$pane_id"
        printf '%s' "$pane_id"
        return 0
      fi
    done < <(list_pane_ids)
  fi

  # Reuse the pane this exact session resolved on an earlier, successful
  # call - see the session-pane cache comment above for why both paths above
  # can stop working partway through a long-running session.
  if cached_session_pane "$session_id"; then
    return 0
  fi

  # Final fallback: Herdr's own CLI guidance (`herdr --skill`) says that a
  # caller with no usable HERDR_PANE_ID should target the focused pane. A
  # session relayed through Herdr's managed-agent subsystem (herdr-core)
  # never has HERDR_PANE_ID and is never the pane's OS-visible foreground
  # process either, so neither path above can ever resolve it - this is the
  # only path that can, and it is only reached once per session (the result
  # is cached above for every later call).
  #
  # pane_is_rovo cannot gate this candidate, because that same managed-agent
  # relay is exactly why the pane's OS-visible foreground process is not
  # Rovo. Guard against misattribution across concurrently-running Rovo
  # sessions instead: refuse a pane another live session already claimed.
  local current_pane
  current_pane="$("$(herdr_bin)" pane current --current 2>/dev/null \
    | jq -r '.result.pane.pane_id // empty')" || current_pane=""
  if [ -n "$current_pane" ] && ! pane_claimed_by_other_session "$current_pane" "$session_id"; then
    cache_session_pane "$session_id" "$current_pane"
    printf '%s' "$current_pane"
    return 0
  fi

  return 1
}

short_status() {
  printf '%s' "$1" | tr '\n' ' ' | cut -c 1-80
}

rovo_session_is_top_level() {
  local session_id="$1" sessions_dir
  [ -n "$session_id" ] || return 1

  for sessions_dir in \
    "${ROVO_SESSIONS_DIR:-}" \
    "${ROVO_USER_DIR:-$HOME/.rovo}/sessions" \
    "${ROVODEV_USER_DIR:-$HOME/.rovodev}/sessions"; do
    [ -n "$sessions_dir" ] || continue
    [ -d "$sessions_dir/$session_id" ] && return 0
  done

  return 1
}

rovo_session_title() {
  local session_id="$1" sessions_dir metadata_file title
  [ -n "$session_id" ] || return 1

  for sessions_dir in \
    "${ROVO_SESSIONS_DIR:-}" \
    "${ROVO_USER_DIR:-$HOME/.rovo}/sessions" \
    "${ROVODEV_USER_DIR:-$HOME/.rovodev}/sessions"; do
    [ -n "$sessions_dir" ] || continue
    metadata_file="$sessions_dir/$session_id/metadata.json"
    [ -f "$metadata_file" ] || continue
    title="$(jq -r '(.title // empty) | strings' "$metadata_file" 2>/dev/null || true)"
    [ -n "$title" ] || continue
    printf '%s' "$title"
    return 0
  done

  return 1
}

report_session_title() {
  local pane_id="$1" session_id="$2" title
  title="$(rovo_session_title "$session_id")" || title="Rovo Dev"
  "$(herdr_bin)" pane report-metadata "$pane_id" \
    --source "$ROVO_TITLE_SOURCE" \
    --agent "$ROVO_AGENT" \
    --applies-to-source "$ROVO_SOURCE" \
    --display-agent "$title" \
    --clear-token task_name \
    --token "session_title=$title" \
    >/dev/null 2>&1 || true
}

# Resolve the Rovo config.yml to operate on, supporting both CLIs:
#
#   Rovo CLI (new):        ~/.rovo/config.yml
#   Rovo Dev CLI (legacy): ~/.rovodev/config.yml
#
# Resolution order:
#   1. ROVO_DEV_CONFIG_FILE - explicit full path (either CLI).
#   2. ROVODEV_USER_DIR / ROVO_USER_DIR - explicit state dir; its config.yml.
#   3. ~/.rovo/config.yml if it exists (prefer the new CLI).
#   4. ~/.rovodev/config.yml if it exists (legacy fallback).
#   5. ~/.rovo/config.yml as the default target when neither exists yet
#      (so a first-time install lands on the new CLI).
rovo_config_file() {
  if [ -n "${ROVO_DEV_CONFIG_FILE:-}" ]; then
    printf '%s' "$ROVO_DEV_CONFIG_FILE"
    return 0
  fi
  if [ -n "${ROVO_USER_DIR:-}" ]; then
    printf '%s/config.yml' "${ROVO_USER_DIR%/}"
    return 0
  fi
  if [ -n "${ROVODEV_USER_DIR:-}" ]; then
    printf '%s/config.yml' "${ROVODEV_USER_DIR%/}"
    return 0
  fi

  local new_config="$HOME/.rovo/config.yml"
  local legacy_config="$HOME/.rovodev/config.yml"
  if [ -f "$new_config" ]; then
    printf '%s' "$new_config"
  elif [ -f "$legacy_config" ]; then
    printf '%s' "$legacy_config"
  else
    printf '%s' "$new_config"
  fi
}
