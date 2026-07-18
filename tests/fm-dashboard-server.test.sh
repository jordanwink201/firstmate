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
      "timeline": {"done_at": "", "done_date": "", "source": "none", "freshness": "none"},
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
    },
    {
      "task_id": "beta-t2",
      "display_title": "Beta completed task",
      "display_subtitle": "completed earlier",
      "attention": "done",
      "branch": "fm/beta-t2",
      "commit_short": "def456abc",
      "pr_url": "",
      "project": "/tmp/projects/beta",
      "worktree": "/tmp/worktrees/beta-t2",
      "kind": "ship",
      "mode": "direct-PR",
      "harness": "codex",
      "model": "gpt-5",
      "effort": "high",
      "backend": "archived",
      "backend_liveness": "archived",
      "timeline": {"done_at": "2026-07-16T13:52:00Z", "done_date": "2026-07-16", "source": "status-line", "freshness": "earlier"},
      "pipeline": {
        "profile": "direct_pr",
        "main_stage": "landed",
        "stage_label": "Landed",
        "next_human_action": "move/comment in Basecamp",
        "source_confidence": "approximate",
        "evidence": ["timeline.source=status-line"],
        "validation_branch": null
      },
      "current_state": {"state": "done", "source": "status-log", "detail": "completed earlier", "raw": "done: completed earlier"},
      "latest_status": {"path": "/tmp/state/beta-t2.status", "verb": "done", "note": "completed earlier", "raw": "2026-07-16 done: completed earlier"}
    },
    {
      "task_id": "gamma-report",
      "display_title": "Gamma answered report",
      "display_subtitle": "gamma-report · scout report",
      "attention": "done",
      "branch": "",
      "commit_short": "",
      "pr_url": "",
      "report_url": "/api/reports/gamma-report",
      "report_path": "/tmp/fmhome/data/gamma-report/report.md",
      "project": "cad",
      "worktree": "",
      "kind": "scout",
      "mode": "report",
      "harness": "",
      "model": "",
      "effort": "",
      "backend": "archived",
      "backend_liveness": "archived",
      "timeline": {"done_at": "2026-07-18T12:00:00Z", "done_date": "2026-07-18", "source": "report-file-mtime", "freshness": "today"},
      "pipeline": {
        "profile": "scout_report",
        "main_stage": "review_ready",
        "stage_label": "Review Ready",
        "next_human_action": "review scout report",
        "source_confidence": "approximate",
        "evidence": ["source=report-store"],
        "validation_branch": null
      },
      "current_state": {"state": "done", "source": "report-store", "detail": "Report summary", "raw": "/tmp/fmhome/data/gamma-report/report.md"},
      "latest_status": {"path": "/tmp/fmhome/data/gamma-report/report.md", "verb": "done", "note": "Report summary", "raw": "done: scout report written"}
    },
    {
      "task_id": "delta-report",
      "display_title": "Delta newer report",
      "display_subtitle": "delta-report · scout report",
      "attention": "done",
      "branch": "",
      "commit_short": "",
      "pr_url": "",
      "report_url": "/api/reports/delta-report",
      "report_path": "/tmp/fmhome/data/delta-report/report.md",
      "project": "cad",
      "worktree": "",
      "kind": "scout",
      "mode": "report",
      "harness": "",
      "model": "",
      "effort": "",
      "backend": "archived",
      "backend_liveness": "archived",
      "timeline": {"done_at": "2026-07-18T16:20:00Z", "done_date": "2026-07-18", "source": "report-file-mtime", "freshness": "today"},
      "pipeline": {
        "profile": "scout_report",
        "main_stage": "review_ready",
        "stage_label": "Review Ready",
        "next_human_action": "review scout report",
        "source_confidence": "approximate",
        "evidence": ["source=report-store"],
        "validation_branch": null
      },
      "current_state": {"state": "done", "source": "report-store", "detail": "Newer report summary", "raw": "/tmp/fmhome/data/delta-report/report.md"},
      "latest_status": {"path": "/tmp/fmhome/data/delta-report/report.md", "verb": "done", "note": "Newer report summary", "raw": "done: scout report written"}
    }
  ],
  "stations": [
    {"task_id": "alpha-t1", "station": "gate_run", "reason": "working run-step has validation or test wording"},
    {"task_id": "beta-t2", "station": "done_earlier", "reason": "done signal has prior-date evidence"},
    {"task_id": "gamma-report", "station": "answered", "reason": "completed scout report is available"},
    {"task_id": "delta-report", "station": "answered", "reason": "completed scout report is available"}
  ],
  "supervision": {
    "watcher": {"fresh": true, "stale": false, "age_seconds": 12},
    "wake_queue": {"pending": 1}
  },
  "replay_sources": {
    "quality": "approximate",
    "minimum_event_ledger": {"implemented": false, "fields": ["timestamp", "task_id", "event_type", "station", "source", "detail"]}
  }
}
JSON
  mkdir -p "$dir/fmhome/data/gamma-report" "$dir/fmhome/data/delta-report"
  cat > "$dir/fmhome/data/gamma-report/report.md" <<'EOF'
