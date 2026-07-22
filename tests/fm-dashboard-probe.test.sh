#!/usr/bin/env bash
# Behavior tests for bin/fm-dashboard-probe.sh.
#
# The probe is dashboard prep only: it reads temp Firstmate state, maps live
# tasks into dashboard stations, and exposes approximate replay inputs without
# touching the real fleet.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROBE="$ROOT/bin/fm-dashboard-probe.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard-probe)

make_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/data" "$dir/fakebin"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = display-message ]; then
  target=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -t) target=${2:-}; shift 2; continue ;;
    esac
    shift
  done
  case "$target" in
    *alive*) printf '%%1\n'; exit 0 ;;
  esac
fi
exit 1
SH
  cat > "$dir/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  validate-t1) printf 'state: working · source: run-step · validating (running tests)\n' ;;
  pane-t2) printf 'state: working · source: pane · harness busy\n' ;;
  decision-t3) printf 'state: unknown · source: none · no current-state source available\n' ;;
  done-t4) printf 'state: unknown · source: none · backend target gone\n' ;;
  cast-t5) printf 'state: unknown · source: none · no current-state source available\n' ;;
  missing-t6) printf 'state: unknown · source: none · worktree gone (torn down?)\n' ;;
  dead-t7) printf 'state: unknown · source: none · backend target gone: sess:dead-target\n' ;;
  currentdone-t8) printf 'state: done · source: run-step · checks green: PR ready for review\n' ;;
  parked-t9) printf 'state: parked · source: run-step · parked at review: 1 finding(s) (ask-user: captain decision)\n' ;;
  current-old-t13) printf 'state: done · source: run-step · completed without status timestamp\n' ;;
  git-t1) printf 'state: working · source: pane · implementing the dashboard detail panel\n' ;;
  nm-run-t1) printf 'state: working · source: run-step · validating (running)\n' ;;
  nm-parked-t2) printf 'state: parked · source: run-step · parked at review: 2 finding(s) (ask-user: captain decision)\n' ;;
  nm-ready-t3) printf 'state: done · source: run-step · checks green: PR ready for review\n' ;;
  nm-landed-t4) printf 'state: done · source: run-step · run passed: PR merged/closed\n' ;;
  nm-failed-t5) printf 'state: failed · source: run-step · run failed\n' ;;
  nm-super-t6) printf 'state: working · source: run-step · validating (running) · status-log superseded by active run\n' ;;
  direct-t7) printf 'state: working · source: pane · PR opened\n' ;;
  local-t8) printf 'state: done · source: status-log · ready in local branch\n' ;;
  scout-t9) printf 'state: done · source: status-log · report written\n' ;;
  second-t10) printf 'state: working · source: pane · idle and supervising routed work\n' ;;
  missing-pipe-t11) printf 'state: unknown · source: none · worktree gone (torn down?)\n' ;;
  *) printf 'state: unknown · source: none · fake default\n' ;;
esac
SH
  chmod +x "$dir/fakebin/tmux" "$dir/fakebin/fm-crew-state.sh"
  printf '%s\n' "$dir"
}

run_probe_json() {
  local dir=$1 out=$2
  PATH="$dir/fakebin:$PATH" \
    FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$dir/state" \
    FM_DATA_OVERRIDE="$dir/data" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    "$PROBE" > "$out"
  jq -e . "$out" >/dev/null || fail "probe did not emit valid JSON: $(cat "$out")"
}

jq_value() {
  jq -r "$1" "$2"
}

assert_jq_true() {
  local expr=$1 file=$2 msg=$3
  jq -e "$expr" "$file" >/dev/null || fail "$msg: $(cat "$file")"
}

old_touch_spec() {
  if [ "$(uname)" = Darwin ]; then
    date -v-2d '+%Y%m%d%H%M.%S'
  else
    date -d '2 days ago' '+%Y%m%d%H%M.%S'
  fi
}

old_local_date() {
  if [ "$(uname)" = Darwin ]; then
    date -v-2d '+%Y-%m-%d'
  else
    date -d '2 days ago' '+%Y-%m-%d'
  fi
}

