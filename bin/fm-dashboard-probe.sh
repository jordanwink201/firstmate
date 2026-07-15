#!/usr/bin/env bash
# fm-dashboard-probe.sh - read-only fleet-dashboard data probe.
#
# Emits a normalized JSON snapshot proving what Mockup A can live-update from
# current Firstmate state, plus the approximate replay sources available for a
# Mockup D timeline. No AI calls, no writes.
#
# Each fleet and station task row also carries a backward-compatible "pipeline"
# object: profile (cad_no_mistakes, direct_pr, local_only, scout_report,
# secondmate, or unknown fallback), main_stage, stage_label, next_human_action,
# source_confidence (live, approximate, or unknown; teardown-sourced and
# archived rows are approximate), and an evidence array. Only cad_no_mistakes
# rows get a non-null validation_branch (no-mistakes step, status, findings,
# pr_url, superseded_status_log); every other profile emits validation_branch
# null. Missing worktrees, stale or superseded status logs, and landed/history
# arrival rows degrade confidence or stage gracefully instead of erroring.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
ARRIVALS="$DATA/dashboard-arrivals.jsonl"
CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

MODE=json
case "${1:-}" in
  ""|--json) MODE=json ;;
  --report) MODE=report ;;
  -h|--help)
    cat <<'EOF'
usage: fm-dashboard-probe.sh [--json|--report]

Read-only probe for the Firstmate fleet dashboard mockups.
Default output is JSON with fleet, stations, and replay_sources sections.
--report prints a short findings report instead.
EOF
    exit 0
    ;;
  *)
    printf 'usage: fm-dashboard-probe.sh [--json|--report]\n' >&2
    exit 2
    ;;
esac

trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

json_string() {
  local s=${1:-} _cc_i _cc_char _cc_esc
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  if [[ $s == *[$'\x01'-$'\x1f']* ]]; then
    for _cc_i in 1 2 3 4 5 6 7 8 11 12 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
      printf -v _cc_char '%b' "\\0$(printf '%03o' "$_cc_i")"
      printf -v _cc_esc '\\u%04x' "$_cc_i"
      s=${s//"$_cc_char"/$_cc_esc}
    done
  fi
  printf '"%s"' "$s"
}

json_number_or_null() {
  case "${1:-}" in
    ""|*[!0-9]*) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
}

stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

last_nonblank_line() {
  [ -f "$1" ] || return 1
  awk 'NF { line = $0 } END { if (line != "") print line }' "$1"
}

status_verb_of() {
  local v=${1%%:*}
  trim "$v"
}

status_note_of() {
  case "${1:-}" in
    *:*) trim "${1#*:}" ;;
    *) trim "${1:-}" ;;
  esac
}

collapse_spaces() {
  printf '%s\n' "${1:-}" | awk '{$1=$1; print}'
}

clean_display_text() {
  local s
  s=$(trim "${1:-}")
  [ -n "$s" ] || return 0
  s=$(printf '%s\n' "$s" | sed 's/\*\*//g; s/__//g; s/`//g; s/^#[[:space:]]*//')
  collapse_spaces "$s"
}

short_display_text() {
  local s limit
  s=$(clean_display_text "${1:-}")
  limit=${2:-120}
  if [ "${#s}" -gt "$limit" ] && [ "$limit" -gt 3 ]; then
    printf '%s...' "${s:0:$((limit - 3))}"
  else
    printf '%s' "$s"
  fi
}

backlog_title_for() {
  local id=$1 line title
  [ -f "$DATA/backlog.md" ] || return 0
  line=$(awk -v id="$id" '
    BEGIN {
      p1 = "- [ ] " id " - "
      p2 = "- [x] " id " - "
      p3 = "- [X] " id " - "
    }
    index($0, p1) == 1 { print substr($0, length(p1) + 1); exit }
    index($0, p2) == 1 { print substr($0, length(p2) + 1); exit }
    index($0, p3) == 1 { print substr($0, length(p3) + 1); exit }
  ' "$DATA/backlog.md")
  [ -n "$line" ] || return 0
  title=$(printf '%s\n' "$line" | sed -E 's/[[:space:]]+\((repo:|kind:|since |done )[^)]*\)//g')
  short_display_text "$title" 120
}

brief_title_for() {
  local id=$1 brief title
  brief="$DATA/$id/brief.md"
  [ -f "$brief" ] || return 0
  title=$(awk '
    /^# Task[[:space:]]*$/ { in_task = 1; next }
    in_task && /^#/ { exit }
    in_task && NF { print; exit }
  ' "$brief")
  short_display_text "$title" 120
}

display_title_for() {
  local meta=$1 id=$2 status_note=$3 title
  title=$(short_display_text "$(fm_meta_get "$meta" title)" 120)
  [ -n "$title" ] || title=$(backlog_title_for "$id")
  [ -n "$title" ] || title=$(brief_title_for "$id")
  [ -n "$title" ] || title=$(short_display_text "$status_note" 120)
  printf '%s' "${title:-$id}"
}

display_subtitle_for() {
  local current_detail=$1 status_note=$2 subtitle
  case "$current_detail" in
    ""|"no current-state source available"|fake\ default|backend\ target\ gone*|worktree\ gone*)
      subtitle=
      ;;
    *)
      subtitle=$current_detail
      ;;
  esac
  [ -n "$subtitle" ] || subtitle=$status_note
  short_display_text "$subtitle" 96
}

