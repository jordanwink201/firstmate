#!/usr/bin/env bash
# Shared wake classifier: the common source of truth for captain-relevant status
# tests, declared-external-wait vocabulary, first-progress launch watchdog
# detection, and the working/paused absorb classification that makes no-verb
# signal and stale-pane wakes safe to absorb.
# Sourced by BOTH the always-on watcher
# (bin/fm-watch.sh) and the away-mode daemon (bin/fm-supervise-daemon.sh) so the
# overlapping triage policy lives in one place instead of two copies that can
# drift apart.
#
# Most functions are pure, side-effect-free reads of status files: each takes
# what it needs as arguments and touches no globals beyond the optional
# FM_CAPTAIN_RE override. Consumers layer their own dedup/marker state on top (the
# daemon keeps its escalation-digest seen-markers; the watcher keeps its .seen-*
# signatures).
#
# Two exceptions inspect outside the status file. The absorb classification
# (crew_absorb_class and its working/paused wrappers) reuses bin/fm-crew-state.sh,
# which may make a bounded no-mistakes call, to decide whether a crew that just
# stopped its turn or went stale is working, deliberately paused, or neither.
# The launch watchdog reads state/<id>.meta, the recorded Git worktree, and
# scout report files to detect an ordinary ship/scout task whose spawn_ts is
# older than FM_FIRST_PROGRESS_SECS (default 480s), has no nonblank status line,
# and has no first-progress evidence. If any metadata or Git check is missing or
# ambiguous, it fails safe as non-actionable. Callers run these checks only on
# no-verb signal handling, stale triage, and heartbeat/catch-all scans, never on
# every status read.

# Directory of this library, used to locate the sibling fm-crew-state.sh reader.
# Resolved at source time from BASH_SOURCE so it works whether sourced by a
# bin/ script (which sets its own SCRIPT_DIR) or directly by a test.
_FM_CLASSIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_CLASSIFY_LIB_DIR="."

# The crew current-state reader used for the "provably working" decision.
# Overridable so tests can stub the run-step/pane verdict without a real worktree
# or no-mistakes install; absent, it points at the real sibling script.
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$_FM_CLASSIFY_LIB_DIR/fm-crew-state.sh}"

# Captain-relevant status verbs. A status line carrying any of these is work
# firstmate must see. Lines without these verbs are no-verb signals: the watcher
# absorbs them only with positive provably-working evidence, while the daemon uses
# its away-mode classification. FM_CAPTAIN_RE overrides the whole set when a home
# needs a custom verb vocabulary; absent, this default applies.
FM_CLASSIFY_CAPTAIN_RE_DEFAULT='done:|needs-decision:|needs-retier:|blocked:|failed:|PR ready|checks green|ready in branch|merged'

# The deliberate-external-wait verb. A crew (or firstmate steering it) appends
#   paused: <reason>
# to declare it is intentionally idling on a KNOWN external dependency - an
# upstream release, a vendor rate-limit reset, a scheduled window. Unlike
# `blocked:` (stuck, firstmate must help) an idle `paused:` pane is EXPECTED, so
# the stale path absorbs it instead of escalating a possible wedge. It is
# deliberately NOT in the captain-relevant set above: a pause is a "stop
# wedge-nagging this idle pane" signal, not work to keep surfacing. This constant
# is the ONE definition of the verb; both the watcher and the daemon read it here
# (status_is_paused) rather than hardcoding the literal, so the vocabulary cannot
# drift between the two consumers. FM_CLASSIFY_PAUSED_VERB overrides it.
FM_CLASSIFY_PAUSED_VERB_DEFAULT='paused'

# Bounded re-surface cadence for a declared pause. Far longer than the wedge
# threshold (FM_STALE_ESCALATE_SECS, default 240s) so a deliberate wait is not
# nagged like a wedge, yet finite so a forgotten pause cannot rot invisibly - it
# re-surfaces once for a recheck every window. One hour by default; both consumers
# read FM_PAUSE_RESURFACE_SECS with this default so the cadence has one owner.
# shellcheck disable=SC2034 # Read by the watcher and daemon (fm-watch.sh, fm-supervise-daemon.sh), not this lib.
FM_PAUSE_RESURFACE_SECS_DEFAULT=3600

# First-progress launch watchdog grace. A spawned ordinary crewmate that has not
# written any nonblank status line and has no progress after this window is
# actionable as stuck-at-launch. Tests override FM_FIRST_PROGRESS_SECS directly.
FM_FIRST_PROGRESS_SECS_DEFAULT=480

