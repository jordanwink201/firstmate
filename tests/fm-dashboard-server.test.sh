#!/usr/bin/env bash
# Behavior tests for bin/fm-dashboard-server.sh.
#
# The dashboard server is read-only localhost glue around fm-dashboard-probe.sh:
# it serves Mockup A v1, exposes cached probe JSON/report endpoints, and keeps
# browser snapshot polling off the slow probe path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SERVER="$ROOT/bin/fm-dashboard-server.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard-server)
SERVER_PIDS=()

stop_servers() {
  local pid
  for pid in "${SERVER_PIDS[@]:-}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  SERVER_PIDS=()
}

cleanup_all() {
  stop_servers
  fm_test_cleanup
}
trap cleanup_all EXIT

make_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/fake" "$dir/fmhome/state" "$dir/fmhome/data"
  cat > "$dir/fake/snapshot.json" <<'JSON'
{
  "fleet": [
    {
      "task_id": "alpha-t1",
      "display_title": "Alpha task title",
      "display_subtitle": "validating",
      "attention": "needs_action",
      "branch": "fm/alpha-t1",
      "commit_short": "abc123def",
      "pr_url": "https://github.com/example/alpha/pull/12",
      "project": "/tmp/projects/alpha",
      "worktree": "/tmp/worktrees/alpha-t1",
      "kind": "ship",
      "mode": "no-mistakes",
      "harness": "codex",
      "model": "gpt-5",
      "effort": "high",
      "backend": "tmux",
      "backend_liveness": "alive",
      "pipeline": {
        "profile": "cad_no_mistakes",
        "main_stage": "validation_gate",
        "stage_label": "Validation Gate",
        "next_human_action": "answer gate finding",
        "source_confidence": "live",
        "evidence": ["meta.mode=no-mistakes", "current_state.source=run-step"],
        "validation_branch": {
          "name": "no-mistakes",
          "step": "review",
          "status": "awaiting_approval",
          "findings": 2,
          "pr_url": "https://github.com/example/alpha/pull/12",
          "superseded_status_log": false
        }
      },
      "current_state": {"state": "working", "source": "run-step", "detail": "validating", "raw": "state: working"},
      "latest_status": {"path": "/tmp/state/alpha-t1.status", "verb": "working", "note": "validating", "raw": "working: validating"}
    }
  ],
  "stations": [
    {"task_id": "alpha-t1", "station": "gate_run", "reason": "working run-step has validation or test wording"}
  ],
  "replay_sources": {
    "quality": "approximate",
    "minimum_event_ledger": {"implemented": false, "fields": ["timestamp", "task_id", "event_type", "station", "source", "detail"]}
  }
}
JSON
  printf 'ok\n' > "$dir/fake/behavior"
  cat > "$dir/fake/fm-dashboard-probe.sh" <<'SH'
#!/usr/bin/env bash
set -u
: "${FM_DASHBOARD_FAKE_DIR:?}"
printf '%s\n' "$*" >> "$FM_DASHBOARD_FAKE_DIR/probe.args"
behavior=$(cat "$FM_DASHBOARD_FAKE_DIR/behavior" 2>/dev/null || printf ok)
case "$behavior" in
  ok)
    case "${1:-}" in
      --report) printf 'Fleet report\nready\n' ;;
      --json|"") cat "$FM_DASHBOARD_FAKE_DIR/snapshot.json" ;;
      *) printf 'unexpected mode: %s\n' "$1" >&2; exit 2 ;;
    esac
    ;;
  fail)
    printf 'probe exploded\n' >&2
    exit 42
    ;;
  slow)
    sleep 0.4
    cat "$FM_DASHBOARD_FAKE_DIR/snapshot.json"
    ;;
  *)
    printf 'unknown fake behavior: %s\n' "$behavior" >&2
    exit 99
    ;;
esac
SH
  chmod +x "$dir/fake/fm-dashboard-probe.sh"
  printf '%s\n' "$dir"
}

http_request() {
  local method=$1 base=$2 path=$3 out=$4
  curl -sS -o "$out" -w '%{http_code}' -X "$method" "$base$path"
}

http_request_with_headers() {
  local method=$1 base=$2 path=$3 out=$4 headers=$5
  curl -sS -D "$headers" -o "$out" -w '%{http_code}' -X "$method" "$base$path"
}