attention_for() {
  local station=$1 current_state=$2 status_verb=$3
  case "$station" in
    needs_captain) printf 'needs_action'; return ;;
    arrived_today) printf 'done'; return ;;
  esac
  case "$status_verb" in
    needs-decision|blocked|failed|needs_captain) printf 'needs_action'; return ;;
    done) printf 'done'; return ;;
  esac
  case "$current_state" in
    done) printf 'done' ;;
    blocked|failed|parked) printf 'needs_action' ;;
    *) printf 'normal' ;;
  esac
}

git_branch_for() {
  local worktree=$1 branch
  [ -n "$worktree" ] && [ -d "$worktree" ] || return 0
  branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  printf '%s' "$branch"
}

git_commit_short_for() {
  local worktree=$1
  [ -n "$worktree" ] && [ -d "$worktree" ] || return 0
  git -C "$worktree" rev-parse --short=9 HEAD 2>/dev/null || true
}

pr_url_from_text() {
  printf '%s\n' "${1:-}" | grep -Eo 'https://github\.com/[^[:space:])]+/pull/[0-9]+' | head -1 || true
}

pr_url_for() {
  local meta=$1 status_line=$2 pr
  pr=$(fm_meta_get "$meta" pr)
  [ -n "$pr" ] || pr=$(fm_meta_get "$meta" pr_url)
  [ -n "$pr" ] || pr=$(pr_url_from_text "$status_line")
  printf '%s' "$pr"
}

crew_field_state() {
  case "${1:-}" in
    state:\ *) printf '%s' "${1#state: }" | awk '{ print $1 }' ;;
  esac
}

crew_field_source() {
  printf '%s\n' "${1:-}" | sed -n 's/.*source: \([^[:space:]]*\).*/\1/p' | head -1
}

crew_field_detail() {
  local line=${1:-} source=${2:-} rest
  [ -n "$source" ] || return 0
  rest=${line#*"source: $source"}
  rest=$(printf '%s' "$rest" | sed 's/^[[:space:]]*·[[:space:]]*//')
  trim "$rest"
}

validation_detail() {
  printf '%s\n' "${1:-}" | grep -Eiq 'validat|(^|[^[:alpha:]])ci([^[:alpha:]]|$)|checks?|tests?|lint|typecheck|build|no-mistakes|gate'
}

station_for() {
  local current_state=$1 current_source=$2 current_detail=$3 status_verb=$4 worktree=$5 liveness=$6 target=$7
  if [ "$current_state" = "done" ] || [ "$status_verb" = "done" ]; then
    printf 'arrived_today|done signal is available from current state or status log'
    return
  fi
  case "$current_state" in
    parked|blocked|failed)
      printf 'needs_captain|current state requires captain attention'
      return
      ;;
  esac
  case "$status_verb" in
    needs-decision|blocked|failed)
      printf 'needs_captain|latest status event requires captain attention'
      return
      ;;
  esac
  if [ "$current_state" = working ]; then
    if [ "$current_source" = run-step ] && validation_detail "$current_detail"; then
      printf 'gate_run|working run-step has validation or test wording'
    else
      printf 'underway|working source has no validation or test wording'
    fi
    return
  fi
  if [ -z "$worktree" ] || [ ! -d "$worktree" ]; then
    printf 'unknown|worktree is missing or torn down'
    return
  fi
  if [ -z "$target" ] || [ "$liveness" != alive ]; then
    printf 'unknown|backend target is missing, dead, or uncertain'
    return
  fi
  printf 'casting_off|live metadata exists but no strong current state is available yet'
}

stage_label_for() {
  case "${1:-}" in
    intake) printf 'Intake' ;;
    mirror) printf 'Mirror' ;;
    spawn) printf 'Spawn' ;;
    run_work) printf 'Run Work' ;;
    validation_gate) printf 'Validation Gate' ;;
    review_ready) printf 'Review Ready' ;;
    landed) printf 'Landed' ;;
    human_followthrough) printf 'Human Followthrough' ;;
    *) printf 'Unknown' ;;
  esac
}

pipeline_profile_for() {
  local kind=$1 mode=$2
  if [ "$kind" = secondmate ] || [ "$mode" = secondmate ]; then
    printf 'secondmate'
    return
  fi
  if [ "$kind" = scout ]; then
    printf 'scout_report'
    return
  fi
  case "$mode" in
    no-mistakes) printf 'cad_no_mistakes' ;;
    direct-PR) printf 'direct_pr' ;;
    local-only) printf 'local_only' ;;
    *) printf 'unknown' ;;
  esac
}

text_has() {
  printf '%s\n' "${1:-}" | grep -Eiq "$2"
}