# The resolution verb that CLOSES a keyed decision opened by needs-decision or
# blocked. See status_open_decisions below for the full durable-decision contract;
# this is the one owner of the verb literal, overridable via FM_CLASSIFY_RESOLVE_VERB.
FM_CLASSIFY_RESOLVE_VERB_DEFAULT='resolved'

# Return the last non-blank line of a status file (empty if missing/blank).
last_status_line() {
  local f=$1
  [ -e "$f" ] || return 0
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1
}

# 0 if the given (last) status line matches a captain-relevant verb.
status_is_captain_relevant() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  status_is_paused "$line" && return 1
  if [ -z "${FM_CAPTAIN_RE+x}" ]; then
    verb=$(status_line_verb "$line")
    case "$verb" in
      done|needs-decision|needs-retier|blocked|failed) return 0 ;;
    esac
  fi
  printf '%s' "$line" | grep -qiE "${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT}"
}

# 0 if a status line's leading verb is the pause verb (paused: <reason>). A pure
# read of the line itself, so the daemon's classify_stale can reuse the last line
# it already read without a fm-crew-state.sh call. Matches only the verb before the
# first colon, so a reason mentioning "paused" elsewhere does not false-match.
status_is_paused() {  # <status-line>
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" ]
}

# --- durable keyed decisions ------------------------------------------------
#
# The status stream is an append-only EVENT log. Reading it last-event-wins
# (last_status_line above) cannot represent "an earlier decision is still open
# after a later, unrelated event": a subsequent done/paused/working line silently
# masks a still-open needs-decision. status_open_decisions is the ONE authoritative
# statement of the contract that fixes this - a needs-decision/blocked line OPENS a
# keyed decision, and ONLY an explicit resolution referencing that key CLOSES it; a
# later unrelated terminal line never clears an open captain decision.
#
# Decision key grammar (backward-compatible with the existing "<verb>: <note>"
# format): an OPTIONAL "[key=<slug>]" token sits between the verb and the colon,
#   needs-decision [key=api-shape]: <summary>
#   resolved       [key=api-shape]: <how it was decided>
# A line with no token uses the key "default", preserving the historical
# one-open-decision-per-task behavior (a bare "resolved:" closes "default").
# The three parsers are pure reads of a single line; the verb parser strips any
# key token before the colon so the leading word is recovered cleanly.
status_line_verb() {  # <status-line> -> leading verb word
  local v=${1%%:*}
  v=${v%%\[key=*}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
}
status_line_note() {  # <status-line> -> text after the first colon, trimmed
  case "$1" in
    *:*) local n=${1#*:}; printf '%s' "${n#"${n%%[![:space:]]*}"}" ;;
    *) printf '%s' "$1" ;;
  esac
}
_fm_decision_key() {  # <status-line> -> key slug, or "default" when no token
  local prefix=${1%%:*} k
  case "$prefix" in
    *\[key=*\]*)
      k=${prefix#*\[key=}
      k=${k%%\]*}
      case "$k" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
        *) printf '%s' "$k" ;;
      esac
      ;;
    *) printf 'default' ;;
  esac
}
# Drop the record for <key> from a newline-terminated "<key>\t<verb>\t<note>" set.
# Portable (no associative arrays) so the fold runs on bash 3.2 as well as 4+.
_fm_decision_drop() {  # <open-set> <key>
  local set=$1 key=$2 line out=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$key"$'\t'*) : ;;
      *) out="${out}${line}"$'\n' ;;
    esac
  done <<EOF
$set
EOF
  printf '%s' "$out"
}
# Fold the WHOLE status stream into the set of decisions still open. Prints one
# TAB-separated "<key>\t<verb>\t<summary>" line per still-open decision, in
# most-recently-opened-last order; prints nothing when none are open. Pure read of
# the file, no globals beyond the optional FM_CLASSIFY_RESOLVE_VERB override. This
# is the durable open-set the fleet snapshot and any point-in-time consumer must use
# instead of trusting the last status line.
status_open_decisions() {  # <status-file>
  local f=$1 line verb key note resolve open='' stripped
  [ -f "$f" ] || return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || continue
    case "$verb" in
      needs-decision|blocked)
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      "$resolve")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done < "$f"
  printf '%s' "$open"
}