header_value() {
  local file=$1 name=$2
  name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  awk -v name="$name" '
    {
      line = $0
      sub(/\r$/, "", line)
      lower = tolower(line)
      if (index(lower, name ":") == 1) {
        sub(/^[^:]*:[ \t]*/, "", line)
        value = line
      }
    }
    END { print value }
  ' "$file"
}

probe_json_count() {
  local dir=$1
  if [ ! -f "$dir/fake/probe.args" ]; then
    printf '0\n'
    return
  fi
  grep -c -- '--json' "$dir/fake/probe.args" || true
}

wait_for_probe_count() {
  local dir=$1 expected=$2 i count
  i=0
  while [ "$i" -lt 100 ]; do
    count=$(probe_json_count "$dir")
    if [ "$count" -ge "$expected" ]; then
      return 0
    fi
    i=$((i + 1))
    sleep 0.05
  done
  fail "timed out waiting for $expected snapshot probe run(s); saw $(probe_json_count "$dir")"
}

set_snapshot_task_id() {
  local dir=$1 task_id=$2
  jq --arg task_id "$task_id" \
    '.fleet[0].task_id = $task_id | .stations[0].task_id = $task_id' \
    "$dir/fake/snapshot.json" > "$dir/fake/snapshot.json.tmp"
  mv "$dir/fake/snapshot.json.tmp" "$dir/fake/snapshot.json"
}