# Gamma Report

## Finding
Report summary
EOF
  cat > "$dir/fmhome/data/delta-report/report.md" <<'EOF'
# Delta Report

## Finding
Newer report summary
EOF
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

assert_dashboard_render_contract() {
  local html=$1 snapshot=$2
  node - "$html" "$snapshot" <<'NODE' || fail "dashboard render contract failed"
const fs = require('node:fs');
const vm = require('node:vm');

const html = fs.readFileSync(process.argv[2], 'utf8');
const snapshot = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const match = html.match(/<script>([\s\S]*)<\/script>/);
if (!match) throw new Error('dashboard script not found');

class Element {
  constructor(id) {
    this.id = id;
    this.innerHTML = '';
    this.className = '';
  }
}

const elements = new Map(['meta', 'banner', 'fleetStrip', 'lanes', 'overlay', 'detail'].map(id => [id, new Element(id)]));
const document = {
  getElementById(id) {
    if (!elements.has(id)) elements.set(id, new Element(id));
    return elements.get(id);
  },
  addEventListener() {},
};

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const context = {
  document,
  window: {},
  Date,
  Intl,
  Number,
  String,
  Boolean,
  Promise,
  setInterval() {},
  clearInterval() {},
  fetch() { throw new Error('render contract must not fetch'); },
};
context.window.Intl = Intl;
vm.createContext(context);
vm.runInContext(match[1].replace(/\n\s*refresh\(\);\s*$/, '\n'), context);

context.state.snapshot = snapshot;
context.state.loading = false;
context.state.error = '';
context.state.stale = false;
context.state.lastGoodAt = Date.now();
context.render();

const strip = elements.get('fleetStrip').innerHTML;
const detail = elements.get('detail').innerHTML;
const lanes = elements.get('lanes').innerHTML;
const meta = elements.get('meta').innerHTML;
const mainRail = strip.slice(strip.indexOf('class="pipeline-rail"'), strip.indexOf('class="pipeline-branch"'));
const branchRail = strip.slice(strip.indexOf('class="pipeline-branch"'));
const mainRailSteps = (mainRail.match(/class="rail-step"/g) || []).length;
const branchRailSteps = (branchRail.match(/class="rail-step"/g) || []).length;

assert(context.state.selectedId === 'alpha-t1', `expected selected alpha-t1, got ${context.state.selectedId}`);
assert(strip.includes('selected-pipeline-title'), 'top strip must keep selected task identity');
assert(strip.includes('class="pipeline-rail"'), 'top strip must render the selected task pipeline rail');
assert(mainRailSteps === 9, `top pipeline rail should render 9 main stages, got ${mainRailSteps}`);
assert(strip.includes('class="pipeline-branch"'), 'top strip should render the no-mistakes branch from validation');
assert(branchRailSteps === 5, `top no-mistakes branch should render 5 stages, got ${branchRailSteps}`);
assert(strip.indexOf('class="pipeline-branch"') > strip.indexOf('class="pipeline-rail"'), 'no-mistakes branch should sit under the main rail');
assert(strip.includes('aria-label="No-mistakes validation branch"'), 'top strip should identify the no-mistakes validation branch');
assert(strip.includes('class="rail-dot"'), 'top pipeline rail should render status dots');
assert(strip.includes('Validation') && strip.includes('Now'), 'top pipeline rail should mark Validation as current');
assert(strip.includes('No-mistakes') && strip.includes('Awaiting Approval'), 'top branch should expose no-mistakes status');
assert(!strip.includes('ship-tab'), 'top strip must not regress to fleet task cards');
assert(!strip.includes('data-ship='), 'top strip must not contain selectable ship cards');
assert(detail.includes('Pipeline status'), 'detail panel should keep compact pipeline status');
assert(!detail.includes('class="pipeline-rail"'), 'detail panel must not duplicate the top pipeline rail');
assert(!detail.includes('class="validation-rail"'), 'detail panel must not duplicate the no-mistakes validation branch rail');
assert(!detail.includes('detail-section-title">No-mistakes</div>'), 'detail panel should not carry a second no-mistakes rail section');
assert(lanes.includes('Answered Today'), 'lanes should render the Answered Today station');
assert(lanes.includes('Gamma answered report'), 'answered lane should render completed report rows');
const deltaIndex = lanes.indexOf('Delta newer report');
const gammaIndex = lanes.indexOf('Gamma answered report');
assert(deltaIndex > -1 && gammaIndex > -1 && deltaIndex < gammaIndex, 'answered lane should sort cards by latest timestamp first');
assert(/Reported \d{1,2}:\d{2}(am|pm) Jul 18/.test(lanes), 'answered report cards should render compact time and date chips');
assert(lanes.includes('Done Earlier'), 'lanes should render the Done Earlier station');
assert(/Done \d{1,2}:\d{2}(am|pm) Jul 16/.test(lanes), 'done cards should render compact time and date chips');
assert(!lanes.includes('empty-lane'), 'zero-count lanes should stay hidden at runtime');
assert(!lanes.includes('station-chip'), 'lane cards should not repeat station chips at runtime');
assert(!lanes.includes('attention-badge'), 'lane cards should not repeat needs-action badges at runtime');
assert(meta.includes('4 records'), 'meta should count restored fleet records');
assert(meta.includes('state lag'), 'meta should surface supervision lag when wake queue is pending');

context.state.selectedId = 'gamma-report';
context.render();
const reportStrip = elements.get('fleetStrip').innerHTML;
const reportDetail = elements.get('detail').innerHTML;
assert(reportStrip.includes('Gamma answered report'), 'answered report should render in the selected pipeline identity');
assert(reportStrip.includes('Review') && reportStrip.includes('Now'), 'answered report should mark Review as current in the top rail');
assert(!reportStrip.includes('class="pipeline-branch"'), 'answered report should not render a no-mistakes branch');
assert(reportDetail.includes('Answered Today'), 'answered report detail should keep the current station context');
assert(reportDetail.includes('Report ready'), 'answered report detail should expose report-ready action state');
assert(reportDetail.includes('Open report'), 'answered report detail should link to the Markdown report');
assert(reportDetail.includes('/tmp/fmhome/data/gamma-report/report.md'), 'answered report detail should expose the local report path in operational refs');
assert(!reportDetail.includes('<span class="pill">Scout report</span>'), 'answered report detail should not repeat the profile pill');
assert(!reportDetail.includes('<span class="task-id">gamma-report</span>'), 'answered report detail should not repeat the task id header');
assert(!reportDetail.includes('<span class="pill">gamma-report</span>'), 'answered report detail should not repeat the task id action pill');
assert(!reportDetail.includes('What matters'), 'answered report detail should not duplicate the top-rail next action');
assert(!reportDetail.includes('Pipeline status'), 'answered report detail should not duplicate the top-rail pipeline status');
NODE
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
  assert_grep 'Answered Today' "$body" "dashboard HTML does not expose Answered Today lane"
  assert_grep 'Arrived Today' "$body" "dashboard HTML does not expose Arrived Today lane"
  assert_grep 'Done Earlier' "$body" "dashboard HTML does not expose Done Earlier lane"
  assert_grep 'Needs Reconciliation' "$body" "dashboard HTML does not expose Needs Reconciliation lane"
  assert_grep 'aria-label="Selected task pipeline"' "$body" "top rail is not scoped to the selected task pipeline"
  assert_grep 'renderSelectedPipelineRail' "$body" "dashboard HTML does not include selected-task top pipeline renderer"
  assert_grep 'selected-pipeline-title' "$body" "top rail does not expose selected task identity"
  assert_grep 'selected-pipeline-next' "$body" "top rail does not expose selected task next action"
  assert_grep 'rail-dot' "$body" "dashboard pipeline rail does not render Jenkins-style status dots"
  assert_grep 'pipeline-branch' "$body" "dashboard top rail does not render the no-mistakes branch"
  assert_grep 'noMistakesBranchHtml' "$body" "dashboard HTML does not include top-rail no-mistakes branch renderer"
  assert_grep 'doneChipHtml' "$body" "dashboard HTML does not include done date chip renderer"
  assert_grep 'reportChipHtml' "$body" "dashboard HTML does not include report date chip renderer"
  assert_grep 'Open report' "$body" "dashboard HTML does not render a report link in details"
  assert_no_grep 'function shipSummaryCardInnerHtml' "$body" "top rail still carries fleet-card summary rendering"
  assert_grep 'What matters' "$body" "dashboard detail does not prioritize captain-facing fields"
  assert_grep 'Pipeline status' "$body" "dashboard detail does not render compact pipeline status"
  assert_grep 'pipelineRailHtml' "$body" "dashboard HTML does not include pipeline rail renderer"
  assert_no_grep '<div class="detail-section-title">No-mistakes</div>' "$body" "dashboard detail still carries the no-mistakes sub-rail section"
  assert_grep 'Operational refs' "$body" "dashboard detail does not de-emphasize operational fields"
  assert_grep 'Needs you' "$body" "dashboard detail does not expose the action state"
  assert_no_grep '>At Port<' "$body" "dashboard still renders the old At Port lane"

  body="$dir/snapshot.json"
  headers="$dir/snapshot.headers"
  code=$(http_request_with_headers GET "$base" /api/snapshot "$body" "$headers")
  [ "$code" = 200 ] || fail "/api/snapshot returned HTTP $code: $(cat "$body")"
  jq -e '.fleet[0].task_id == "alpha-t1" and .fleet[0].display_title == "Alpha task title" and .fleet[0].pr_url == "https://github.com/example/alpha/pull/12" and .fleet[0].pipeline.main_stage == "validation_gate" and .fleet[0].pipeline.validation_branch.findings == 2 and .fleet[0].timeline.source == "none" and .stations[0].station == "gate_run" and .fleet[1].timeline.freshness == "earlier" and .stations[1].station == "done_earlier" and .fleet[2].kind == "scout" and .fleet[2].report_url == "/api/reports/gamma-report" and .fleet[2].pipeline.main_stage == "review_ready" and .stations[2].station == "answered" and .fleet[3].task_id == "delta-report" and .stations[3].station == "answered" and .supervision.wake_queue.pending == 1' "$body" >/dev/null \
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

  body="$dir/report-file.md"
  code=$(http_request GET "$base" /api/reports/gamma-report "$body")
  [ "$code" = 200 ] || fail "/api/reports/gamma-report returned HTTP $code: $(cat "$body")"
  assert_contains "$(cat "$body")" "# Gamma Report" "/api/reports/gamma-report did not return the stored Markdown report"

  body="$dir/bad-report.json"
  code=$(http_request GET "$base" /api/reports/bad%2Fid "$body")
  [ "$code" = 400 ] || fail "/api/reports/bad%2Fid returned HTTP $code instead of 400: $(cat "$body")"
  jq -e '.error == "bad_report_id"' "$body" >/dev/null \
    || fail "bad report id body was not clear JSON: $(cat "$body")"

  body="$dir/missing-report.json"
  code=$(http_request GET "$base" /api/reports/missing-report "$body")
  [ "$code" = 404 ] || fail "/api/reports/missing-report returned HTTP $code instead of 404: $(cat "$body")"
  jq -e '.error == "report_not_found"' "$body" >/dev/null \
    || fail "missing report body was not clear JSON: $(cat "$body")"

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

  pass "dashboard server serves HTML, cached snapshot, reports, health, 405, and 404"
}

test_dashboard_runtime_keeps_top_pipeline_rail() {
  local dir base code body snapshot
  dir=$(make_case runtime-top-rail)
  base=$(start_server "$dir")

  body="$dir/home.html"
  code=$(http_request GET "$base" / "$body")
  [ "$code" = 200 ] || fail "/ returned HTTP $code"

  snapshot="$dir/snapshot.json"
  code=$(http_request GET "$base" /api/snapshot "$snapshot")
  [ "$code" = 200 ] || fail "/api/snapshot returned HTTP $code: $(cat "$snapshot")"

  assert_dashboard_render_contract "$body" "$snapshot"
  pass "dashboard runtime keeps restored pipeline and station rendering"
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
test_dashboard_runtime_keeps_top_pipeline_rail
test_initial_no_cache_snapshot_waits_for_boot_probe
test_warm_cache_snapshot_does_not_launch_probe
test_due_refresh_runs_in_background_while_serving_cache
test_probe_failure_with_no_cache_returns_503
test_probe_failure_with_last_good_returns_cached_snapshot
test_concurrent_snapshot_requests_share_one_probe_run