test_fleet_meta_and_station_mapping() {
  local dir state out wt
  dir=$(make_case mapping)
  state="$dir/state"
  out="$dir/out.json"

  for wt in wt-validate wt-pane wt-decision wt-done wt-cast wt-dead wt-currentdone wt-parked; do
    mkdir -p "$dir/$wt"
  done

  fm_write_meta "$state/validate-t1.meta" \
    "window=sess:alive-validate" \
    "worktree=$dir/wt-validate" \
    "project=$dir/projects/cad" \
    "kind=ship" \
    "mode=no-mistakes" \
    "harness=codex" \
    "model=gpt-5.5" \
    "effort=high"
  fm_write_meta "$state/pane-t2.meta" \
    "window=sess:alive-pane" \
    "worktree=$dir/wt-pane" \
    "project=$dir/projects/tc" \
    "kind=ship" \
    "mode=direct-PR"
  fm_write_meta "$state/decision-t3.meta" \
    "window=sess:alive-decision" \
    "worktree=$dir/wt-decision" \
    "project=$dir/projects/cad" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'working: setup\nneeds-decision: choose the UI copy\n' > "$state/decision-t3.status"
  fm_write_meta "$state/done-t4.meta" \
    "window=sess:dead-done" \
    "worktree=$dir/wt-done" \
    "project=$dir/projects/cad" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'done: PR checks green\n' > "$state/done-t4.status"
  fm_write_meta "$state/cast-t5.meta" \
    "window=sess:alive-cast" \
    "worktree=$dir/wt-cast" \
    "project=$dir/projects/cad" \
    "kind=scout" \
    "mode=report"
  fm_write_meta "$state/missing-t6.meta" \
    "window=sess:alive-missing" \
    "worktree=$dir/no-such-worktree" \
    "project=$dir/projects/cad" \
    "kind=ship" \
    "mode=no-mistakes"
  fm_write_meta "$state/dead-t7.meta" \
    "window=sess:dead-target" \
    "worktree=$dir/wt-dead" \
    "project=$dir/projects/cad" \
    "kind=ship" \
    "mode=no-mistakes"
  fm_write_meta "$state/currentdone-t8.meta" \
    "window=sess:alive-currentdone" \
    "worktree=$dir/wt-currentdone" \
    "project=$dir/projects/cad" \
    "kind=ship" \
    "mode=no-mistakes"
  fm_write_meta "$state/parked-t9.meta" \
    "window=sess:alive-parked" \
    "worktree=$dir/wt-parked" \
    "project=$dir/projects/cad" \
    "kind=ship" \
    "mode=no-mistakes"

  run_probe_json "$dir" "$out"

  assert_jq_true '.fleet | length == 9' "$out" "fleet did not include all meta-backed tasks"
  [ "$(jq_value '.fleet[] | select(.task_id == "validate-t1") | .backend' "$out")" = tmux ] \
    || fail "absent backend= did not normalize to tmux"
  [ "$(jq_value '.fleet[] | select(.task_id == "validate-t1") | .project' "$out")" = "$dir/projects/cad" ] \
    || fail "project metadata was not parsed"
  [ "$(jq_value '.fleet[] | select(.task_id == "validate-t1") | .current_state.source' "$out")" = run-step ] \
    || fail "current state source was not parsed from fm-crew-state output"
  [ "$(jq_value '.fleet[] | select(.task_id == "validate-t1") | .backend_liveness' "$out")" = alive ] \
    || fail "live backend target was not marked alive"
  [ "$(jq_value '.fleet[] | select(.task_id == "dead-t7") | .backend_liveness' "$out")" = dead ] \
    || fail "dead backend target was not marked dead"

  [ "$(jq_value '.stations[] | select(.task_id == "validate-t1") | .station' "$out")" = gate_run ] \
    || fail "validating run-step did not map to gate_run"
  [ "$(jq_value '.stations[] | select(.task_id == "pane-t2") | .station' "$out")" = underway ] \
    || fail "busy pane did not map to underway"
  [ "$(jq_value '.stations[] | select(.task_id == "decision-t3") | .station' "$out")" = needs_captain ] \
    || fail "needs-decision status did not map to needs_captain"
  [ "$(jq_value '.stations[] | select(.task_id == "done-t4") | .station' "$out")" = arrived_today ] \
    || fail "done status did not map to arrived_today"
  [ "$(jq_value '.stations[] | select(.task_id == "currentdone-t8") | .station' "$out")" = arrived_today ] \
    || fail "done current state did not map to arrived_today"
  [ "$(jq_value '.stations[] | select(.task_id == "parked-t9") | .station' "$out")" = needs_captain ] \
    || fail "parked current state did not map to needs_captain"
  [ "$(jq_value '.stations[] | select(.task_id == "cast-t5") | .station' "$out")" = casting_off ] \
    || fail "live meta without strong state did not map to casting_off"
  [ "$(jq_value '.stations[] | select(.task_id == "missing-t6") | .station' "$out")" = unknown ] \
    || fail "missing worktree did not map to unknown"
  [ "$(jq_value '.stations[] | select(.task_id == "dead-t7") | .station' "$out")" = unknown ] \
    || fail "dead backend target did not map to unknown"
  [ "$(jq_value '.fleet[] | select(.task_id == "decision-t3") | .attention' "$out")" = needs_action ] \
    || fail "needs-decision task did not expose needs_action attention"
  [ "$(jq_value '.fleet[] | select(.task_id == "done-t4") | .attention' "$out")" = "done" ] \
    || fail "done task did not expose done attention"
  [ "$(jq_value '.fleet[] | select(.task_id == "pane-t2") | .attention' "$out")" = normal ] \
    || fail "ordinary working task did not expose normal attention"
  pass "fleet JSON parses meta/current-state/liveness and station mapping"
}