wait_for_server() {
  local pid=$1 log=$2 port i code out
  out="${log}.health"
  i=0
  while [ "$i" -lt 100 ]; do
    port=$(sed -n 's/.*http:\/\/127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$log" 2>/dev/null | tail -1)
    if [ -n "$port" ]; then
      code=$(curl -sS -o "$out" -w '%{http_code}' "http://127.0.0.1:$port/healthz" 2>/dev/null || true)
      if [ "$code" = 200 ]; then
        printf '%s\n' "$port"
        return 0
      fi
    fi
    kill -0 "$pid" 2>/dev/null || return 1
    i=$((i + 1))
    sleep 0.05
  done
  return 1
}

start_server() {
  local dir=$1 refresh_ms="${2:-10000}"
  local log="$dir/server.log" err="$dir/server.err" pid port
  stop_servers
  FM_HOME="$dir/fmhome" \
    FM_DASHBOARD_FAKE_DIR="$dir/fake" \
    FM_DASHBOARD_PROBE_BIN="$dir/fake/fm-dashboard-probe.sh" \
    FM_DASHBOARD_REFRESH_MS="$refresh_ms" \
    FM_DASHBOARD_PROBE_TIMEOUT_MS=1200 \
    "$SERVER" --host 127.0.0.1 --port 0 > "$log" 2> "$err" &
  pid=$!
  SERVER_PIDS+=("$pid")
  port=$(wait_for_server "$pid" "$log") || {
    fail "server did not become healthy"$'\n'"--- stdout ---"$'\n'"$(cat "$log" 2>/dev/null)"$'\n'"--- stderr ---"$'\n'"$(cat "$err" 2>/dev/null)"
  }
  printf 'http://127.0.0.1:%s\n' "$port"
}

test_routes_and_methods() {
  local dir base code body headers
  dir=$(make_case routes)
  base=$(start_server "$dir")

  body="$dir/home.html"
  code=$(http_request GET "$base" / "$body")
  [ "$code" = 200 ] || fail "/ returned HTTP $code"
  assert_grep '<title>Firstmate Fleet Dashboard</title>' "$body" "/ did not return dashboard HTML"
  assert_grep '<span class="ship-title">' "$body" "dashboard HTML does not render card titles first"
  assert_grep 'displayTitle(ship)' "$body" "dashboard HTML does not prefer display_title for cards"
  assert_grep 'Open PR' "$body" "dashboard HTML does not render a PR link in details"
  assert_grep 'attention-badge' "$body" "dashboard HTML does not include needs-action badge markup"
  assert_grep 'Arrived Today' "$body" "dashboard HTML does not expose Arrived Today lane"
  assert_grep 'What matters' "$body" "dashboard detail does not prioritize captain-facing fields"
  assert_grep 'Pipeline' "$body" "dashboard detail does not render the pipeline rail section"
  assert_grep 'pipelineRailHtml' "$body" "dashboard HTML does not include pipeline rail renderer"
  assert_grep 'function shipSummaryCardInnerHtml' "$body" "dashboard HTML does not share fleet summary card rendering"
  assert_grep 'pipelineSummaryHtml(pipeline)' "$body" "fleet summary cards do not render pipeline summaries"
  assert_grep 'shipSummaryCardInnerHtml(ship, station)' "$body" "top fleet strip does not use the pipeline-aware summary renderer"
  assert_grep 'shipSummaryCardInnerHtml(ship, def.id)' "$body" "lane cards do not use the pipeline-aware summary renderer"
  assert_grep 'Pipeline summary' "$body" "fleet summary cards do not expose a compact pipeline summary"
  assert_grep 'No-mistakes' "$body" "dashboard detail does not render the no-mistakes sub-rail section"
  assert_grep 'validationBranchHtml' "$body" "dashboard HTML does not include validation branch renderer"
  assert_grep 'Validation detail not tracked for this profile.' "$body" "dashboard HTML does not include fallback copy for non-no-mistakes profiles"
  assert_grep 'Validation detail unavailable for this task.' "$body" "dashboard HTML does not include unavailable copy for no-mistakes rows without validation detail"
  assert_grep 'Operational refs' "$body" "dashboard detail does not de-emphasize operational fields"
  assert_grep 'Needs you' "$body" "dashboard detail does not expose the action state"
  assert_no_grep '>At Port<' "$body" "dashboard still renders the old At Port lane"

  body="$dir/snapshot.json"
  headers="$dir/snapshot.headers"
  code=$(http_request_with_headers GET "$base" /api/snapshot "$body" "$headers")
  [ "$code" = 200 ] || fail "/api/snapshot returned HTTP $code: $(cat "$body")"
  jq -e '.fleet[0].task_id == "alpha-t1" and .fleet[0].display_title == "Alpha task title" and .fleet[0].pr_url == "https://github.com/example/alpha/pull/12" and .fleet[0].pipeline.main_stage == "validation_gate" and .fleet[0].pipeline.validation_branch.findings == 2 and .stations[0].station == "gate_run"' "$body" >/dev/null \
    || fail "/api/snapshot did not return valid probe JSON: $(cat "$body")"
  [ "$(header_value "$headers" x-firstmate-cache)" = fresh ] \
    || fail "/api/snapshot did not mark a fresh cache response: $(cat "$headers")"
  [ -n "$(header_value "$headers" x-firstmate-captured-at)" ] \
    || fail "/api/snapshot did not expose x-firstmate-captured-at"
  [ "$(header_value "$headers" x-firstmate-refreshing)" = false ] \
    || fail "/api/snapshot did not expose x-firstmate-refreshing=false"

  body="$dir/report.txt"
  code=$(http_request GET "$base" /api/report "$body")
  [ "$code" = 200 ] || fail "/api/report returned HTTP $code: $(cat "$body")"
  assert_contains "$(cat "$body")" "Fleet report" "/api/report did not return probe report text"

  body="$dir/health.json"
  code=$(http_request GET "$base" /healthz "$body")
  [ "$code" = 200 ] || fail "/healthz returned HTTP $code: $(cat "$body")"
  jq -e '.ok == true' "$body" >/dev/null || fail "/healthz did not return ok JSON: $(cat "$body")"

  body="$dir/favicon.ico"
  code=$(http_request GET "$base" /favicon.ico "$body")
  [ "$code" = 204 ] || fail "/favicon.ico returned HTTP $code instead of 204"

  body="$dir/post.json"
  code=$(http_request POST "$base" /api/snapshot "$body")
  [ "$code" = 405 ] || fail "POST /api/snapshot returned HTTP $code instead of 405"
  jq -e '.error == "method_not_allowed" and (.allowed | index("GET"))' "$body" >/dev/null \
    || fail "405 body was not clear JSON: $(cat "$body")"

  body="$dir/missing.json"
  code=$(http_request GET "$base" /missing "$body")
  [ "$code" = 404 ] || fail "unknown route returned HTTP $code instead of 404"
  jq -e '.error == "not_found"' "$body" >/dev/null || fail "404 body was not clear JSON: $(cat "$body")"

  pass "dashboard server serves HTML, cached snapshot, report, health, 405, and 404"
}

test_initial_no_cache_snapshot_waits_for_boot_probe() {
  local dir base code body count
  dir=$(make_case initial-wait)
  printf 'slow\n' > "$dir/fake/behavior"
  base=$(start_server "$dir")

  body="$dir/initial.json"
  code=$(http_request GET "$base" /api/snapshot "$body")
  [ "$code" = 200 ] || fail "initial no-cache snapshot returned HTTP $code: $(cat "$body")"
  jq -e '.fleet[0].task_id == "alpha-t1"' "$body" >/dev/null \
    || fail "initial no-cache snapshot did not return raw probe JSON: $(cat "$body")"
  count=$(probe_json_count "$dir")
  [ "$count" = 1 ] || fail "initial no-cache snapshot spawned $count probe runs instead of waiting for the boot probe"
  pass "initial no-cache snapshot waits for the boot probe and returns raw JSON"
}

test_warm_cache_snapshot_does_not_launch_probe() {
  local dir base code body headers before after
  dir=$(make_case warm-cache)
  base=$(start_server "$dir")

  body="$dir/first.json"
  code=$(http_request GET "$base" /api/snapshot "$body")
  [ "$code" = 200 ] || fail "initial snapshot returned HTTP $code: $(cat "$body")"
  wait_for_probe_count "$dir" 1
  before=$(probe_json_count "$dir")

  printf 'fail\n' > "$dir/fake/behavior"
  body="$dir/warm.json"
  headers="$dir/warm.headers"
  code=$(http_request_with_headers GET "$base" /api/snapshot "$body" "$headers")
  after=$(probe_json_count "$dir")
  [ "$code" = 200 ] || fail "warm-cache snapshot returned HTTP $code: $(cat "$body")"
  jq -e '.fleet[0].task_id == "alpha-t1"' "$body" >/dev/null \
    || fail "warm-cache snapshot did not return cached raw JSON: $(cat "$body")"
  [ "$after" = "$before" ] || fail "warm-cache snapshot launched a new probe: before=$before after=$after"
  [ "$(header_value "$headers" x-firstmate-cache)" = fresh ] \
    || fail "warm-cache snapshot did not report fresh cache: $(cat "$headers")"
  pass "warm-cache snapshot returns immediately without launching a new probe"
}

test_due_refresh_runs_in_background_while_serving_cache() {
  local dir base code body headers before during after
  dir=$(make_case due-refresh)
  base=$(start_server "$dir" 120)

  body="$dir/first.json"
  code=$(http_request GET "$base" /api/snapshot "$body")
  [ "$code" = 200 ] || fail "initial snapshot returned HTTP $code: $(cat "$body")"
  wait_for_probe_count "$dir" 1
  set_snapshot_task_id "$dir" beta-t2
  printf 'slow\n' > "$dir/fake/behavior"
  wait_for_probe_count "$dir" 2
  before=$(probe_json_count "$dir")

  body="$dir/during.json"
  headers="$dir/during.headers"
  code=$(http_request_with_headers GET "$base" /api/snapshot "$body" "$headers")
  during=$(probe_json_count "$dir")
  [ "$code" = 200 ] || fail "snapshot during background refresh returned HTTP $code: $(cat "$body")"
  jq -e '.fleet[0].task_id == "alpha-t1"' "$body" >/dev/null \
    || fail "snapshot during background refresh did not serve the last-good cache: $(cat "$body")"
  [ "$(header_value "$headers" x-firstmate-refreshing)" = true ] \
    || fail "snapshot during background refresh did not expose x-firstmate-refreshing=true: $(cat "$headers")"
  [ "$(header_value "$headers" x-firstmate-cache)" = stale-while-refresh ] \
    || fail "snapshot during background refresh did not mark stale-while-refresh: $(cat "$headers")"
  [ "$during" = "$before" ] || fail "request during background refresh launched another probe: before=$before during=$during"

  sleep 0.5
  body="$dir/after.json"
  code=$(http_request GET "$base" /api/snapshot "$body")
  [ "$code" = 200 ] || fail "snapshot after background refresh returned HTTP $code: $(cat "$body")"
  jq -e '.fleet[0].task_id == "beta-t2"' "$body" >/dev/null \
    || fail "snapshot after background refresh did not publish the refreshed cache: $(cat "$body")"
  after=$(probe_json_count "$dir")
  [ "$after" -ge 2 ] || fail "background refresh did not run a second probe"
  pass "due refresh runs in the background while cached JSON is served"
}

test_probe_failure_with_no_cache_returns_503() {
  local dir base code body headers
  dir=$(make_case no-cache-failure)
  printf 'fail\n' > "$dir/fake/behavior"
  base=$(start_server "$dir")

  body="$dir/failure.json"
  headers="$dir/failure.headers"
  code=$(http_request_with_headers GET "$base" /api/snapshot "$body" "$headers")
  [ "$code" = 503 ] || fail "no-cache failing snapshot returned HTTP $code instead of 503: $(cat "$body")"
  jq -e '.error == "probe_failed" and .cached == false and (.message | contains("probe exited 42"))' "$body" >/dev/null \
    || fail "no-cache failure body was not clear error JSON: $(cat "$body")"
  [ "$(header_value "$headers" x-firstmate-cache)" = none ] \
    || fail "no-cache failure did not expose x-firstmate-cache=none: $(cat "$headers")"
  assert_contains "$(header_value "$headers" x-firstmate-error)" "probe exited 42" "no-cache failure header did not expose probe failure"
  pass "probe failure with no cache returns 503 clear error JSON"
}

test_probe_failure_with_last_good_returns_cached_snapshot() {
  local dir base code body headers
  dir=$(make_case cached-failure)
  base=$(start_server "$dir" 120)

  body="$dir/first.json"
  code=$(http_request GET "$base" /api/snapshot "$body")
  [ "$code" = 200 ] || fail "initial snapshot returned HTTP $code: $(cat "$body")"
  wait_for_probe_count "$dir" 1

  printf 'fail\n' > "$dir/fake/behavior"
  wait_for_probe_count "$dir" 2
  sleep 0.1
  body="$dir/failure.json"
  headers="$dir/failure.headers"
  code=$(http_request_with_headers GET "$base" /api/snapshot "$body" "$headers")
  [ "$code" = 200 ] || fail "cached failing snapshot returned HTTP $code instead of 200: $(cat "$body")"
  jq -e '.fleet[0].task_id == "alpha-t1" and .stations[0].station == "gate_run"' "$body" >/dev/null \
    || fail "cached failure did not return last-good raw snapshot JSON: $(cat "$body")"
  [ "$(header_value "$headers" x-firstmate-cache)" = last-good ] \
    || fail "cached failure did not expose x-firstmate-cache=last-good: $(cat "$headers")"
  assert_contains "$(header_value "$headers" x-firstmate-error)" "probe exited 42" "cached failure header did not expose probe failure"
  pass "probe failure with a last-good cache returns 200 cached JSON plus error headers"
}

test_concurrent_snapshot_requests_share_one_probe_run() {
  local dir base out1 out2 code1 code2 count
  dir=$(make_case single-flight)
  printf 'slow\n' > "$dir/fake/behavior"
  base=$(start_server "$dir")

  out1="$dir/one.json"
  out2="$dir/two.json"
  curl -sS -o "$out1" -w '%{http_code}' "$base/api/snapshot" > "$dir/code1" &
  local pid1=$!
  sleep 0.05
  curl -sS -o "$out2" -w '%{http_code}' "$base/api/snapshot" > "$dir/code2" &
  local pid2=$!
  wait "$pid1" || fail "first concurrent curl failed"
  wait "$pid2" || fail "second concurrent curl failed"

  code1=$(cat "$dir/code1")
  code2=$(cat "$dir/code2")
  [ "$code1" = 200 ] || fail "first concurrent snapshot returned HTTP $code1: $(cat "$out1")"
  [ "$code2" = 200 ] || fail "second concurrent snapshot returned HTTP $code2: $(cat "$out2")"
  jq -e '.fleet[0].task_id == "alpha-t1"' "$out1" >/dev/null || fail "first concurrent response was not snapshot JSON"
  jq -e '.fleet[0].task_id == "alpha-t1"' "$out2" >/dev/null || fail "second concurrent response was not snapshot JSON"
  count=$(grep -c -- '--json' "$dir/fake/probe.args" || true)
  [ "$count" = 1 ] || fail "concurrent snapshot requests spawned $count probe runs instead of 1"
  pass "concurrent snapshot requests share one in-flight probe run"
}

test_routes_and_methods
test_initial_no_cache_snapshot_waits_for_boot_probe
test_warm_cache_snapshot_does_not_launch_probe
test_due_refresh_runs_in_background_while_serving_cache
test_probe_failure_with_no_cache_returns_503
test_probe_failure_with_last_good_returns_cached_snapshot
test_concurrent_snapshot_requests_share_one_probe_run
