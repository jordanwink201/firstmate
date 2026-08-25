#!/usr/bin/env bash
# Deterministic browser QA wrapper for firstmate tasks.
# Attaches to an authenticated Chrome remote-debugging endpoint, proves the
# exact active URL/title through chrome-devtools-axi, and writes evidence.
# Usage:
#   fm-browser-qa.sh --url <exact-url> --out <dir> [--browser-url <url>] [--session <name>] [--start-if-needed]
set -eu

# Failure bookkeeping. STAGE names the step in progress so an abort can say where
# it died; BLOCK_REASON is set by blocked() and read by the exit trap. Both are
# initialised here because blocked() can fire during the dependency checks below.
STAGE=init
BLOCK_REASON=
LEDGER_FILE="${FM_BROWSER_QA_LEDGER:-$HOME/.local/share/fm-browser-qa/runs.jsonl}"

usage() {
  cat >&2 <<'EOF'
usage: bin/fm-browser-qa.sh --url <exact-url> --out <dir> [--browser-url <url>] [--session <name>] [--start-if-needed]
EOF
}

die_usage() {
  echo "error: $1" >&2
  usage
  exit 2
}

# chrome-devtools-axi reports some failures on stdout rather than stderr, so a
# message built from the .err file alone comes out empty. Join whatever either
# stream produced, in the order given.
stream_detail() {
  local detail='' f chunk
  for f in "$@"; do
    [ -s "$f" ] || continue
    chunk=$(tr '\n' ' ' < "$f" | cut -c1-400)
    detail="$detail${detail:+ | }$chunk"
  done
  [ -n "$detail" ] || detail="no output on stdout or stderr"
  printf '%s' "$detail"
}

# The evidence directory is the only thing that outlives the run, so record the
# failure there. Without this a partial directory is the sole clue and the stage
# has to be inferred from which artifacts are missing.
write_failure_marker() {
  [ -n "${OUT_DIR:-}" ] && [ -d "${OUT_DIR:-}" ] || return 0
  {
    echo "# Browser QA FAILED"
    echo
    echo "- Stage: $STAGE"
    echo "- Reason: $BLOCK_REASON"
    echo "- Exact URL: ${TARGET_URL:-<unset>}"
    echo "- Browser endpoint: ${BROWSER_URL:-<unset>}"
    echo "- Logical evidence session: ${LOGICAL_SESSION_NAME:-<unset>}"
    echo "- AXI bridge session: ${AXI_SESSION_NAME:-<unset>}"
    echo "- Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } > "$OUT_DIR/FAILED.md" 2>/dev/null || true
}

blocked() {
  BLOCK_REASON=$1
  echo "blocked: $1" >&2
  write_failure_marker
  exit 1
}

sanitize_token() {
  local raw=$1 token
  token=$(printf '%s' "$raw" | LC_ALL=C tr -c '[:alnum:]_.-' '-' | sed 's/^-*//; s/-*$//')
  [ -n "$token" ] || token=default
  printf '%s\n' "$token"
}

TARGET_URL=
OUT_DIR=
BROWSER_URL=http://127.0.0.1:9222
SESSION_INPUT=
START_IF_NEEDED=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --url)
      [ "$#" -ge 2 ] || die_usage "--url requires a value"
      TARGET_URL=$2
      shift 2
      ;;
    --out)
      [ "$#" -ge 2 ] || die_usage "--out requires a value"
      OUT_DIR=$2
      shift 2
      ;;
    --browser-url)
      [ "$#" -ge 2 ] || die_usage "--browser-url requires a value"
      BROWSER_URL=$2
      shift 2
      ;;
    --session)
      [ "$#" -ge 2 ] || die_usage "--session requires a value"
      SESSION_INPUT=$2
      shift 2
      ;;
    --start-if-needed)
      START_IF_NEEDED=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die_usage "unknown argument: $1"
      ;;
  esac
done