# Fold material routed-work phases in the same keyed event stream.
# A working or declared-pause event opens or replaces one phase for its key.
# A later done, failed, needs-decision, blocked, or resolved event carrying that
# key closes the phase, because it has moved to a terminal or separately tracked
# state.
# A bare legacy event uses the default key, preserving one-phase behavior.
# This fold is evidence about whether a parent event was explicitly superseded.
# It is never authoritative current crew state, and consumers must not let an open
# phase outrank a structured home snapshot or fm-crew-state result.
_fm_status_open_activities_stream() {
  local line verb key note resolve open='' stripped pause
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  pause=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || continue
    case "$verb" in
      working|"$pause")
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      done|failed|needs-decision|blocked|"$resolve")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done
  printf '%s' "$open"
}

status_open_activities() {  # <status-file-or-dash>
  local f=$1
  if [ "$f" = - ]; then
    _fm_status_open_activities_stream
    return 0
  fi
  [ -f "$f" ] || return 0
  _fm_status_open_activities_stream < "$f"
}

# task id from a recorded window target, falling back to the tmux-shaped
# "<session>:fm-<id>" form when no metadata state is available.
window_to_task() {
  local w=$1 state=${2:-${STATE:-${FM_STATE_OVERRIDE:-}}} meta mw mt t
  if [ -n "$state" ]; then
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      mw=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      mt=$(grep '^terminal=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
      t=$(basename "$meta")
      t=${t%.meta}
      printf '%s' "$t"
      return 0
    done
  fi
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}

_fm_classify_meta_value() {  # <meta-file> <key>
  local meta=$1 key=$2
  [ -f "$meta" ] || return 0
  grep "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

_fm_status_has_nonblank_line() {  # <status-file>
  local f=$1
  [ -f "$f" ] || return 1
  grep -q '[^[:space:]]' "$f" 2>/dev/null
}

_fm_first_progress_secs() {
  local secs=${FM_FIRST_PROGRESS_SECS:-$FM_FIRST_PROGRESS_SECS_DEFAULT}
  case "$secs" in
    ''|*[!0-9]*) secs=$FM_FIRST_PROGRESS_SECS_DEFAULT ;;
  esac
  printf '%s' "$secs"
}

_fm_launch_default_base_ref() {  # <meta-file>
  local meta=$1 wt project ref branch base
  wt=$(_fm_classify_meta_value "$meta" worktree)
  project=$(_fm_classify_meta_value "$meta" project)
  [ -n "$wt" ] && [ -n "$project" ] || return 1
  [ -d "$wt" ] && [ -d "$project" ] || return 1
  ref=$(git -C "$project" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    base=$ref
  else
    base=
    for branch in main master; do
      if git -C "$project" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
        base=$branch
        break
      fi
    done
    [ -n "$base" ] || return 1
  fi
  git -C "$wt" rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1 || return 1
  printf '%s' "$base"
}

_fm_launch_worktree_has_progress() {  # <meta-file>; 0 progress, 1 no progress, 2 unsafe
  local meta=$1 wt status base ahead
  wt=$(_fm_classify_meta_value "$meta" worktree)
  [ -n "$wt" ] && [ -d "$wt" ] || return 2
  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 2
  status=$(git -C "$wt" status --porcelain --untracked-files=normal 2>/dev/null) || return 2
  [ -z "$status" ] || return 0
  base=$(_fm_launch_default_base_ref "$meta") || return 2
  ahead=$(git -C "$wt" rev-list --count "$base..HEAD" 2>/dev/null) || return 2
  case "$ahead" in
    ''|*[!0-9]*) return 2 ;;
  esac
  [ "$ahead" -gt 0 ] && return 0
  return 1
}

_fm_classify_file_mtime() {  # <file>
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

_fm_launch_data_dir() {  # <state-dir>
  local state=$1
  if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
    printf '%s' "$FM_DATA_OVERRIDE"
  elif [ -n "${FM_HOME:-}" ]; then
    printf '%s/data' "$FM_HOME"
  else
    case "$state" in
      */state) printf '%s/data' "${state%/state}" ;;
      *) return 1 ;;
    esac
  fi
}