pipeline_findings_count() {
  printf '%s\n' "${1:-}" | sed -nE 's/.*[^0-9]([0-9]+) finding\(s\).*/\1/p' | head -1
}

validation_step_from_detail() {
  local detail=$1 step
  step=$(printf '%s\n' "$detail" | sed -nE 's/.*parked at ([^:() ]+).*/\1/p' | head -1)
  if [ -n "$step" ]; then
    printf '%s' "$step"
    return
  fi
  if text_has "$detail" '(^|[^[:alpha:]])ci([^[:alpha:]]|$)|checks green|PR ready'; then
    printf 'ci'
  elif text_has "$detail" 'review'; then
    printf 'review'
  elif text_has "$detail" 'test|lint|typecheck|build'; then
    printf 'test'
  elif text_has "$detail" 'validat|gate|run active|run completed|run passed|run failed'; then
    printf 'validation'
  fi
}

validation_status_for() {
  local current_state=$1 detail=$2
  case "$current_state" in
    parked) printf 'awaiting_approval'; return ;;
    failed)
      if text_has "$detail" 'cancelled'; then printf 'cancelled'; else printf 'failed'; fi
      return
      ;;
    done)
      if text_has "$detail" 'checks green|PR ready'; then
        printf 'checks-passed'
      elif text_has "$detail" 'passed|merged|closed|landed'; then
        printf 'passed'
      else
        printf 'completed'
      fi
      return
      ;;
  esac
  if text_has "$detail" 'validating \(fixing\)|run active \(fixing\)'; then
    printf 'fixing'
  elif text_has "$detail" 'validating \(running\)|validating \(background run\)|ci running|run active \(running\)|run active'; then
    printf 'running'
  else
    printf '%s' "${current_state:-unknown}"
  fi
}

pipeline_source_confidence_for() {
  local source=$1 current_source=$2 current_state=$3 worktree=$4 liveness=$5 target=$6 stage=$7
  if [ "$source" = teardown ] || [ "$liveness" = archived ]; then
    printf 'approximate'
    return
  fi
  case "$stage" in
    landed|review_ready)
      case "$current_source" in
        run-step|pane) printf 'live'; return ;;
        status-log) printf 'approximate'; return ;;
      esac
      ;;
  esac
  if [ "$current_state" != "done" ]; then
    if [ -z "$worktree" ] || [ ! -d "$worktree" ] || [ -z "$target" ] || [ "$liveness" != alive ]; then
      printf 'unknown'
      return
    fi
  fi
  case "$current_source" in
    run-step|pane) printf 'live' ;;
    status-log) printf 'approximate' ;;
    *) printf 'unknown' ;;
  esac
}

pipeline_stage_for() {
  local profile=$1 station=$2 current_state=$3 current_detail=$4 status_verb=$5 status_note=$6 pr_url=$7 source=$8
  local text="$current_detail $status_note"
  if [ "$source" = teardown ]; then
    printf 'landed'
    return
  fi
  if [ "$station" = unknown ]; then
    printf 'unknown'
    return
  fi
  case "$profile" in
    cad_no_mistakes)
      if [ "$current_state" = "done" ] || [ "$status_verb" = "done" ] || [ "$station" = arrived_today ]; then
        if text_has "$text" 'checks green|PR ready'; then
          printf 'review_ready'
        elif text_has "$text" 'passed|merged|closed|landed'; then
          printf 'landed'
        else
          printf 'review_ready'
        fi
      elif [ "$current_state" = parked ] || [ "$current_state" = failed ] || [ "$station" = gate_run ]; then
        printf 'validation_gate'
      elif [ "$station" = needs_captain ]; then
        printf 'validation_gate'
      elif [ "$station" = casting_off ]; then
        printf 'spawn'
      else
        printf 'run_work'
      fi
      ;;
    direct_pr)
      if [ "$station" = arrived_today ] && text_has "$text" 'landed|merged|closed'; then
        printf 'landed'
      elif [ -n "$pr_url" ] || [ "$current_state" = "done" ] || [ "$status_verb" = "done" ]; then
        printf 'review_ready'
      elif [ "$station" = needs_captain ]; then
        printf 'human_followthrough'
      elif [ "$station" = casting_off ]; then
        printf 'spawn'
      else
        printf 'run_work'
      fi
      ;;
    local_only)
      if [ "$station" = arrived_today ] && text_has "$text" 'landed|merged|local main'; then
        printf 'landed'
      elif [ "$current_state" = "done" ] || [ "$status_verb" = "done" ]; then
        printf 'review_ready'
      elif [ "$station" = needs_captain ]; then
        printf 'human_followthrough'
      elif [ "$station" = casting_off ]; then
        printf 'spawn'
      else
        printf 'run_work'
      fi
      ;;
    scout_report)
      if [ "$current_state" = "done" ] || [ "$status_verb" = "done" ]; then
        printf 'review_ready'
      elif [ "$station" = arrived_today ]; then
        printf 'review_ready'
      elif [ "$station" = needs_captain ]; then
        printf 'human_followthrough'
      elif [ "$station" = casting_off ]; then
        printf 'spawn'
      else
        printf 'run_work'
      fi
      ;;
    secondmate)
      if [ "$station" = unknown ]; then printf 'unknown'; else printf 'run_work'; fi
      ;;
    *)
      if [ "$station" = casting_off ]; then printf 'spawn'; else printf 'unknown'; fi
      ;;
  esac
}