[ -n "$TARGET_URL" ] || die_usage "--url is required"
[ -n "$OUT_DIR" ] || die_usage "--out is required"

command -v chrome-devtools-axi >/dev/null 2>&1 || blocked "chrome-devtools-axi is not installed or not on PATH"
command -v curl >/dev/null 2>&1 || blocked "curl is not installed or not on PATH"
command -v node >/dev/null 2>&1 || blocked "node is not installed or not on PATH"

BROWSER_URL=${BROWSER_URL%/}
mkdir -p "$OUT_DIR" || blocked "could not create evidence directory: $OUT_DIR"

if [ -n "$SESSION_INPUT" ]; then
  LOGICAL_SESSION_NAME="fmqa-$(sanitize_token "$SESSION_INPUT")"
else
  LOGICAL_SESSION_NAME="fmqa-$(sanitize_token "$(basename "$OUT_DIR")")"
fi

TMP_DIR=
AXI_SESSION_NAME=

axi() (
  unset CHROME_DEVTOOLS_AXI_PORT
  export CHROME_DEVTOOLS_AXI_SESSION="$AXI_SESSION_NAME"
  export CHROME_DEVTOOLS_AXI_BROWSER_URL="$BROWSER_URL"
  chrome-devtools-axi "$@"
)

# One JSON line per run, so failure rates and stage distribution are answerable
# after the fact instead of only from whatever terminal saw the run.
append_ledger() {
  local status=$1 dir
  [ -n "${LEDGER_FILE:-}" ] || return 0
  command -v node >/dev/null 2>&1 || return 0
  dir=$(dirname "$LEDGER_FILE")
  mkdir -p "$dir" >/dev/null 2>&1 || return 0
  node - "$status" "$STAGE" "$BLOCK_REASON" "${TARGET_URL:-}" "${OUT_DIR:-}" \
    "${LOGICAL_SESSION_NAME:-}" "${AXI_SESSION_NAME:-}" "$LEDGER_FILE" <<'NODE' >/dev/null 2>&1 || true
const fs = require('fs');
const [status, stage, reason, url, outDir, session, axiSession, ledger] = process.argv.slice(2);
fs.appendFileSync(ledger, JSON.stringify({
  ts: new Date().toISOString(),
  status: Number(status),
  stage,
  reason: reason || null,
  url: url || null,
  out_dir: outDir || null,
  session: session || null,
  axi_session: axiSession || null,
}) + '\n');
NODE
}

cleanup() {
  local status=$?
  trap - EXIT
  trap '' HUP INT TERM
  append_ledger "$status"
  if [ -n "$AXI_SESSION_NAME" ]; then
    axi stop >/dev/null 2>&1 || true
  fi
  if [ -n "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR" >/dev/null 2>&1 || true
  fi
  exit "$status"
}

handle_signal() {
  local status=$1
  trap - HUP INT TERM
  exit "$status"
}

trap cleanup EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-browser-qa.XXXXXX")
AXI_SESSION_NAME="fmqa-$(sanitize_token "$(basename "$TMP_DIR")")"
WARNINGS_FILE="$TMP_DIR/warnings.txt"
: > "$WARNINGS_FILE"
STAGE=browser-check

append_warning() {
  printf '%s\n' "- $1" >> "$WARNINGS_FILE"
}

browser_json_url() {
  printf '%s/json/version\n' "$BROWSER_URL"
}

browser_reachable() {
  curl -fsS --max-time "${FM_BROWSER_QA_CURL_TIMEOUT:-2}" "$(browser_json_url)" >/dev/null 2>&1
}

browser_debugging_port() {
  case "$BROWSER_URL" in
    http://127.0.0.1:*|http://localhost:*)
      printf '%s\n' "$BROWSER_URL" | sed -n 's#^http://[^:/]*:\([0-9][0-9]*\).*$#\1#p'
      ;;
    *)
      return 1
      ;;
  esac
}