_fm_launch_scout_report_has_progress() {  # <task-id> <state-dir> <spawn-ts>; 0 progress, 1 no progress, 2 unsafe
  local id=$1 state=$2 spawn_ts=$3 data report mtime rc
  case "$id" in
    ''|*/*) return 2 ;;
  esac
  data=$(_fm_launch_data_dir "$state") || return 1
  report="$data/$id/report.md"
  [ -e "$report" ] || return 1
  [ -f "$report" ] || return 2
  mtime=$(_fm_classify_file_mtime "$report") || return 2
  case "$mtime" in
    ''|*[!0-9]*) return 2 ;;
  esac
  if grep -q '[^[:space:]]' "$report" 2>/dev/null; then
    :
  else
    rc=$?
    [ "$rc" -eq 1 ] && return 1
    return 2
  fi
  [ "$mtime" -gt "$spawn_ts" ] && return 0
  return 1
}

launch_watchdog_reason() {  # <task-id> <state-dir>
  local id=$1 state=$2 meta kind spawn_ts now age first_secs meta_state progress_rc
  [ -n "$id" ] && [ -n "$state" ] || return 1
  meta="$state/$id.meta"
  [ -f "$meta" ] || return 1
  kind=$(_fm_classify_meta_value "$meta" kind)
  case "$kind" in
    ship|scout) ;;
    *) return 1 ;;
  esac
  meta_state=$(_fm_classify_meta_value "$meta" state)
  case "$meta_state" in
    terminal|archived|done) return 1 ;;
  esac
  spawn_ts=$(_fm_classify_meta_value "$meta" spawn_ts)
  case "$spawn_ts" in
    ''|*[!0-9]*) return 1 ;;
  esac
  now=$(date +%s)
  case "$now" in
    ''|*[!0-9]*) return 1 ;;
  esac
  age=$((now - spawn_ts))
  [ "$age" -ge 0 ] || return 1
  first_secs=$(_fm_first_progress_secs)
  [ "$age" -ge "$first_secs" ] || return 1
  _fm_status_has_nonblank_line "$state/$id.status" && return 1
  if [ "$kind" = scout ]; then
    _fm_launch_scout_report_has_progress "$id" "$state" "$spawn_ts"
    progress_rc=$?
    case "$progress_rc" in
      0) return 1 ;;
      1) ;;
      *) return 1 ;;
    esac
  fi
  _fm_launch_worktree_has_progress "$meta"
  progress_rc=$?
  case "$progress_rc" in
    0) return 1 ;;
    1) ;;
    *) return 1 ;;
  esac
  case "$kind" in
    scout)
      printf 'stuck-at-launch: %s no first progress after %ss (status absent/empty; no dirty files, branch commits, or report progress)' "$id" "$age" ;;
    *)
      printf 'stuck-at-launch: %s no first progress after %ss (status absent/empty; no dirty files or branch commits)' "$id" "$age" ;;
  esac
  return 0
}

launch_watchdog_signature() {  # <task-id> <state-dir>
  local id=$1 state=$2 meta spawn_ts
  launch_watchdog_reason "$id" "$state" >/dev/null || return 1
  meta="$state/$id.meta"
  spawn_ts=$(_fm_classify_meta_value "$meta" spawn_ts)
  [ -n "$spawn_ts" ] || return 1
  printf 'stuck-at-launch:%s:%s' "$id" "$spawn_ts"
}

signal_launch_watchdog_reason() {  # <state-dir> <file> ...
  local state=$1 f base task seen="" reason found="" sep=""
  shift
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.status)     task=${base%.status} ;;
      *.turn-ended) task=${base%.turn-ended} ;;
      *)            continue ;;
    esac
    [ -n "$task" ] || continue
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    reason=$(launch_watchdog_reason "$task" "$state") || continue
    printf '%s%s' "$sep" "$reason"
    found=1
    sep=' | '
  done
  [ -n "$found" ]
}

scan_launch_watchdog_tasks() {  # <state-dir> -> task<TAB>window<TAB>reason
  local state=$1 meta task reason window terminal
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    task=$(basename "$meta")
    task=${task%.meta}
    reason=$(launch_watchdog_reason "$task" "$state") || continue
    terminal=$(_fm_classify_meta_value "$meta" terminal)
    window=${terminal:-$(_fm_classify_meta_value "$meta" window)}
    printf '%s\t%s\t%s\n' "$task" "$window" "$reason"
  done
}

# 0 (actionable) if ANY status file listed in a "signal:" wake carries a
# captain-relevant last line; 1 otherwise. Pass the space-separated file list that
# follows the "signal:" prefix. Non-.status arguments (e.g. .turn-ended markers,
# which never carry a verb) are skipped. A 1 here is NOT "benign" on its own: a
# no-verb signal (a bare turn-end, a working: note) is only benign when the crew is
# also provably working (signal_crew_provably_working below); otherwise it surfaces.
signal_reason_is_actionable() {  # <file> ...
  local f last
  for f in "$@"; do
    [ -e "$f" ] || continue
    case "$f" in *.status) ;; *) continue ;; esac
    last=$(last_status_line "$f")
    [ -n "$last" ] || continue
    status_is_captain_relevant "$last" && return 0
  done
  return 1
}

# Classify WHY an idle/stale crew MIGHT be safely absorbed instead of surfaced,
# from bin/fm-crew-state.sh's one authoritative current-state line
# ("state: <s> · source: <src> · <detail>"). Prints exactly one token:
#   working - an actively-running no-mistakes step (running/fixing/ci) or a busy
#             pane; the crew is legitimately mid-work on a static-looking pane
#             (e.g. waiting on CI);
#   paused  - the crew's authoritative current state is a declared external-wait
#             pause (paused:), which is EXPECTED to idle;
#   none    - neither, so the wake must surface (a stopped/finished/parked/failed/
#             torn-down/unknown crew, or an unreadable verdict).
# One fm-crew-state.sh read serves BOTH absorb reasons at once. Reading the state
# authoritatively (not the status log) is what keeps run-step precedence: a crew
# that appended paused: but then STARTED a run reports working, never paused.
# NOT a pure read: fm-crew-state.sh may make a bounded no-mistakes call, so callers
# run it only on no-verb signal and first-sighting stale paths, never every wake.
# FM_CREW_STATE_BIN lets tests stub the verdict.
crew_absorb_class() {  # <id>
  local id=$1 line state src
  [ -n "$id" ] || { printf 'none'; return; }
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) printf 'none'; return ;; esac
  state=${line#state: }; state=${state%% *}
  if [ "$state" = paused ]; then printf 'paused'; return; fi
  if [ "$state" = working ]; then
    src=${line#*source: }; src=${src%% *}
    case "$src" in run-step|pane) printf 'working'; return ;; esac
  fi
  printf 'none'
}

# 0 if crew <id> shows POSITIVE evidence it is still working (crew_absorb_class
# reports `working`). This is the "provably working" predicate at the heart of
# absorb-only-when-provably-working: a no-verb turn-end or stale wake is absorbed
# ONLY when this returns 0, and SURFACED otherwise (the crew may be done, waiting
# on a decision, or wedged). For stale panes it is checked before trusting the
# status log so a pre-validation captain-relevant line does not override an active
# run. See crew_absorb_class for the exact working/paused/none decision.
crew_is_provably_working() {  # <id>
  [ "$(crew_absorb_class "$1")" = working ]
}

# 0 if crew <id>'s authoritative current state is a declared external-wait pause.
# The stale path absorbs such a crew (on a long re-surface cadence) instead of
# escalating a possible wedge.
crew_is_paused() {  # <id>
  [ "$(crew_absorb_class "$1")" = paused ]
}

# 0 (benign/absorb) if EVERY task referenced by a no-verb "signal:" wake is provably
# working; 1 (actionable/surface) if any is not, or no task can be resolved. Pass the
# same space-separated file list as signal_reason_is_actionable. Files are mapped to
# task ids by stripping the .status / .turn-ended suffix; a no-verb wake with nothing
# provably working must surface, so an empty/unresolvable list returns 1.
signal_crew_provably_working() {  # <file> ...
  local f base task seen=""
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.status)     task=${base%.status} ;;
      *.turn-ended) task=${base%.turn-ended} ;;
      *)            continue ;;
    esac
    [ -n "$task" ] || continue
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    if [ -n "${STATE:-}" ] && launch_watchdog_reason "$task" "$STATE" >/dev/null 2>&1; then
      return 1
    fi
    crew_is_provably_working "$task" || return 1
  done
  [ -n "$seen" ] || return 1
  return 0
}

# 0 (terminal/actionable) if a stale window's last status line is
# captain-relevant; 1 otherwise, including the no-status case. A 1 only means
# "non-terminal"; the always-on watcher then applies crew_is_provably_working,
# while the away-mode daemon applies its persistence recheck.
stale_is_terminal() {  # <window> <state>
  local win=$1 state=$2 last
  last=$(last_status_line "$state/$(window_to_task "$win" "$state").status")
  [ -n "$last" ] && status_is_captain_relevant "$last"
}

# Print "<file>\t<task>\t<last-line>" for every state/*.status whose last line is
# captain-relevant. This is the cheap fleet-scan both supervisors run as a
# catch-all backstop for a captain-relevant status the per-wake path might miss.
# No dedup is applied here: each consumer dedupes against its own seen-state (the
# daemon against .subsuper-seen-status-*, the watcher against .seen-* signatures).
scan_captain_relevant_statuses() {  # <state>
  local state=$1 f last task
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    status_is_captain_relevant "$last" || continue
    task=$(basename "$f"); task="${task%.status}"
    printf '%s\t%s\t%s\n' "$f" "$task" "$last"
  done
  return 0
}