test_display_title_precedence_and_subtitle() {
  local dir state data out
  dir=$(make_case titles)
  state="$dir/state"
  data="$dir/data"
  out="$dir/out.json"

  cat > "$data/backlog.md" <<'EOF'
# Backlog
- [ ] title-meta-t1 - Backlog title should lose (repo: tc) (kind: ship) (since 2026-07-08)
- [ ] title-backlog-t2 - Backlog title wins (repo: cad) (kind: scout) (since 2026-07-08)
EOF
  mkdir -p "$data/title-meta-t1" "$data/title-backlog-t2" "$data/title-brief-t3"
  cat > "$data/title-meta-t1/brief.md" <<'EOF'
# Task
Brief title should lose.
EOF
  cat > "$data/title-brief-t3/brief.md" <<'EOF'
Intro line.

# Task
Brief **task** title wins.
EOF

  fm_write_meta "$state/title-meta-t1.meta" \
    "window=sess:alive-title-meta" \
    "title=Meta title wins" \
    "project=$dir/projects/tc"
  printf 'working: Status title should lose\n' > "$state/title-meta-t1.status"
  fm_write_meta "$state/title-backlog-t2.meta" \
    "window=sess:alive-title-backlog" \
    "project=$dir/projects/cad"
  fm_write_meta "$state/title-brief-t3.meta" \
    "window=sess:alive-title-brief" \
    "project=$dir/projects/cad"
  fm_write_meta "$state/title-status-t4.meta" \
    "window=sess:alive-title-status" \
    "project=$dir/projects/cad"
  printf 'working: Latest status note wins\n' > "$state/title-status-t4.status"
  fm_write_meta "$state/title-id-t5.meta" \
    "window=sess:alive-title-id" \
    "project=$dir/projects/cad"

  run_probe_json "$dir" "$out"

  [ "$(jq_value '.fleet[] | select(.task_id == "title-meta-t1") | .display_title' "$out")" = "Meta title wins" ] \
    || fail "meta title did not win display_title precedence"
  [ "$(jq_value '.fleet[] | select(.task_id == "title-backlog-t2") | .display_title' "$out")" = "Backlog title wins" ] \
    || fail "backlog line did not provide display_title"
  [ "$(jq_value '.fleet[] | select(.task_id == "title-brief-t3") | .display_title' "$out")" = "Brief task title wins." ] \
    || fail "brief # Task did not provide display_title"
  [ "$(jq_value '.fleet[] | select(.task_id == "title-status-t4") | .display_title' "$out")" = "Latest status note wins" ] \
    || fail "latest status note did not provide display_title"
  [ "$(jq_value '.fleet[] | select(.task_id == "title-id-t5") | .display_title' "$out")" = title-id-t5 ] \
    || fail "task id was not the final display_title fallback"
  [ "$(jq_value '.fleet[] | select(.task_id == "title-status-t4") | .display_subtitle' "$out")" = "Latest status note wins" ] \
    || fail "status note did not provide display_subtitle when current detail was generic"
  pass "display title precedence derives meta, backlog, brief, status, and id fallbacks"
}

test_git_and_pr_fields_are_extracted() {
  local dir state out wt expected_commit
  dir=$(make_case git-pr)
  state="$dir/state"
  out="$dir/out.json"
  wt="$dir/worktree"
  fm_git_init_commit "$wt"
  git -C "$wt" checkout -q -b fm/dashboard-branch
  expected_commit=$(git -C "$wt" rev-parse --short=9 HEAD)

  fm_write_meta "$state/git-t1.meta" \
    "window=sess:alive-git" \
    "worktree=$wt" \
    "project=$dir/projects/cad" \
    "kind=ship" \
    "mode=direct-PR" \
    "pr=https://github.com/example/project/pull/44"
  printf 'working: status has a different PR https://github.com/example/project/pull/99\n' > "$state/git-t1.status"
  fm_write_meta "$state/status-pr-t2.meta" \
    "window=sess:alive-status-pr" \
    "worktree=$wt" \
    "project=$dir/projects/cad"
  printf 'done: PR https://github.com/example/project/pull/55 checks green\n' > "$state/status-pr-t2.status"

  run_probe_json "$dir" "$out"

  [ "$(jq_value '.fleet[] | select(.task_id == "git-t1") | .branch' "$out")" = "fm/dashboard-branch" ] \
    || fail "git branch was not extracted from worktree"
  [ "$(jq_value '.fleet[] | select(.task_id == "git-t1") | .commit_short' "$out")" = "$expected_commit" ] \
    || fail "git commit_short was not extracted from worktree"
  [ "$(jq_value '.fleet[] | select(.task_id == "git-t1") | .pr_url' "$out")" = "https://github.com/example/project/pull/44" ] \
    || fail "meta pr did not win over status PR URL"
  [ "$(jq_value '.fleet[] | select(.task_id == "status-pr-t2") | .pr_url' "$out")" = "https://github.com/example/project/pull/55" ] \
    || fail "status PR URL was not extracted"
  pass "branch, commit_short, and PR URL fields are extracted read-only"
}

test_empty_fleet_output() {
  local dir out
  dir=$(make_case empty)
  out="$dir/out.json"
  run_probe_json "$dir" "$out"
  assert_jq_true '.fleet == [] and .stations == []' "$out" "empty state did not produce empty fleet and stations arrays"
  pass "empty fleet emits empty fleet and station arrays"
}