browser_profile_dir() {
  if [ -n "${FM_BROWSER_QA_PROFILE_DIR:-}" ]; then
    printf '%s\n' "$FM_BROWSER_QA_PROFILE_DIR"
    return 0
  fi
  [ -n "${HOME:-}" ] || blocked "HOME is not set; cannot choose a persistent Chrome QA profile"
  printf '%s\n' "$HOME/.local/share/fm-browser-qa/chrome-profile"
}

focus_browser_window() {
  command -v osascript >/dev/null 2>&1 || return 0
  osascript -e 'tell application "Google Chrome" to activate' >/dev/null 2>&1 || true
}

extract_user_data_dir() {
  awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^--user-data-dir=/) {
          sub(/^--user-data-dir=/, "", $i)
          print $i
          exit
        }
        if ($i == "--user-data-dir" && i < NF) {
          print $(i + 1)
          exit
        }
      }
    }
  '
}

is_temporary_profile_dir() {
  case "$1" in
    /tmp/*|/private/tmp/*|/var/folders/*/T/*|*/fm-visible-*|*/fm-browser-qa.*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

verify_existing_browser_profile() {
  local port pids pid command profile expected_profile
  [ "$START_IF_NEEDED" -eq 1 ] || return 0
  port=$(browser_debugging_port) || return 0
  [ -n "$port" ] || return 0
  command -v lsof >/dev/null 2>&1 || return 0
  command -v ps >/dev/null 2>&1 || return 0

  pids=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true)
  [ -n "$pids" ] || return 0
  expected_profile=$(browser_profile_dir)

  for pid in $pids; do
    command=$(ps -p "$pid" -o command= 2>/dev/null || true)
    [ -n "$command" ] || continue
    profile=$(printf '%s\n' "$command" | extract_user_data_dir)
    [ -n "$profile" ] || continue
    if is_temporary_profile_dir "$profile"; then
      blocked "Chrome remote-debugging endpoint at $BROWSER_URL is already using a temporary profile ($profile, pid $pid). Close that Chrome window or run: kill $pid; then rerun with --start-if-needed so the persistent QA profile starts at $expected_profile"
    fi
    if [ "$profile" != "$expected_profile" ]; then
      append_warning "Chrome remote-debugging endpoint uses profile $profile instead of $expected_profile; assuming it is the intended authenticated profile."
    fi
  done
}

start_browser() {
  local port profile_dir
  port=$(browser_debugging_port) \
    || blocked "--start-if-needed only knows how to start a local http://127.0.0.1:<port> or http://localhost:<port> Chrome"
  [ -n "$port" ] || blocked "could not parse Chrome remote-debugging port from $BROWSER_URL"
  command -v open >/dev/null 2>&1 || blocked "--start-if-needed requires macOS open(1); start Chrome with --remote-debugging-port=$port and retry"
  profile_dir=$(browser_profile_dir)
  mkdir -p "$profile_dir" || blocked "could not create Chrome QA profile directory: $profile_dir"
  open -na "Google Chrome" --args \
    "--remote-debugging-port=$port" \
    "--user-data-dir=$profile_dir" \
    "--new-window" \
    "$TARGET_URL" >/dev/null 2>&1 \
    || blocked "could not start Google Chrome with --remote-debugging-port=$port"
  focus_browser_window
}

wait_for_browser() {
  local tries=${FM_BROWSER_QA_START_TRIES:-20}
  while [ "$tries" -gt 0 ]; do
    browser_reachable && return 0
    sleep "${FM_BROWSER_QA_START_SLEEP:-0.5}"
    tries=$((tries - 1))
  done
  return 1
}

if browser_reachable; then
  verify_existing_browser_profile
else
  if [ "$START_IF_NEEDED" -eq 1 ]; then
    start_browser
    wait_for_browser || blocked "Chrome remote-debugging endpoint did not become reachable at $BROWSER_URL"
  else
    blocked "Chrome remote-debugging endpoint is not reachable at $BROWSER_URL; start the authenticated browser or pass --start-if-needed"
  fi