pipeline_next_action_for() {
  local profile=$1 stage=$2 current_state=$3 status_verb=$4 confidence=$5 superseded=$6
  local needs_attention=false
  case "$current_state:$status_verb" in
    parked:*|failed:*|blocked:*|*:needs-decision|*:blocked|*:failed) needs_attention=true ;;
  esac
  if [ "$stage" = unknown ]; then
    printf 'monitor only'
    return
  fi
  if [ "$confidence" = unknown ] && [ "$needs_attention" != true ]; then
    printf 'monitor only'
    return
  fi
  case "$profile:$stage" in
    cad_no_mistakes:validation_gate)
      if [ "$superseded" = true ]; then
        printf 'wait for validation'
      elif [ "$needs_attention" = true ]; then
        printf 'answer gate finding'
      else
        printf 'wait for validation'
      fi
      ;;
    cad_no_mistakes:review_ready|direct_pr:review_ready) printf 'review PR' ;;
    local_only:review_ready) printf 'review local branch' ;;
    scout_report:review_ready) printf 'review scout report' ;;
    *:landed|*:human_followthrough) printf 'move/comment in Basecamp' ;;
    *:run_work|*:spawn|*:intake|*:mirror) printf 'monitor only' ;;
    *) printf 'monitor only' ;;
  esac
}

set_pipeline_fields() {
  local kind=$1 mode=$2 station=$3 current_state=$4 current_source=$5 current_detail=$6 status_verb=$7 status_note=$8 worktree=$9
  local liveness=${10} target=${11} pr_url=${12} source=${13}
  PIPE_PROFILE=$(pipeline_profile_for "$kind" "$mode")
  PIPE_MAIN_STAGE=$(pipeline_stage_for "$PIPE_PROFILE" "$station" "$current_state" "$current_detail" "$status_verb" "$status_note" "$pr_url" "$source")
  PIPE_STAGE_LABEL=$(stage_label_for "$PIPE_MAIN_STAGE")
  PIPE_SOURCE_CONFIDENCE=$(pipeline_source_confidence_for "$source" "$current_source" "$current_state" "$worktree" "$liveness" "$target" "$PIPE_MAIN_STAGE")
  PIPE_VALIDATION_STEP=
  PIPE_VALIDATION_STATUS=
  PIPE_VALIDATION_FINDINGS=
  PIPE_VALIDATION_PR_URL=$pr_url
  PIPE_VALIDATION_SUPERSEDED=false
  PIPE_EVIDENCE=()
  [ -n "$kind" ] && PIPE_EVIDENCE+=("meta.kind=$kind")
  [ -n "$mode" ] && PIPE_EVIDENCE+=("meta.mode=$mode")
  [ -n "$source" ] && PIPE_EVIDENCE+=("source=$source")
  [ -n "$current_state" ] && PIPE_EVIDENCE+=("current_state.state=$current_state")
  [ -n "$current_source" ] && PIPE_EVIDENCE+=("current_state.source=$current_source")
  [ -n "$station" ] && PIPE_EVIDENCE+=("station=$station")
  [ -n "$status_verb" ] && PIPE_EVIDENCE+=("status.verb=$status_verb")
  [ -n "$pr_url" ] && PIPE_EVIDENCE+=("pr_url=present")
  if [ -z "$worktree" ] || { [ -n "$worktree" ] && [ ! -d "$worktree" ]; }; then
    PIPE_EVIDENCE+=("worktree=missing")
  fi
  if [ -n "$target" ] && [ "$liveness" != alive ] && [ "$liveness" != archived ]; then
    PIPE_EVIDENCE+=("backend_liveness=$liveness")
  fi
  if text_has "$current_detail" 'status-log superseded'; then
    PIPE_VALIDATION_SUPERSEDED=true
  fi
  PIPE_NEXT_HUMAN_ACTION=$(pipeline_next_action_for "$PIPE_PROFILE" "$PIPE_MAIN_STAGE" "$current_state" "$status_verb" "$PIPE_SOURCE_CONFIDENCE" "$PIPE_VALIDATION_SUPERSEDED")
  if [ "$PIPE_PROFILE" = cad_no_mistakes ]; then
    PIPE_VALIDATION_STEP=$(validation_step_from_detail "$current_detail")
    PIPE_VALIDATION_STATUS=$(validation_status_for "$current_state" "$current_detail")
    PIPE_VALIDATION_FINDINGS=$(pipeline_findings_count "$current_detail")
  fi
}

print_pipeline_evidence_json() {
  local first=1 item
  printf '['
  for item in "${PIPE_EVIDENCE[@]:-}"; do
    [ -n "$item" ] || continue
    [ "$first" -eq 1 ] || printf ', '
    first=0
    json_string "$item"
  done
  printf ']'
}