test_arrival_ledger_keeps_landed_ships_visible_today() {
  local dir data out today yesterday
  dir=$(make_case arrivals)
  data="$dir/data"
  out="$dir/out.json"
  today=$(date '+%Y-%m-%d')
  yesterday=$(date -v-1d '+%Y-%m-%d' 2>/dev/null || date -d yesterday '+%Y-%m-%d')
  cat > "$data/dashboard-arrivals.jsonl" <<EOF
{"task_id":"landed-t1","arrived_at":"${today}T12:00:00Z","display_title":"Landed task","latest_status":"done: landed cleanly","pr_url":"https://github.com/example/repo/pull/1","branch":"fm/landed-t1","commit_short":"abc123def","project":"repo","worktree":"/tmp/wt","mode":"no-mistakes","source":"teardown"}
{"task_id":"blocked-arrival-t2","arrived_at":"${today}T13:00:00Z","display_title":"Blocked arrival","latest_status":"blocked: cleanup blocked by dirty worktree","pr_url":"https://github.com/example/repo/pull/2","mode":"no-mistakes","source":"teardown"}
{"task_id":"decision-arrival-t3","arrived_at":"${today}T14:00:00Z","display_title":"Decision arrival","latest_status":"needs-decision: cleanup blocked by missing report","pr_url":"https://github.com/example/repo/pull/3","mode":"no-mistakes","source":"teardown"}
{"task_id":"old-t1","arrived_at":"${yesterday}T12:00:00Z","display_title":"Old task","latest_status":"done: old","source":"teardown"}
{"task_id":"old-blocked-arrival-t4","arrived_at":"${yesterday}T15:00:00Z","display_title":"Old blocked arrival","latest_status":"blocked: stale cleanup blocker","pr_url":"https://github.com/example/repo/pull/4","mode":"no-mistakes","source":"teardown"}
{"task_id":"old-decision-arrival-t5","arrived_at":"${yesterday}T16:00:00Z","display_title":"Old decision arrival","latest_status":"needs-decision: stale cleanup decision","pr_url":"https://github.com/example/repo/pull/5","mode":"direct-PR","source":"teardown"}
EOF

  run_probe_json "$dir" "$out"
  assert_jq_true '.fleet[] | select(.task_id == "landed-t1" and .backend_liveness == "archived" and .current_state.source == "arrival-ledger")' \
    "$out" "same-day arrival ledger row did not appear as archived fleet item"
  [ "$(jq_value '.stations[] | select(.task_id == "landed-t1") | .station' "$out")" = arrived_today ] \
    || fail "same-day arrival did not map to arrived_today"
  assert_jq_true '[.stations[] | select(.station == "arrived_today") | .task_id] == ["landed-t1"]' \
    "$out" "same-day attention arrivals still appeared in arrived_today"
  assert_jq_true '.fleet[] | select(.task_id == "landed-t1" and .timeline.source == "arrival-ledger" and .timeline.freshness == "today")' \
    "$out" "same-day arrival did not expose today timeline fields"
  [ "$(jq_value '.stations[] | select(.task_id == "blocked-arrival-t2") | .station' "$out")" = needs_captain ] \
    || fail "same-day blocked arrival did not map to needs_captain"
  assert_jq_true '.fleet[] | select(.task_id == "blocked-arrival-t2" and .attention == "needs_action" and .source == "arrival-ledger" and .current_state.state == "blocked" and .current_state.detail == "cleanup blocked by dirty worktree" and .latest_status.verb == "blocked" and .pipeline.main_stage == "validation_gate" and .pipeline.next_human_action == "answer gate finding" and (.pipeline.evidence | index("source=arrival-ledger")))' \
    "$out" "blocked arrival ledger row did not stay in the captain-attention pipeline"
  [ "$(jq_value '.stations[] | select(.task_id == "decision-arrival-t3") | .station' "$out")" = needs_captain ] \
    || fail "same-day needs-decision arrival did not map to needs_captain"
  assert_jq_true '.fleet[] | select(.task_id == "decision-arrival-t3" and .attention == "needs_action" and .source == "arrival-ledger" and .current_state.state == "parked" and .current_state.detail == "cleanup blocked by missing report" and .latest_status.verb == "needs-decision" and .pipeline.main_stage == "validation_gate" and .pipeline.next_human_action == "answer gate finding" and (.pipeline.evidence | index("source=arrival-ledger")))' \
    "$out" "needs-decision arrival ledger row did not stay in the captain-attention pipeline"
  [ "$(jq_value '.stations[] | select(.task_id == "old-t1") | .station' "$out")" = done_earlier ] \
    || fail "previous-day arrival did not map to done_earlier"
  [ "$(jq_value '.stations[] | select(.task_id == "old-blocked-arrival-t4") | .station' "$out")" = done_earlier ] \
    || fail "previous-day blocked arrival stayed in needs_captain"
  [ "$(jq_value '.stations[] | select(.task_id == "old-decision-arrival-t5") | .station' "$out")" = done_earlier ] \
    || fail "previous-day needs-decision arrival stayed in needs_captain"
  assert_jq_true '[.stations[] | select(.station == "needs_captain") | .task_id] == ["blocked-arrival-t2", "decision-arrival-t3"]' \
    "$out" "prior-day attention arrivals polluted current Needs Captain lane"
  [ "$(jq_value '.fleet[] | select(.task_id == "old-t1") | .pr_url' "$out")" = "" ] \
    || fail "missing arrival pr_url did not remain empty"
  assert_jq_true '[.stations[] | select(.task_id == "old-t1" and .station == "arrived_today")] | length == 0' \
    "$out" "previous-day arrival ledger row still appeared in arrived_today"
  pass "arrival ledger separates landed ships from attention rows"
}