fi

json_field() {
  node - "$1" "$2" <<'NODE'
const fs = require('fs');
const [file, field] = process.argv.slice(2);
const obj = JSON.parse(fs.readFileSync(file, 'utf8'));
process.stdout.write(String(obj[field] ?? ''));
NODE
}

normalize_url() {
  node - "$1" <<'NODE'
const [raw] = process.argv.slice(2);
try {
  process.stdout.write(new URL(raw).href);
} catch {
  process.stdout.write(raw);
}
NODE
}

parse_eval_identity() {
  node - "$1" "$2" <<'NODE'
const fs = require('fs');
const [input, output] = process.argv.slice(2);
const text = fs.readFileSync(input, 'utf8');
const match = text.match(/^result:\s*(.+)$/m);
if (!match) {
  console.error('missing result line');
  process.exit(1);
}
let value;
try {
  value = JSON.parse(match[1].trim());
} catch (error) {
  console.error(`invalid eval result JSON: ${error.message}`);
  process.exit(1);
}
if (typeof value === 'string') {
  try {
    value = JSON.parse(value);
  } catch {
    // Leave value as-is; the validation below will reject non-object strings.
  }
}
if (!value || typeof value !== 'object' || typeof value.href !== 'string') {
  console.error('eval result did not contain {href,title}');
  process.exit(1);
}
fs.writeFileSync(output, JSON.stringify({
  href: value.href,
  title: typeof value.title === 'string' ? value.title : ''
}, null, 2) + '\n');
NODE
}

write_identity() {
  node - "$1" "$2" "$BROWSER_URL" "$LOGICAL_SESSION_NAME" "$AXI_SESSION_NAME" "$TARGET_URL" "$OUT_DIR/identity.json" <<'NODE'
const fs = require('fs');
const [identityFile, pageId, browserUrl, logicalSessionName, axiSessionName, requestedUrl, output] = process.argv.slice(2);
const identity = JSON.parse(fs.readFileSync(identityFile, 'utf8'));
fs.writeFileSync(output, JSON.stringify({
  page_id: pageId,
  requested_url: requestedUrl,
  active_url: identity.href,
  title: identity.title,
  browser_url: browserUrl,
  session: logicalSessionName,
  axi_session: axiSessionName,
  captured_at: new Date().toISOString()
}, null, 2) + '\n');
NODE
}

is_auth_blocked() {
  node - "$1" "$2" <<'NODE'
const [href, title] = process.argv.slice(2);
const h = String(href || '').toLowerCase();
const t = String(title || '').toLowerCase();
if (h.includes('/cdn-cgi/access/login') || t.includes('cloudflare access') || /\bsign[ -]?in\b/.test(t)) {
  process.exit(0);
}
process.exit(1);
NODE
}

auth_blocked() {
  focus_browser_window
  blocked "authenticated browser session expired; sign in to the foregrounded QA Chrome window, then rerun"
}

count_lines() {
  wc -l < "$1" | tr -d '[:space:]'
}

safe_page_id() {
  printf '%s' "$1" | LC_ALL=C tr -c '[:alnum:]_.-' '_'
}

probe_page() {
  local page_id=$1 out_json=$2 safe_id err_file
  safe_id=$(safe_page_id "$page_id")
  err_file="$TMP_DIR/probe-$safe_id.err"
  axi selectpage "$page_id" > "$TMP_DIR/select-$safe_id.out" 2> "$err_file" || return 1
  axi eval '({href: location.href, title: document.title})' > "$TMP_DIR/eval-$safe_id.out" 2> "$err_file" || return 1
  parse_eval_identity "$TMP_DIR/eval-$safe_id.out" "$out_json" 2> "$err_file" || return 1
}