print_pipeline_json() {
  printf '      "pipeline": {\n'
  printf '        "profile": %s,\n' "$(json_string "$PIPE_PROFILE")"
  printf '        "main_stage": %s,\n' "$(json_string "$PIPE_MAIN_STAGE")"
  printf '        "stage_label": %s,\n' "$(json_string "$PIPE_STAGE_LABEL")"
  printf '        "next_human_action": %s,\n' "$(json_string "$PIPE_NEXT_HUMAN_ACTION")"
  printf '        "source_confidence": %s,\n' "$(json_string "$PIPE_SOURCE_CONFIDENCE")"
  printf '        "evidence": %s,\n' "$(print_pipeline_evidence_json)"
  if [ "$PIPE_PROFILE" = cad_no_mistakes ]; then
    printf '        "validation_branch": {\n'
    printf '          "name": "no-mistakes",\n'
    printf '          "step": %s,\n' "$(json_string "$PIPE_VALIDATION_STEP")"
    printf '          "status": %s,\n' "$(json_string "$PIPE_VALIDATION_STATUS")"
    printf '          "findings": %s,\n' "$(json_number_or_null "$PIPE_VALIDATION_FINDINGS")"
    printf '          "pr_url": %s,\n' "$(json_string "$PIPE_VALIDATION_PR_URL")"
    printf '          "superseded_status_log": %s\n' "$PIPE_VALIDATION_SUPERSEDED"
    printf '        }\n'
  else
    printf '        "validation_branch": null\n'
  fi
  printf '      }'
}

task_id_seen() {
  local needle=$1 id
  for id in "${STATION_IDS[@]:-}"; do
    [ "$id" = "$needle" ] && return 0
  done
  return 1
}

arrival_local_day() {
  local ts=$1
  [ -n "$ts" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    date -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" '+%Y-%m-%d' 2>/dev/null && return 0
  else
    date -d "$ts" '+%Y-%m-%d' 2>/dev/null && return 0
  fi
  printf '%s\n' "${ts%%T*}"
}

print_arrival_fleet_rows() {
  local today row fields id arrived_at display_title latest_status pr_url branch commit_short project worktree mode
  local status_verb status_note first_ref
  [ -f "$ARRIVALS" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  today=$(date '+%Y-%m-%d')
  # shellcheck disable=SC2094 # This function writes JSON to stdout, not to the arrivals file it reads.
  while IFS= read -r row || [ -n "$row" ]; do
    [ -n "$row" ] || continue
    fields=$(printf '%s\n' "$row" | jq -r '[.task_id // .id // "", .arrived_at // "", .display_title // (.task_id // .id // ""), .latest_status // "", .pr_url // "", .branch // "", .commit_short // "", .project // "", .worktree // "", .mode // ""] | @tsv' 2>/dev/null) || continue
    IFS=$'\t' read -r id arrived_at display_title latest_status pr_url branch commit_short project worktree mode <<EOF
$fields
EOF
    [ -n "$id" ] || continue
    task_id_seen "$id" && continue
    [ "$(arrival_local_day "$arrived_at")" = "$today" ] || continue
    status_verb=$(status_verb_of "$latest_status")
    status_note=$(status_note_of "$latest_status")
    [ -n "$mode" ] || mode=no-mistakes
    set_pipeline_fields ship "$mode" arrived_today "done" arrival-ledger "successful ship teardown" "$status_verb" "$status_note" "$worktree" archived "" "$pr_url" teardown
    STATION_IDS+=("$id")
    STATION_VALUES+=("arrived_today")
    STATION_REASONS+=("archived successful ship teardown from today's arrival ledger")
    [ "$first" -eq 1 ] || printf ',\n'
    first=0
    first_ref="$ARRIVALS"
    printf '    {\n'
    printf '      "task_id": %s,\n' "$(json_string "$id")"
    printf '      "display_title": %s,\n' "$(json_string "$display_title")"
    printf '      "display_subtitle": %s,\n' "$(json_string "$status_note")"
    printf '      "attention": "done",\n'
    printf '      "branch": %s,\n' "$(json_string "$branch")"
    printf '      "commit_short": %s,\n' "$(json_string "$commit_short")"
    printf '      "pr_url": %s,\n' "$(json_string "$pr_url")"
    printf '      "meta_path": "",\n'
    printf '      "project": %s,\n' "$(json_string "$project")"
    printf '      "worktree": %s,\n' "$(json_string "$worktree")"
    printf '      "kind": "ship",\n'
    printf '      "mode": %s,\n' "$(json_string "$mode")"
    printf '      "harness": "",\n'
    printf '      "model": "",\n'
    printf '      "effort": "",\n'
    printf '      "backend": "archived",\n'
    printf '      "backend_known": false,\n'
    printf '      "window": "",\n'
    printf '      "backend_target": "",\n'
    printf '      "backend_liveness": "archived",\n'
    printf '      "source": "teardown",\n'
    printf '      "arrived_at": %s,\n' "$(json_string "$arrived_at")"
    printf '      "current_state": {\n'
    printf '        "state": "done",\n'
    printf '        "source": "arrival-ledger",\n'
    printf '        "detail": "successful ship teardown",\n'
    printf '        "raw": %s\n' "$(json_string "$first_ref")"
    printf '      },\n'
    printf '      "latest_status": {\n'
    printf '        "path": %s,\n' "$(json_string "$ARRIVALS")"
    printf '        "verb": %s,\n' "$(json_string "$status_verb")"
    printf '        "note": %s,\n' "$(json_string "$status_note")"
    printf '        "raw": %s\n' "$(json_string "$latest_status")"
    printf '      },\n'
    print_pipeline_json
    printf '\n'
    printf '    }'
  done < "$ARRIVALS"
}

task_id_from_file() {
  local path=$1 base
  base=$(basename "$path")
  case "$base" in
    *.meta) printf '%s' "${base%.meta}" ;;
    *.status) printf '%s' "${base%.status}" ;;
  esac
}