test_completion_timeline_drives_done_lanes_and_reconciliation() {
  local dir state out today old_date old_spec wt
  dir=$(make_case timeline)
  state="$dir/state"
  out="$dir/out.json"
  today=$(date '+%Y-%m-%d')
  old_date=$(old_local_date)
  old_spec=$(old_touch_spec)

  for wt in wt-inline-old wt-inline-today wt-mtime-old wt-current-old wt-reconcile wt-recent wt-prefix-done wt-prefix-complete wt-date-task-complete; do
    mkdir -p "$dir/$wt"
  done

  fm_write_meta "$state/inline-old-t10.meta" \
    "window=sess:alive-inline-old" \
    "worktree=$dir/wt-inline-old" \
    "project=$dir/projects/cad" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'done: finished at %sT12:00:00Z\n' "$old_date" > "$state/inline-old-t10.status"

  fm_write_meta "$state/inline-today-t11.meta" \
    "window=sess:alive-inline-today" \
    "worktree=$dir/wt-inline-today" \
    "project=$dir/projects/cad" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'done: finished at %sT12:00:00Z\n' "$today" > "$state/inline-today-t11.status"

  fm_write_meta "$state/mtime-old-t12.meta" \
    "window=sess:alive-mtime-old" \
    "worktree=$dir/wt-mtime-old" \
    "project=$dir/projects/cad" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'done: finished without inline timestamp\n' > "$state/mtime-old-t12.status"
  touch -t "$old_spec" "$state/mtime-old-t12.status"

  fm_write_meta "$state/current-old-t13.meta" \
    "window=sess:alive-current-old" \
    "worktree=$dir/wt-current-old" \
    "project=$dir/projects/cad" \
    "kind=ship" \
    "mode=no-mistakes"
  touch -t "$old_spec" "$state/current-old-t13.meta"

  fm_write_meta "$state/reconcile-t14.meta" \
    "window=sess:alive-reconcile" \
    "worktree=$dir/wt-reconcile" \
    "project=$dir/projects/cad" \
    "kind=ship" \
    "mode=no-mistakes"
  touch -t "$old_spec" "$state/reconcile-t14.meta"

  fm_write_meta "$state/recent-t15.meta" \
    "window=sess:alive-recent" \
    "worktree=$dir/wt-recent" \
    "project=$dir/projects/cad" \
    "kind=ship" \
    "mode=no-mistakes"

  fm_write_meta "$state/prefix-done-t16.meta" \
    "window=sess:alive-prefix-done" \
    "worktree=$dir/wt-prefix-done" \
    "project=$dir/projects/cad" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s 13:52 done: implemented timestamp-prefixed status\n' "$old_date" > "$state/prefix-done-t16.status"

  fm_write_meta "$state/prefix-complete-t17.meta" \
    "window=sess:alive-prefix-complete" \
    "worktree=$dir/wt-prefix-complete" \
    "project=$dir/projects/cad" \
    "kind=scout" \
    "mode=report"
  printf '%sT18:58:00-0500 completed source-first triage report\n' "$old_date" > "$state/prefix-complete-t17.status"

  fm_write_meta "$state/date-task-complete-t18.meta" \
    "window=sess:alive-date-task-complete" \
    "worktree=$dir/wt-date-task-complete" \
    "project=$dir/projects/cad" \
    "kind=ship" \
    "mode=direct-PR"
  printf '%s sales-cleanup-q3-q6 complete: pushed branch and wrote report\n' "$old_date" > "$state/date-task-complete-t18.status"

  run_probe_json "$dir" "$out"

  assert_jq_true '.fleet[] | select(.task_id == "inline-old-t10" and .timeline.source == "status-line" and .timeline.done_date == "'"$old_date"'" and .timeline.freshness == "earlier")' \
    "$out" "inline prior done timestamp did not expose status-line timeline"
  [ "$(jq_value '.stations[] | select(.task_id == "inline-old-t10") | .station' "$out")" = done_earlier ] \
    || fail "inline prior done timestamp did not map to done_earlier"
  [ "$(jq_value '.stations[] | select(.task_id == "inline-today-t11") | .station' "$out")" = arrived_today ] \
    || fail "inline same-day done timestamp did not map to arrived_today"
  assert_jq_true '.fleet[] | select(.task_id == "mtime-old-t12" and .timeline.source == "status-file-mtime" and .timeline.freshness == "earlier")' \
    "$out" "done status without inline timestamp did not use status file mtime"
  [ "$(jq_value '.stations[] | select(.task_id == "mtime-old-t12") | .station' "$out")" = done_earlier ] \
    || fail "prior status mtime did not map to done_earlier"
  assert_jq_true '.fleet[] | select(.task_id == "current-old-t13" and .timeline.source == "meta-file-mtime" and .timeline.freshness == "earlier")' \
    "$out" "current done state did not fall back to meta file mtime"
  [ "$(jq_value '.stations[] | select(.task_id == "current-old-t13") | .station' "$out")" = done_earlier ] \
    || fail "current done state with old meta mtime did not map to done_earlier"
  [ "$(jq_value '.stations[] | select(.task_id == "reconcile-t14") | .station' "$out")" = needs_reconciliation ] \
    || fail "old live metadata without state did not map to needs_reconciliation"
  assert_jq_true '.fleet[] | select(.task_id == "reconcile-t14" and .pipeline.main_stage == "unknown" and .pipeline.next_human_action == "reconcile task state")' \
    "$out" "needs_reconciliation task did not expose reconcile pipeline action"
  [ "$(jq_value '.stations[] | select(.task_id == "recent-t15") | .station' "$out")" = casting_off ] \
    || fail "recent no-status metadata did not remain casting_off"
  assert_jq_true '.fleet[] | select(.task_id == "prefix-done-t16" and .latest_status.verb == "done" and .latest_status.note == "implemented timestamp-prefixed status" and .timeline.done_date == "'"$old_date"'" and .timeline.source == "status-line")' \
    "$out" "leading timestamp done status did not parse as dated completion"
  [ "$(jq_value '.stations[] | select(.task_id == "prefix-done-t16") | .station' "$out")" = done_earlier ] \
    || fail "leading timestamp done status did not map to done_earlier"
  assert_jq_true '.fleet[] | select(.task_id == "prefix-complete-t17" and .latest_status.verb == "done" and .latest_status.note == "source-first triage report" and .timeline.done_date == "'"$old_date"'" and .timeline.source == "status-line")' \
    "$out" "leading timestamp completed status did not parse as dated completion"
  [ "$(jq_value '.stations[] | select(.task_id == "prefix-complete-t17") | .station' "$out")" = done_earlier ] \
    || fail "leading timestamp completed status did not map to done_earlier"
  assert_jq_true '.fleet[] | select(.task_id == "date-task-complete-t18" and .latest_status.verb == "done" and .latest_status.note == "pushed branch and wrote report" and .timeline.done_date == "'"$old_date"'" and .timeline.source == "status-line")' \
    "$out" "date-plus-task complete status did not parse as dated completion"
  [ "$(jq_value '.stations[] | select(.task_id == "date-task-complete-t18") | .station' "$out")" = done_earlier ] \
    || fail "date-plus-task complete status did not map to done_earlier"
  pass "completion timelines drive today/earlier done lanes and reconciliation"
}