probe_error() {
  local safe_id
  safe_id=$(safe_page_id "$1")
  stream_detail "$TMP_DIR/probe-$safe_id.err" "$TMP_DIR/select-$safe_id.out" \
    "$TMP_DIR/eval-$safe_id.out"
}

list_page_ids() {
  local label=$1
  if ! axi pages > "$TMP_DIR/pages-$label.txt" 2> "$TMP_DIR/pages-$label.err"; then
    blocked "could not enumerate browser pages: $(stream_detail "$TMP_DIR/pages-$label.err" "$TMP_DIR/pages-$label.txt")"
  fi
  awk '/^[[:space:]]*[A-Za-z0-9_.-]+,/ { gsub(/^[[:space:]]*/, "", $0); sub(/,.*/, "", $0); print }' "$TMP_DIR/pages-$label.txt"
}

scan_pages() {
  local scan_dir=$1 ids=$2 mode=$3 page_id identity_json href
  mkdir -p "$scan_dir"
  : > "$scan_dir/matches.tsv"
  for page_id in $ids; do
    identity_json="$scan_dir/page-$(safe_page_id "$page_id").json"
    if ! probe_page "$page_id" "$identity_json"; then
      if [ "$mode" = strict ]; then
        blocked "could not prove browser page $page_id identity: $(probe_error "$page_id")"
      fi
      echo "warning: skipped browser page $page_id: could not probe it" >&2
      append_warning "skipped browser page $page_id: could not probe it"
      continue
    fi
    href=$(json_field "$identity_json" href)
    if [ "$href" = "$NORM_TARGET_URL" ]; then
      printf '%s\t%s\n' "$page_id" "$identity_json" >> "$scan_dir/matches.tsv"
    fi
  done
}

open_target_page() {
  if ! axi newpage "$TARGET_URL" > "$TMP_DIR/newpage.out" 2> "$TMP_DIR/newpage.err"; then
    blocked "could not open exact QA URL in authenticated browser: $(stream_detail "$TMP_DIR/newpage.err" "$TMP_DIR/newpage.out")"
  fi
  sleep "${FM_BROWSER_QA_OPEN_SETTLE:-1}"
}

NORM_TARGET_URL=$(normalize_url "$TARGET_URL")

STAGE=page-scan
SCAN_DIR="$TMP_DIR/scan-initial"
INITIAL_IDS=$(list_page_ids initial)
scan_pages "$SCAN_DIR" "$INITIAL_IDS" tolerate
MATCHES="$SCAN_DIR/matches.tsv"
MATCH_COUNT=$(count_lines "$MATCHES")

if [ "$MATCH_COUNT" -eq 0 ]; then
  open_target_page
  POST_IDS=$(list_page_ids after-open)
  NEW_IDS=
  for page_id in $POST_IDS; do
    known=0
    for known_id in $INITIAL_IDS; do
      if [ "$page_id" = "$known_id" ]; then
        known=1
        break
      fi
    done
    if [ "$known" -eq 0 ]; then
      NEW_IDS="$NEW_IDS $page_id"
    fi
  done
  SCAN_DIR="$TMP_DIR/scan-after-open"
  scan_pages "$SCAN_DIR" "$NEW_IDS" strict
  MATCHES="$SCAN_DIR/matches.tsv"
  MATCH_COUNT=$(count_lines "$MATCHES")
  if [ "$MATCH_COUNT" -eq 0 ]; then
    for page_id in $NEW_IDS; do
      identity_json="$SCAN_DIR/page-$(safe_page_id "$page_id").json"
      [ -f "$identity_json" ] || continue
      if is_auth_blocked "$(json_field "$identity_json" href)" "$(json_field "$identity_json" title)"; then
        auth_blocked
      fi
    done
    blocked "exact QA URL is not open after navigation: $TARGET_URL"
  fi
fi

if [ "$MATCH_COUNT" -gt 1 ]; then
  blocked "multiple tabs match the exact QA URL; close duplicates and retry: $TARGET_URL"
fi

