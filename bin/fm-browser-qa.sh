#!/usr/bin/env bash
# Deterministic browser QA wrapper for firstmate tasks.
# Attaches to an already-authenticated Chrome remote-debugging endpoint, proves
# the exact active URL/title through chrome-devtools-axi, and writes evidence.
# Usage:
#   fm-browser-qa.sh --url <exact-url> --out <dir> [--browser-url <url>] [--session <name>] [--start-if-needed]
set -eu

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

blocked() {
  echo "blocked: $1" >&2
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
  SESSION_NAME="fmqa-$(sanitize_token "$SESSION_INPUT")"
else
  SESSION_NAME="fmqa-$(sanitize_token "$(basename "$OUT_DIR")")"
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-browser-qa.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT
WARNINGS_FILE="$TMP_DIR/warnings.txt"
: > "$WARNINGS_FILE"

append_warning() {
  printf '%s\n' "- $1" >> "$WARNINGS_FILE"
}

browser_json_url() {
  printf '%s/json/version\n' "$BROWSER_URL"
}

browser_reachable() {
  curl -fsS --max-time "${FM_BROWSER_QA_CURL_TIMEOUT:-2}" "$(browser_json_url)" >/dev/null 2>&1
}

start_browser() {
  local port
  case "$BROWSER_URL" in
    http://127.0.0.1:*|http://localhost:*)
      port=$(printf '%s\n' "$BROWSER_URL" | sed -n 's#^http://[^:/]*:\([0-9][0-9]*\).*$#\1#p')
      ;;
    *)
      blocked "--start-if-needed only knows how to start a local http://127.0.0.1:<port> or http://localhost:<port> Chrome"
      ;;
  esac
  [ -n "$port" ] || blocked "could not parse Chrome remote-debugging port from $BROWSER_URL"
  command -v open >/dev/null 2>&1 || blocked "--start-if-needed requires macOS open(1); start Chrome with --remote-debugging-port=$port and retry"
  open -na "Google Chrome" --args "--remote-debugging-port=$port" >/dev/null 2>&1 \
    || blocked "could not start Google Chrome with --remote-debugging-port=$port"
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

if ! browser_reachable; then
  if [ "$START_IF_NEEDED" -eq 1 ]; then
    start_browser
    wait_for_browser || blocked "Chrome remote-debugging endpoint did not become reachable at $BROWSER_URL"
  else
    blocked "Chrome remote-debugging endpoint is not reachable at $BROWSER_URL; start the authenticated browser or pass --start-if-needed"
  fi
fi

axi() (
  unset CHROME_DEVTOOLS_AXI_PORT
  export CHROME_DEVTOOLS_AXI_SESSION="$SESSION_NAME"
  export CHROME_DEVTOOLS_AXI_BROWSER_URL="$BROWSER_URL"
  chrome-devtools-axi "$@"
)

json_field() {
  node - "$1" "$2" <<'NODE'
const fs = require('fs');
const [file, field] = process.argv.slice(2);
const obj = JSON.parse(fs.readFileSync(file, 'utf8'));
process.stdout.write(String(obj[field] ?? ''));
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
  node - "$1" "$2" "$BROWSER_URL" "$SESSION_NAME" "$TARGET_URL" "$OUT_DIR/identity.json" <<'NODE'
const fs = require('fs');
const [identityFile, pageId, browserUrl, sessionName, requestedUrl, output] = process.argv.slice(2);
const identity = JSON.parse(fs.readFileSync(identityFile, 'utf8'));
fs.writeFileSync(output, JSON.stringify({
  page_id: pageId,
  requested_url: requestedUrl,
  active_url: identity.href,
  title: identity.title,
  browser_url: browserUrl,
  session: sessionName,
  captured_at: new Date().toISOString()
}, null, 2) + '\n');
NODE
}

is_auth_blocked() {
  node - "$1" "$2" <<'NODE'
const [href, title] = process.argv.slice(2);
const h = String(href || '').toLowerCase();
const t = String(title || '').toLowerCase();
if (h.includes('/cdn-cgi/access/login') || t.includes('cloudflare access') || t.includes('sign in')) {
  process.exit(0);
}
process.exit(1);
NODE
}

count_lines() {
  wc -l < "$1" | tr -d '[:space:]'
}

safe_page_id() {
  printf '%s' "$1" | LC_ALL=C tr -c '[:alnum:]_.-' '_'
}

select_and_probe() {
  local page_id=$1 out_json=$2 safe_id select_out select_err eval_out eval_err
  safe_id=$(safe_page_id "$page_id")
  select_out="$TMP_DIR/select-$safe_id.out"
  select_err="$TMP_DIR/select-$safe_id.err"
  eval_out="$TMP_DIR/eval-$safe_id.out"
  eval_err="$TMP_DIR/eval-$safe_id.err"

  if ! axi selectpage "$page_id" > "$select_out" 2> "$select_err"; then
    blocked "could not select browser page $page_id: $(cat "$select_err")"
  fi
  if ! axi eval 'JSON.stringify({href: location.href, title: document.title})' > "$eval_out" 2> "$eval_err"; then
    blocked "could not prove browser page $page_id identity: $(cat "$eval_err")"
  fi
  if ! parse_eval_identity "$eval_out" "$out_json" 2> "$TMP_DIR/parse-$safe_id.err"; then
    blocked "could not parse browser page $page_id identity: $(cat "$TMP_DIR/parse-$safe_id.err")"
  fi
}

scan_pages() {
  local scan_dir=$1 ids page_id identity_json href title
  mkdir -p "$scan_dir"
  : > "$scan_dir/matches.tsv"
  : > "$scan_dir/auth.tsv"
  if ! axi pages > "$scan_dir/pages.txt" 2> "$scan_dir/pages.err"; then
    blocked "could not enumerate browser pages: $(cat "$scan_dir/pages.err")"
  fi
  ids=$(awk '/^[[:space:]]*[A-Za-z0-9_.-]+,/ { gsub(/^[[:space:]]*/, "", $0); sub(/,.*/, "", $0); print }' "$scan_dir/pages.txt")
  for page_id in $ids; do
    identity_json="$scan_dir/page-$(safe_page_id "$page_id").json"
    select_and_probe "$page_id" "$identity_json"
    href=$(json_field "$identity_json" href)
    title=$(json_field "$identity_json" title)
    if is_auth_blocked "$href" "$title"; then
      printf '%s\t%s\t%s\n' "$page_id" "$href" "$title" >> "$scan_dir/auth.tsv"
    fi
    if [ "$href" = "$TARGET_URL" ]; then
      printf '%s\t%s\n' "$page_id" "$identity_json" >> "$scan_dir/matches.tsv"
    fi
  done
}

open_target_page() {
  if ! axi newpage "$TARGET_URL" > "$TMP_DIR/newpage.out" 2> "$TMP_DIR/newpage.err"; then
    blocked "could not open exact QA URL in authenticated browser: $(cat "$TMP_DIR/newpage.err")"
  fi
  sleep "${FM_BROWSER_QA_OPEN_SETTLE:-1}"
}

SCAN_DIR="$TMP_DIR/scan-initial"
scan_pages "$SCAN_DIR"
MATCHES="$SCAN_DIR/matches.tsv"
MATCH_COUNT=$(count_lines "$MATCHES")

if [ "$MATCH_COUNT" -eq 0 ]; then
  open_target_page
  SCAN_DIR="$TMP_DIR/scan-after-open"
  scan_pages "$SCAN_DIR"
  MATCHES="$SCAN_DIR/matches.tsv"
  MATCH_COUNT=$(count_lines "$MATCHES")
fi

if [ "$MATCH_COUNT" -eq 0 ]; then
  if [ -s "$SCAN_DIR/auth.tsv" ]; then
    blocked "authenticated browser session expired"
  fi
  blocked "exact QA URL is not open after navigation: $TARGET_URL"
fi

if [ "$MATCH_COUNT" -gt 1 ]; then
  blocked "multiple tabs match the exact QA URL; close duplicates and retry: $TARGET_URL"
fi

MATCH_LINE=$(sed -n '1p' "$MATCHES")
PAGE_ID=$(printf '%s\n' "$MATCH_LINE" | cut -f1)
FINAL_IDENTITY="$TMP_DIR/final-identity.json"
select_and_probe "$PAGE_ID" "$FINAL_IDENTITY"
FINAL_HREF=$(json_field "$FINAL_IDENTITY" href)
FINAL_TITLE=$(json_field "$FINAL_IDENTITY" title)

if is_auth_blocked "$FINAL_HREF" "$FINAL_TITLE"; then
  blocked "authenticated browser session expired"
fi

if [ "$FINAL_HREF" != "$TARGET_URL" ]; then
  blocked "selected browser tab URL mismatch: expected $TARGET_URL got $FINAL_HREF"
fi

write_identity "$FINAL_IDENTITY" "$PAGE_ID"

if ! axi snapshot > "$OUT_DIR/snapshot.txt" 2> "$TMP_DIR/snapshot.err"; then
  blocked "snapshot evidence failed: $(cat "$TMP_DIR/snapshot.err")"
fi
[ -s "$OUT_DIR/snapshot.txt" ] || blocked "snapshot evidence was empty"

if ! axi screenshot "$OUT_DIR/screenshot.png" > "$TMP_DIR/screenshot.out" 2> "$TMP_DIR/screenshot.err"; then
  blocked "screenshot evidence failed: $(cat "$TMP_DIR/screenshot.err")"
fi
[ -s "$OUT_DIR/screenshot.png" ] || blocked "screenshot evidence was empty"

if ! axi console > "$OUT_DIR/console.txt" 2> "$TMP_DIR/console.err"; then
  {
    echo "warning: console capture failed"
    cat "$TMP_DIR/console.err"
  } > "$OUT_DIR/console.txt"
  append_warning "console capture failed; see console.txt"
fi

if ! axi network > "$OUT_DIR/network.txt" 2> "$TMP_DIR/network.err"; then
  {
    echo "warning: network capture failed"
    cat "$TMP_DIR/network.err"
  } > "$OUT_DIR/network.txt"
  append_warning "network capture failed; see network.txt"
fi

{
  echo "# Browser QA Report"
  echo
  echo "- Exact URL: $TARGET_URL"
  echo "- Active URL: $FINAL_HREF"
  echo "- Title: $FINAL_TITLE"
  echo "- Page ID: $PAGE_ID"
  echo "- Browser endpoint: $BROWSER_URL"
  echo "- AXI session: $SESSION_NAME"
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

echo "ok: browser QA evidence written to $OUT_DIR"