print_fleet_and_station_arrays() {
  local first=1 meta id backend backend_known window target liveness worktree project kind mode harness model effort
  local crew_line current_state current_source current_detail status_file status_line status_verb status_note station_pair station reason
  local display_title display_subtitle attention branch commit_short pr_url pr_head
  STATION_IDS=()
  STATION_VALUES=()
  STATION_REASONS=()

  printf '  "fleet": [\n'
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    backend=$(fm_backend_of_meta "$meta")
    backend_known=true
    fm_backend_is_known "$backend" || backend_known=false
    window=$(fm_meta_get "$meta" window)
    target=$(fm_backend_target_of_meta "$meta")
    worktree=$(fm_meta_get "$meta" worktree)
    project=$(fm_meta_get "$meta" project)
    kind=$(fm_meta_get "$meta" kind)
    mode=$(fm_meta_get "$meta" mode)
    harness=$(fm_meta_get "$meta" harness)
    model=$(fm_meta_get "$meta" model)
    effort=$(fm_meta_get "$meta" effort)
    [ -n "$kind" ] || kind=ship
    [ -n "$target" ] || target=$window

    liveness=unknown
    if [ "$backend_known" = true ] && [ -n "$target" ]; then
      if fm_backend_target_exists "$backend" "$target" "fm-$id"; then
        liveness=alive
      else
        liveness=dead
      fi
    fi

    crew_line=$(FM_STATE_OVERRIDE="$STATE" FM_HOME="$FM_HOME" "$CREW_STATE_BIN" "$id" 2>/dev/null || true)
    current_state=$(crew_field_state "$crew_line")
    current_source=$(crew_field_source "$crew_line")
    current_detail=$(crew_field_detail "$crew_line" "$current_source")
    [ -n "$current_state" ] || current_state=unknown
    [ -n "$current_source" ] || current_source=none

    status_file="$STATE/$id.status"
    status_line=$(last_nonblank_line "$status_file" 2>/dev/null || true)
    status_verb=$(status_verb_of "$status_line")
    status_note=$(status_note_of "$status_line")

    station_pair=$(station_for "$current_state" "$current_source" "$current_detail" "$status_verb" "$worktree" "$liveness" "$target")
    station=${station_pair%%|*}
    reason=${station_pair#*|}
    display_title=$(display_title_for "$meta" "$id" "$status_note")
    display_subtitle=$(display_subtitle_for "$current_detail" "$status_note")
    attention=$(attention_for "$station" "$current_state" "$status_verb")
    branch=$(git_branch_for "$worktree")
    [ -n "$branch" ] || branch=$(fm_meta_get "$meta" branch)
    commit_short=$(git_commit_short_for "$worktree")
    if [ -z "$commit_short" ]; then
      pr_head=$(fm_meta_get "$meta" pr_head)
      [ -n "$pr_head" ] && commit_short=${pr_head:0:9}
    fi
    pr_url=$(pr_url_for "$meta" "$status_line")
    set_pipeline_fields "$kind" "$mode" "$station" "$current_state" "$current_source" "$current_detail" "$status_verb" "$status_note" "$worktree" "$liveness" "$target" "$pr_url" meta
    STATION_IDS+=("$id")
    STATION_VALUES+=("$station")
    STATION_REASONS+=("$reason")

    [ "$first" -eq 1 ] || printf ',\n'
    first=0
    printf '    {\n'
    printf '      "task_id": %s,\n' "$(json_string "$id")"
    printf '      "display_title": %s,\n' "$(json_string "$display_title")"
    printf '      "display_subtitle": %s,\n' "$(json_string "$display_subtitle")"
    printf '      "attention": %s,\n' "$(json_string "$attention")"
    printf '      "branch": %s,\n' "$(json_string "$branch")"
    printf '      "commit_short": %s,\n' "$(json_string "$commit_short")"
    printf '      "pr_url": %s,\n' "$(json_string "$pr_url")"
    printf '      "meta_path": %s,\n' "$(json_string "$meta")"
    printf '      "project": %s,\n' "$(json_string "$project")"
    printf '      "worktree": %s,\n' "$(json_string "$worktree")"
    printf '      "kind": %s,\n' "$(json_string "$kind")"
    printf '      "mode": %s,\n' "$(json_string "$mode")"
    printf '      "harness": %s,\n' "$(json_string "$harness")"
    printf '      "model": %s,\n' "$(json_string "$model")"
    printf '      "effort": %s,\n' "$(json_string "$effort")"
    printf '      "backend": %s,\n' "$(json_string "$backend")"
    printf '      "backend_known": %s,\n' "$backend_known"
    printf '      "window": %s,\n' "$(json_string "$window")"
    printf '      "backend_target": %s,\n' "$(json_string "$target")"
    printf '      "backend_liveness": %s,\n' "$(json_string "$liveness")"
    printf '      "current_state": {\n'
    printf '        "state": %s,\n' "$(json_string "$current_state")"
    printf '        "source": %s,\n' "$(json_string "$current_source")"
    printf '        "detail": %s,\n' "$(json_string "$current_detail")"
    printf '        "raw": %s\n' "$(json_string "$crew_line")"
    printf '      },\n'
    printf '      "latest_status": {\n'
    printf '        "path": %s,\n' "$(json_string "$status_file")"
    printf '        "verb": %s,\n' "$(json_string "$status_verb")"
    printf '        "note": %s,\n' "$(json_string "$status_note")"
    printf '        "raw": %s\n' "$(json_string "$status_line")"
    printf '      },\n'
    print_pipeline_json
    printf '\n'
    printf '    }'
  done
  print_arrival_fleet_rows
  printf '\n  ],\n'

  printf '  "stations": [\n'
  first=1
  local i
  for i in "${!STATION_IDS[@]}"; do
    [ "$first" -eq 1 ] || printf ',\n'
    first=0
    printf '    {"task_id": %s, "station": %s, "reason": %s}' \
      "$(json_string "${STATION_IDS[$i]}")" \
      "$(json_string "${STATION_VALUES[$i]}")" \
      "$(json_string "${STATION_REASONS[$i]}")"
  done
  printf '\n  ],\n'
}

print_status_files() {
  local first=1 status id mtime line verb note
  printf '    "status_files": [\n'
  for status in "$STATE"/*.status; do
    [ -f "$status" ] || continue
    id=$(basename "$status" .status)
    mtime=$(stat_mtime "$status" || true)
    line=$(last_nonblank_line "$status" 2>/dev/null || true)
    verb=$(status_verb_of "$line")
    note=$(status_note_of "$line")
    [ "$first" -eq 1 ] || printf ',\n'
    first=0
    printf '      {"task_id": %s, "path": %s, "mtime_epoch": %s, "last_line": %s, "verb": %s, "note": %s, "replay_note": "latest event time is approximated from file mtime"}' \
      "$(json_string "$id")" "$(json_string "$status")" "$(json_number_or_null "$mtime")" \
      "$(json_string "$line")" "$(json_string "$verb")" "$(json_string "$note")"
  done
  printf '\n    ],\n'
}

print_watch_triage() {
  local first=1 line timestamp message
  printf '    "watch_triage_log": [\n'
  if [ -f "$STATE/.watch-triage.log" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      timestamp=
      message=$line
      case "$line" in
        \[*\]*)
          timestamp=${line#\[}
          timestamp=${timestamp%%\]*}
          message=${line#*\] }
          ;;
      esac
      [ "$first" -eq 1 ] || printf ',\n'
      first=0
      printf '      {"timestamp": %s, "message": %s, "raw": %s}' \
        "$(json_string "$timestamp")" "$(json_string "$message")" "$(json_string "$line")"
    done < "$STATE/.watch-triage.log"
  fi
  printf '\n    ],\n'
}

print_wake_queue() {
  local first=1 epoch seq kind key payload
  printf '    "wake_queue": [\n'
  if [ -f "$STATE/.wake-queue" ]; then
    while IFS=$'\t' read -r epoch seq kind key payload || [ -n "${epoch:-}" ]; do
      [ -n "${epoch:-}" ] || continue
      [ "$first" -eq 1 ] || printf ',\n'
      first=0
      printf '      {"epoch": %s, "seq": %s, "kind": %s, "key": %s, "payload": %s}' \
        "$(json_number_or_null "$epoch")" "$(json_number_or_null "$seq")" \
        "$(json_string "${kind:-}")" "$(json_string "${key:-}")" "$(json_string "${payload:-}")"
    done < "$STATE/.wake-queue"
  fi
  printf '\n    ],\n'
}

print_task_ledger() {
  local ledger="$DATA/task-ledger.md" first=1 line body date task_id kind project harness duration escalations tokens outcome friction rest
  printf '    "task_ledger": [\n'
  if [ -f "$ledger" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "|"* )
          case "$line" in *---*|"| date "*|"| Date "*) continue ;; esac
          body=${line#|}
          body=${body%|}
          IFS='|' read -r date task_id kind project harness duration escalations tokens outcome friction rest <<< "$body"
          date=$(trim "$date")
          task_id=$(trim "$task_id")
          kind=$(trim "$kind")
          project=$(trim "$project")
          harness=$(trim "$harness")
          duration=$(trim "$duration")
          escalations=$(trim "$escalations")
          tokens=$(trim "$tokens")
          outcome=$(trim "$outcome")
          friction=$(trim "$friction")
          [ -n "$task_id" ] || continue
          [ "$first" -eq 1 ] || printf ',\n'
          first=0
          printf '      {"date": %s, "task_id": %s, "kind": %s, "project": %s, "harness": %s, "duration": %s, "escalations": %s, "tokens": %s, "outcome": %s, "friction": %s, "raw": %s}' \
            "$(json_string "$date")" "$(json_string "$task_id")" "$(json_string "$kind")" \
            "$(json_string "$project")" "$(json_string "$harness")" "$(json_string "$duration")" \
            "$(json_string "$escalations")" "$(json_string "$tokens")" "$(json_string "$outcome")" \
            "$(json_string "$friction")" "$(json_string "$line")"
          ;;
      esac
    done < "$ledger"
  fi
  printf '\n    ],\n'
}

print_file_mtimes() {
  local first=1 path id type mtime
  printf '    "file_mtimes": [\n'
  for path in "$STATE"/*.meta "$STATE"/*.status "$STATE/.watch-triage.log" "$STATE/.wake-queue" "$DATA/task-ledger.md" "$ARRIVALS"; do
    [ -e "$path" ] || continue
    type=other
    case "$path" in
      *.meta) type=meta ;;
      *.status) type=status ;;
      */.watch-triage.log) type=watch-triage ;;
      */.wake-queue) type=wake-queue ;;
      */task-ledger.md) type=task-ledger ;;
      */dashboard-arrivals.jsonl) type=arrival-ledger ;;
    esac
    id=$(task_id_from_file "$path")
    mtime=$(stat_mtime "$path" || true)
    [ "$first" -eq 1 ] || printf ',\n'
    first=0
    printf '      {"type": %s, "task_id": %s, "path": %s, "mtime_epoch": %s}' \
      "$(json_string "$type")" "$(json_string "$id")" "$(json_string "$path")" "$(json_number_or_null "$mtime")"
  done
  printf '\n    ],\n'
}