STAGE=identity
MATCH_LINE=$(sed -n '1p' "$MATCHES")
PAGE_ID=$(printf '%s\n' "$MATCH_LINE" | cut -f1)
FINAL_IDENTITY="$TMP_DIR/final-identity.json"
if ! probe_page "$PAGE_ID" "$FINAL_IDENTITY"; then
  blocked "could not prove browser page $PAGE_ID identity: $(probe_error "$PAGE_ID")"
fi
FINAL_HREF=$(json_field "$FINAL_IDENTITY" href)
FINAL_TITLE=$(json_field "$FINAL_IDENTITY" title)

if is_auth_blocked "$FINAL_HREF" "$FINAL_TITLE"; then
  auth_blocked
fi

if [ "$FINAL_HREF" != "$NORM_TARGET_URL" ]; then
  blocked "selected browser tab URL mismatch: expected $NORM_TARGET_URL got $FINAL_HREF"
fi

write_identity "$FINAL_IDENTITY" "$PAGE_ID"

STAGE=snapshot
if ! axi snapshot > "$OUT_DIR/snapshot.txt" 2> "$TMP_DIR/snapshot.err"; then
  blocked "snapshot evidence failed: $(stream_detail "$TMP_DIR/snapshot.err" "$OUT_DIR/snapshot.txt")"
fi
[ -s "$OUT_DIR/snapshot.txt" ] || blocked "snapshot evidence was empty: $(stream_detail "$TMP_DIR/snapshot.err")"

STAGE=screenshot
if ! axi screenshot "$OUT_DIR/screenshot.png" > "$TMP_DIR/screenshot.out" 2> "$TMP_DIR/screenshot.err"; then
  blocked "screenshot evidence failed: $(stream_detail "$TMP_DIR/screenshot.err" "$TMP_DIR/screenshot.out")"
fi
# axi can exit 0 without producing the file, and it echoes the path it resolved,
# so surface both streams here rather than reporting a bare "was empty".
[ -s "$OUT_DIR/screenshot.png" ] || blocked "screenshot evidence was empty: $(stream_detail "$TMP_DIR/screenshot.out" "$TMP_DIR/screenshot.err")"

STAGE=console
if ! axi console > "$OUT_DIR/console.txt" 2> "$TMP_DIR/console.err"; then
  {
    echo "warning: console capture failed"
    cat "$TMP_DIR/console.err"
  } > "$OUT_DIR/console.txt"
  append_warning "console capture failed; see console.txt"
fi

STAGE=network
if ! axi network > "$OUT_DIR/network.txt" 2> "$TMP_DIR/network.err"; then
  {
    echo "warning: network capture failed"
    cat "$TMP_DIR/network.err"
  } > "$OUT_DIR/network.txt"
  append_warning "network capture failed; see network.txt"
fi

STAGE=report
# Evidence directories get reused across runs, so a marker left by an earlier
# failed run would contradict the report about to be written.
rm -f "$OUT_DIR/FAILED.md"

{
  echo "# Browser QA Report"
  echo
  echo "- Exact URL: $TARGET_URL"
  echo "- Active URL: $FINAL_HREF"
  echo "- Title: $FINAL_TITLE"
  echo "- Page ID: $PAGE_ID"
  echo "- Browser endpoint: $BROWSER_URL"
  echo "- Logical evidence session: $LOGICAL_SESSION_NAME"
  echo "- AXI bridge session: $AXI_SESSION_NAME"
  echo
  echo "## Evidence"
  echo
  echo "- identity.json"
  echo "- snapshot.txt"
  echo "- screenshot.png"
  echo "- console.txt"
  echo "- network.txt"
  if [ -s "$WARNINGS_FILE" ]; then
    echo
    echo "## Warnings"
    echo
    cat "$WARNINGS_FILE"
  fi
} > "$OUT_DIR/report.md"

STAGE="done"
echo "ok: browser QA evidence written to $OUT_DIR"