test_pipeline_snapshot_profiles_and_stages() {
  local dir state data out wt
  dir=$(make_case pipeline)
  state="$dir/state"
  data="$dir/data"
  out="$dir/out.json"

  for wt in wt-nm-run wt-nm-parked wt-nm-ready wt-nm-landed wt-nm-failed wt-nm-super wt-direct wt-local wt-scout wt-second; do
    mkdir -p "$dir/$wt"
  done

  fm_write_meta "$state/nm-run-t1.meta" \
    "window=sess:alive-nm-run" \
    "worktree=$dir/wt-nm-run" \
    "project=$dir/projects/cad" \
    "kind=ship" \
    "mode=no-mistakes"
  fm_write_meta "$state/nm-parked-t2.meta" \
    "window=sess:alive-nm-parked" \
    "worktree=$dir/wt-nm-parked" \
    "project=$dir/projects/cad" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'needs-decision: review gate\n' > "$state/nm-parked-t2.status"
  fm_write_meta "$state/nm-ready-t3.meta" \
    "window=sess:alive-nm-ready" \
    "worktree=$dir/wt-nm-ready" \
    "project=$dir/projects/cad" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr=https://github.com/example/cad/pull/3"
  fm_write_meta "$state/nm-landed-t4.meta" \
    "window=sess:alive-nm-landed" \
    "worktree=$dir/wt-nm-landed" \
    "project=$dir/projects/cad" \
    "kind=ship" \
    "mode=no-mistakes"
  fm_write_meta "$state/nm-failed-t5.meta" \
    "window=sess:alive-nm-failed" \
    "worktree=$dir/wt-nm-failed" \
    "project=$dir/projects/cad" \
    "kind=ship" \
    "mode=no-mistakes"
  fm_write_meta "$state/nm-super-t6.meta" \
    "window=sess:alive-nm-super" \
    "worktree=$dir/wt-nm-super" \
    "project=$dir/projects/cad" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'needs-decision: stale gate question\n' > "$state/nm-super-t6.status"
  fm_write_meta "$state/direct-t7.meta" \
    "window=sess:alive-direct" \
    "worktree=$dir/wt-direct" \
    "project=$dir/projects/tc" \
    "kind=ship" \
    "mode=direct-PR" \
    "pr=https://github.com/example/tc/pull/7"
  fm_write_meta "$state/local-t8.meta" \
    "window=sess:alive-local" \
    "worktree=$dir/wt-local" \
    "project=$dir/projects/local" \
    "kind=ship" \
    "mode=local-only"
  fm_write_meta "$state/scout-t9.meta" \
    "window=sess:alive-scout" \
    "worktree=$dir/wt-scout" \
    "project=$dir/projects/cad" \
    "kind=scout" \
    "mode=report"
  fm_write_meta "$state/second-t10.meta" \
    "window=sess:alive-second" \
    "worktree=$dir/wt-second" \
    "project=$dir/projects/cad" \
    "kind=secondmate" \
    "mode=secondmate"
  fm_write_meta "$state/missing-pipe-t11.meta" \
    "window=sess:alive-missing-pipe" \
    "worktree=$dir/no-such-worktree" \
    "project=$dir/projects/cad" \
    "kind=ship" \
    "mode=no-mistakes"
  fm_write_meta "$state/nm-parked-gone-t13.meta" \
    "window=sess:alive-nm-parked-gone" \
    "worktree=$dir/no-such-parked-worktree" \
    "project=$dir/projects/cad" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'needs-decision: review gate\n' > "$state/nm-parked-gone-t13.status"

  cat > "$data/dashboard-arrivals.jsonl" <<EOF
{"task_id":"landed-history-t12","arrived_at":"$(date '+%Y-%m-%d')T12:00:00Z","display_title":"History landed","latest_status":"done: landed cleanly","pr_url":"https://github.com/example/repo/pull/12","branch":"fm/landed-history-t12","commit_short":"abc123def","project":"repo","worktree":"/tmp/wt","mode":"no-mistakes","source":"teardown"}
EOF

  run_probe_json "$dir" "$out"

  assert_jq_true '.fleet[] | select(.task_id == "nm-run-t1" and .pipeline.profile == "cad_no_mistakes" and .pipeline.main_stage == "validation_gate" and .pipeline.next_human_action == "wait for validation" and .pipeline.source_confidence == "live" and .pipeline.validation_branch.name == "no-mistakes" and .pipeline.validation_branch.step == "validation" and .pipeline.validation_branch.status == "running")' \
    "$out" "running no-mistakes task did not expose validation pipeline"
  assert_jq_true '.fleet[] | select(.task_id == "nm-parked-t2" and .pipeline.main_stage == "validation_gate" and .pipeline.next_human_action == "answer gate finding" and .pipeline.validation_branch.step == "review" and .pipeline.validation_branch.status == "awaiting_approval" and .pipeline.validation_branch.findings == 2)' \
    "$out" "parked no-mistakes task did not expose ask-user gate details"
  assert_jq_true '.fleet[] | select(.task_id == "nm-ready-t3" and .pipeline.main_stage == "review_ready" and .pipeline.next_human_action == "review PR" and .pipeline.validation_branch.status == "checks-passed" and .pipeline.validation_branch.pr_url == "https://github.com/example/cad/pull/3")' \
    "$out" "checks-passed no-mistakes task did not map to review_ready"
  assert_jq_true '.fleet[] | select(.task_id == "nm-landed-t4" and .pipeline.main_stage == "landed" and .pipeline.next_human_action == "move/comment in Basecamp" and .pipeline.validation_branch.status == "passed")' \
    "$out" "passed no-mistakes task did not map to landed"
  assert_jq_true '.fleet[] | select(.task_id == "nm-failed-t5" and .pipeline.main_stage == "validation_gate" and .pipeline.next_human_action == "answer gate finding" and .pipeline.validation_branch.status == "failed")' \
    "$out" "failed no-mistakes task did not stay in validation gate"
  assert_jq_true '.fleet[] | select(.task_id == "nm-super-t6" and .pipeline.validation_branch.superseded_status_log == true and .pipeline.next_human_action == "wait for validation")' \
    "$out" "superseded stale status did not change the next operator action"
  assert_jq_true '.fleet[] | select(.task_id == "direct-t7" and .pipeline.profile == "direct_pr" and .pipeline.main_stage == "review_ready" and .pipeline.next_human_action == "review PR" and .pipeline.validation_branch == null)' \
    "$out" "direct-PR task did not expose review-ready fallback pipeline"
  assert_jq_true '.fleet[] | select(.task_id == "local-t8" and .pipeline.profile == "local_only" and .pipeline.main_stage == "review_ready" and .pipeline.next_human_action == "review local branch")' \
    "$out" "local-only task did not expose local review fallback pipeline"
  assert_jq_true '.fleet[] | select(.task_id == "scout-t9" and .pipeline.profile == "scout_report" and .pipeline.main_stage == "review_ready" and .pipeline.next_human_action == "review scout report")' \
    "$out" "scout task did not expose report review fallback pipeline"
  assert_jq_true '.fleet[] | select(.task_id == "second-t10" and .pipeline.profile == "secondmate" and .pipeline.main_stage == "run_work" and .pipeline.next_human_action == "monitor only")' \
    "$out" "secondmate task did not expose monitor-only fallback pipeline"
  assert_jq_true '.fleet[] | select(.task_id == "missing-pipe-t11" and .pipeline.main_stage == "unknown" and .pipeline.source_confidence == "unknown" and (.pipeline.evidence | index("worktree=missing")))' \
    "$out" "missing worktree did not expose unknown pipeline confidence"
  assert_jq_true '.fleet[] | select(.task_id == "landed-history-t12" and .pipeline.profile == "cad_no_mistakes" and .pipeline.main_stage == "landed" and .pipeline.source_confidence == "approximate" and (.pipeline.evidence | index("source=teardown")))' \
    "$out" "arrival-ledger row did not expose landed pipeline history"
  assert_jq_true '.fleet[] | select(.task_id == "nm-parked-gone-t13" and .pipeline.main_stage == "validation_gate" and .pipeline.next_human_action == "answer gate finding" and .pipeline.source_confidence == "unknown" and (.pipeline.evidence | index("worktree=missing")))' \
    "$out" "needs-attention task with missing worktree did not keep human next action"
  pass "pipeline snapshot maps no-mistakes, fallback profiles, stale status, missing worktree, and landed history"
}