print_replay_sources() {
  printf '  "replay_sources": {\n'
  printf '    "quality": "approximate",\n'
  printf '    "summary": "Existing files can approximate recent events but cannot reconstruct exact station transitions or durations.",\n'
  print_status_files
  print_watch_triage
  print_wake_queue
  print_task_ledger
  print_file_mtimes
  printf '    "minimum_event_ledger": {\n'
  printf '      "implemented": true,\n'
  printf '      "files": [%s],\n' "$(json_string "$ARRIVALS")"
  printf '      "fields": ["arrived_at", "task_id", "display_title", "latest_status", "pr_url", "branch", "commit_short", "project", "worktree", "mode", "source"]\n'
  printf '    }\n'
  printf '  }\n'
}

print_json() {
  printf '{\n'
  print_fleet_and_station_arrays
  print_replay_sources
  printf '}\n'
}

print_report() {
  local meta_count=0 status_count=0 triage_count=0 wake_count=0 ledger_count=0
  for f in "$STATE"/*.meta; do [ -f "$f" ] && meta_count=$((meta_count + 1)); done
  for f in "$STATE"/*.status; do [ -f "$f" ] && status_count=$((status_count + 1)); done
  [ -f "$STATE/.watch-triage.log" ] && triage_count=$(awk 'END { print NR + 0 }' "$STATE/.watch-triage.log")
  [ -f "$STATE/.wake-queue" ] && wake_count=$(awk 'NF { count++ } END { print count + 0 }' "$STATE/.wake-queue")
  if [ -f "$DATA/task-ledger.md" ]; then
    ledger_count=$(awk '/^\|/ && $0 !~ /---/ && $0 !~ /^\|[[:space:]]*[Dd]ate[[:space:]]*\|/ { count++ } END { print count + 0 }' "$DATA/task-ledger.md")
  fi

  cat <<EOF
Firstmate Fleet Dashboard Probe

Mockup A live update:
- Current task cards can be populated now from state/*.meta plus fm-crew-state.sh.
- Backend target and liveness are deterministic enough for polling. No AI calls or WebSockets are needed for the first dashboard pass.
- Current fleet count: $meta_count task(s).

Mockup D replay:
- Replay from existing data is approximate. Available sources: $status_count status file(s), $triage_count watcher triage line(s), $wake_count queued wake record(s), $ledger_count task-ledger row(s), and file mtimes.
- Existing state can show recent events and completion summaries, but it cannot prove exact station transitions, durations, or superseded status history after teardown.

Minimum append-only event ledger:
- timestamp
- task_id
- event_type
- station
- source
- detail
EOF
}

if [ "$MODE" = report ]; then
  print_report
else
  print_json
fi