test_replay_sources_are_extracted() {
  local dir state data out ledger
  dir=$(make_case replay)
  state="$dir/state"
  data="$dir/data"
  out="$dir/out.json"
  ledger="$data/task-ledger.md"

  printf 'working: setup\nfailed: tests failed\n' > "$state/replay-t1.status"
  printf '[2026-07-08T10:11:12-0500] absorbed benign signal: replay-t1.status\n' > "$state/.watch-triage.log"
  printf '111\t1\tsignal\treplay-t1.status\tsignal: replay-t1.status\n' > "$state/.wake-queue"
  cat > "$ledger" <<'EOF'
| date | id | kind | project | harness | duration | escalation count | tokens | outcome | friction |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-07-08 | replay-t1 | ship | cad | codex/gpt-5.5/high | 12m | 1 | codex out=52k | failed | tests failed |
EOF

  run_probe_json "$dir" "$out"

  [ "$(jq_value '.replay_sources.quality' "$out")" = approximate ] \
    || fail "replay quality was not marked approximate"
  [ "$(jq_value '.replay_sources.status_files[] | select(.task_id == "replay-t1") | .verb' "$out")" = failed ] \
    || fail "status replay source did not expose the latest status verb"
  [ "$(jq_value '.replay_sources.watch_triage_log[0].timestamp' "$out")" = "2026-07-08T10:11:12-0500" ] \
    || fail "watch triage timestamp was not extracted"
  [ "$(jq_value '.replay_sources.wake_queue[0].epoch' "$out")" = 111 ] \
    || fail "wake queue epoch was not extracted"
  [ "$(jq_value '.replay_sources.task_ledger[0].task_id' "$out")" = replay-t1 ] \
    || fail "task ledger row was not extracted"
  assert_jq_true '.replay_sources.file_mtimes | map(.type) | index("status") and index("watch-triage") and index("wake-queue") and index("task-ledger")' \
    "$out" "file mtimes did not include replay inputs"
  assert_jq_true '.replay_sources.minimum_event_ledger.implemented == true and (.replay_sources.minimum_event_ledger.files[] | contains("dashboard-arrivals.jsonl"))' \
    "$out" "minimum event ledger fields changed"
  assert_jq_true '.supervision.watcher.stale == true and .supervision.wake_queue.pending == 1' \
    "$out" "supervision summary did not expose stale watcher or pending wake queue"
  pass "replay sources include status mtimes, watcher timestamps, wake epochs, task ledger, and ledger recommendation"
}

test_completed_scout_reports_feed_answered_lane() {
  local dir state data out active_report_path new_report_path
  dir=$(make_case reports)
  state="$dir/state"
  data="$dir/data"
  out="$dir/out.json"

  mkdir -p "$data/scout-active" "$data/scout-new" "$data/scout-old" "$dir/wt-scout-active"
  active_report_path="$data/scout-active/report.md"
  new_report_path="$data/scout-new/report.md"
  cat > "$active_report_path" <<'EOF'
# Active report should not duplicate

## Finding
The active row should win.
EOF
  cat > "$new_report_path" <<'EOF'
# CAD ShowMe scout
Card: ShowMe is aggregate but this is teaching arithmetic
Scout date: 2026-07-18
Checkout: `/Users/jordanwinkelman/Documents/GitHub/computer-applications-demo`

## Finding
The lesson teaches scalar arithmetic. The source already appears fixed.
EOF
  cat > "$data/scout-old/report.md" <<'EOF'
# Older report

## Finding
Older context.
EOF
  touch -t 202607181300.00 "$active_report_path"
  touch -t 202607181200.00 "$new_report_path"
  touch -t 202607171200.00 "$data/scout-old/report.md"

  fm_write_meta "$state/scout-active.meta" \
    "window=sess:alive-scout-active" \
    "worktree=$dir/wt-scout-active" \
    "project=$dir/projects/cad" \
    "kind=scout" \
    "mode=report"

  FM_DASHBOARD_TODAY=2026-07-18 FM_DASHBOARD_REPORT_LIMIT=12 run_probe_json "$dir" "$out"

  assert_jq_true '.fleet | map(select(.task_id == "scout-active")) | length == 1' \
    "$out" "active scout with a report file should not duplicate"
  assert_jq_true '.fleet[] | select(.task_id == "scout-new" and .display_title == "ShowMe is aggregate but this is teaching arithmetic" and .kind == "scout" and .mode == "report" and .attention == "done" and .backend_liveness == "archived" and .source == "report-store" and .report_url == "/api/reports/scout-new" and .current_state.source == "report-store" and (.current_state.detail | contains("scalar arithmetic")) and .pipeline.profile == "scout_report" and .pipeline.main_stage == "review_ready" and .pipeline.next_human_action == "review scout report" and .pipeline.source_confidence == "approximate" and (.pipeline.evidence | index("source=report-store")) and (.pipeline.evidence | index("worktree=missing") | not))' \
    "$out" "completed scout report row did not expose answered report metadata"
  [ "$(jq_value '.fleet[] | select(.task_id == "scout-new") | .report_path' "$out")" = "$new_report_path" ] \
    || fail "completed scout report did not expose the local report path"
  assert_jq_true '[.stations[] | select(.station == "answered") | .task_id] == ["scout-new"]' \
    "$out" "completed scout reports did not feed the answered lane with the report limit applied"
  assert_jq_true '.fleet | map(.task_id) | index("scout-old") | not' \
    "$out" "completed scout reports did not filter to today"
  pass "completed scout reports remain visible as answered dashboard rows"
}

test_report_output() {
  local dir out
  dir=$(make_case report)
  out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" "$PROBE" --report)
  assert_contains "$out" "Mockup A live update:" "report missing Mockup A section"
  assert_contains "$out" "Mockup D replay:" "report missing Mockup D section"
  assert_contains "$out" "timestamp" "report missing ledger fields"
  pass "report mode prints the dashboard findings template"
}

test_fleet_meta_and_station_mapping
test_display_title_precedence_and_subtitle
test_git_and_pr_fields_are_extracted
test_empty_fleet_output
test_arrival_ledger_keeps_landed_ships_visible_today
test_completion_timeline_drives_done_lanes_and_reconciliation
test_pipeline_snapshot_profiles_and_stages
test_replay_sources_are_extracted
test_completed_scout_reports_feed_answered_lane
test_report_output
