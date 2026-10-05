#!/usr/bin/env bash
# Deterministic browser QA wrapper for firstmate tasks.
# Attaches to an authenticated Chrome remote-debugging endpoint, proves the
# exact active URL/title through chrome-devtools-axi, and writes evidence.
# Compatibility: when CHROME_DEVTOOLS_AXI_MCP_PATH is unset, validates and reuses
# exact chrome-devtools-mcp 1.7.0 from $HOME/.local/share/fm-browser-qa, installing
# with npm only when needed and serializing concurrent staged publication.
# An explicit CHROME_DEVTOOLS_AXI_MCP_PATH bypasses the cache without modifying
# the global chrome-devtools-axi installation.
# Installing or repairing the compatibility cache requires npm and perl.
# FM_BROWSER_QA_CURL_TIMEOUT bounds target reachability, browser reachability,
# and full-title inventory requests in seconds (default: 2).
# Finite curl-supported numeric values >= 0.001 are honored; other values use 2.
# Diagnostics: blocked runs leave FAILED.md after the evidence directory exists,
# and every exit best-effort appends JSONL to FM_BROWSER_QA_LEDGER or the default
# $HOME/.local/share/fm-browser-qa/runs.jsonl when either path is available.
# Auth: protected HTTP(S) teacher-route QA requires a fresh account/self response
# and a visible usable portal shell after exact page identity verification.
# Protected top-level routes (optionally prefixed en/en-gb/es/br) are dashboard, account,
# settings, orders, resources, reports, schools, school, teachers, classes,
# pending-joins, students, live-activity, assignments, and curriculum. Public,
# unknown, nonteacher, non-HTTP(S), and attachment targets retain page inspection.
# Proof requires an HTTPS page and resource entries with the exact pathname
# /teachers/account/self or /teachers/globals to establish the HTTPS API host:
# teachers -> api, teachers-dev -> api-dev, teachers-<slug> -> teachers-api-<slug>,
# all under typing.com; every matching API URL must have no userinfo or nondefault
# port. Unsupported/missing or conflicting configuration blocks before token use.
# localStorage teacher_jwt_token stays in page context for the fresh five-second
# GET /teachers/account/self, with cache no-store, credentials include, redirects
# rejected, JSON Accept/Content-Type, x-app-site typing, and bearer authorization.
# x-language uses tc:language then the first URL segment if listed in
# FTWGLOBALS_BE_API.languages, otherwise FTWGLOBALS_BE_API.defaultLanguage or en.
# HTTP200 JSON data must have a positive safe-integer teacher_id, role teacher,
# school_admin, district_admin, or billing_admin, and integer active=1.
# Integer active=0 is authenticated-but-inactive (unusable), not a login trigger.
# The mounted shell requires visible #root-layout, #root-layout-main, and
# #root-layout header, with no shared.roles.undefined/null in its rendered text
# and no visible modal h2 with rendered text exactly Logged Out, Desconectado, or
# app.logged_out_notice_title (case-insensitive, whitespace-normalized).
# These text checks use innerText only, even when empty, without a textContent
# fallback that would include hidden descendants. Empty accounts, blank names, and
# unrelated dialogs remain valid; no populated classes/students are required.
# teacher-session.json publishes only allowlisted proof metadata, never tokens or
# raw account data. Unknown, timeout, and readiness failures remain unverified.
# At most one teaching-verify login attempt follows a same-host /login or /login/*
# landing, HTTP401 self response, or missing token on a protected target
# (FM_BROWSER_QA_LOGIN_HELPER overrides it); then resolved-route navigation,
# exact page identity, and fresh session proof must all pass again.
# Helper success does not prove navigation success: a remaining Sign In page
# or a different final URL blocks verification without diagnosing expired
# credentials. Cloudflare Access retains its human-sign-in authentication blocker.
# Target URLs: HTTP(S) teachers[.-]*.typing.com roots, with or without a trailing
# slash and without any query or fragment delimiter, select the same origin's
# /dashboard. Explicit routes, localized paths, queries, fragments, and other
# hosts keep their target. All targets use browser-equivalent URL normalization.
# Resolution precedes browser startup, tab selection, and navigation; initial
# and post-login navigation verify the same resolved target.
# Attachment instead verifies the receipt's saved active_url and title without
# root resolution, including older receipts that have no resolved_url field.
# Evidence: identity.json keeps requested_url (original input), resolved_url
# (canonical target), and active_url (observed page, which must exactly match the
# resolved target for success). A failure identity records the observed page,
# not completion; check the run outcome and FAILED.md before accepting evidence.
# Current URL-QA identities mark teacher_session_required; required success also
# has schema-1 teacher-session.json with matching page_id, requested/resolved/active
# URLs, a checked_at timestamp, status authenticated/reason verified, HTTP200 and true
# principal_valid, role_valid, active, shell_ready, plus the trusted api_origin.
# The run ledger keeps url plus resolved_url. Reports and failure diagnostics
# distinguish requested, resolved, and observed URLs and announce root resolution.
# Starting or failing URL QA removes a wrapper-owned report.md from a prior run.
# Usage:
#   fm-browser-qa.sh --url <exact-url> --out <dir> [--browser-url <url>] [--session <name>] [--start-if-needed]
#   fm-browser-qa.sh --select-identity <identity.json> --axi-session <session> [--out <dir>]
set -eu
export LC_ALL=C

# Failure bookkeeping. STAGE names the step in progress so an abort can say where
# it died; BLOCK_REASON is set by blocked() and read by the exit trap. Both are
# initialised here because blocked() can fire during the dependency checks below.
STAGE=init
BLOCK_REASON=
if [ -n "${FM_BROWSER_QA_LEDGER:-}" ]; then
  LEDGER_FILE=$FM_BROWSER_QA_LEDGER
elif [ -n "${HOME:-}" ]; then
  LEDGER_FILE="$HOME/.local/share/fm-browser-qa/runs.jsonl"
else
  LEDGER_FILE=
fi
TARGET_URL=
RESOLVED_URL=
OBSERVED_URL=
ROOT_RESOLVED=0
AUTH_CHECK_MODE=
LOGIN_ATTEMPTED=0
TEACHER_SESSION_REQUIRED=0
OUT_DIR=
BROWSER_URL=http://127.0.0.1:9222
BROWSER_URL_SET=0
SESSION_INPUT=
IDENTITY_INPUT=
AXI_SESSION_INPUT=
INHERITED_AXI_SESSION=${CHROME_DEVTOOLS_AXI_SESSION:-}
START_IF_NEEDED=0
LOGICAL_SESSION_NAME=
TMP_DIR=
WARNINGS_FILE=
AXI_SESSION_NAME=
MCP_COMPAT_DIR=
MCP_COMPAT_LOCK_FILE=
MCP_COMPAT_LOCK_PID=
MCP_COMPAT_STAGING_DIR=
MCP_OUTPUT_DIR=
JSON_RESULT=
CURL_TIMEOUT=${FM_BROWSER_QA_CURL_TIMEOUT:-2}
MODE=qa
STOP_AXI_ON_CLEANUP=1
ATTACH_EXPECTED_TITLE=
ATTACH_BINDING_READY=0
# chrome-devtools-mcp 1.8.0 requires pageId while AXI still relies on selected-page state.
# Remove this pin after AXI sends pageId or supports disabling page-id routing.
MCP_COMPAT_VERSION=1.7.0
LOGIN_HELPER=${FM_BROWSER_QA_LOGIN_HELPER:-"${HOME:-}/Documents/GitHub/teaching-verify/scripts/qa-chrome-login.mjs"}

usage() {
  cat >&2 <<'EOF'
usage: bin/fm-browser-qa.sh --url <exact-url> --out <dir> [--browser-url <url>] [--session <name>] [--start-if-needed]
       bin/fm-browser-qa.sh --select-identity <identity.json> --axi-session <session> [--out <dir>]

Bare HTTP(S) teachers[.-]*.typing.com roots select /dashboard on the same origin.
Both trailing-slash forms are accepted; query and fragment delimiters (even
empty ones), explicit routes, localized paths, and other hosts are unchanged.
URLs use browser-equivalent normalization. Prefer the exact class/student/report
route when known. Navigation and identity verification use the resolved target;
evidence preserves requested_url, resolved_url, and observed active_url, and the
ledger preserves url plus resolved_url. Success requires exact active_url match.

Protected teacher URL QA requires a fresh authenticated, active account and a usable
portal shell, with sanitized proof in teacher-session.json. Explicit unauthenticated
proof or an app login redirect permits one login attempt, followed by fresh URL
and session verification. Missing/unsupported API configuration, timeouts, and
unready UI block as unverified; see the script header for the proof contract.

Root resolution applies only to --url QA; attachment targets the receipt's
active_url exactly and remains compatible with receipts without resolved_url.
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
  [ "$MODE" != qa ] || rm -f "$OUT_DIR/report.md"
  {
    echo "# Browser QA FAILED"
    echo
    echo "- Stage: $STAGE"
    echo "- Reason: $BLOCK_REASON"
    echo "- Requested URL: ${TARGET_URL:-<unset>}"
    echo "- Resolved URL: ${RESOLVED_URL:-<unresolved>}"
    echo "- Observed URL: ${OBSERVED_URL:-<unobserved>}"
    if [ "$ROOT_RESOLVED" -eq 1 ]; then
      echo "- Resolution: teacher portal root resolved to /dashboard"
    fi
    echo "- Browser endpoint: ${BROWSER_URL:-<unset>}"
    echo "- Logical evidence session: ${LOGICAL_SESSION_NAME:-<unset>}"
    echo "- AXI bridge session: ${AXI_SESSION_NAME:-<unset>}"
    echo "- Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    # Landed-page identities outlive the temp dir here so a navigation that
    # ended somewhere unexpected (login redirect, error page) is self-diagnosing.
    if [ -n "${LANDED_PAGES_FILE:-}" ] && [ -s "${LANDED_PAGES_FILE:-}" ]; then
      echo
      echo "## Pages the navigation landed on"
      echo
      cat "$LANDED_PAGES_FILE"
    fi
  } > "$OUT_DIR/FAILED.md" 2>/dev/null || true
}

blocked() {
  BLOCK_REASON=$1
  echo "blocked: $1" >&2
  echo "URLs: requested=${TARGET_URL:-<unset>} resolved=${RESOLVED_URL:-<unresolved>} observed=${OBSERVED_URL:-<unobserved>}" >&2
  write_failure_marker
  exit 1
}

sanitize_token() {
  local raw=$1 token
  token=$(printf '%s' "$raw" | LC_ALL=C tr -c '[:alnum:]_.-' '-' | sed 's/^-*//; s/-*$//')
  [ -n "$token" ] || token=default
  printf '%s\n' "$token"
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

# This host matcher also scopes root resolution; keep teacher-host recognition
# in one place so login and URL selection cannot drift.
target_supports_auto_login() {
  node - "$1" <<'NODE'
const [target] = process.argv.slice(2);
try {
  const { hostname } = new URL(target);
  process.exit(/^teachers[.-]/.test(hostname) && /\.typing\.com$/.test(hostname) ? 0 : 1);
} catch {
  process.exit(1);
}
NODE
}

target_requires_teacher_session() {
  target_supports_auto_login "$1" || return 1
  node - "$1" <<'NODE'
const url = new URL(process.argv[2]);
const segments = url.pathname.split('/').slice(1);
if (['en', 'en-gb', 'es', 'br'].includes(segments[0])) segments.shift();
const protectedRoutes = ['dashboard', 'account', 'settings', 'orders', 'resources', 'reports', 'schools', 'school',
  'teachers', 'classes', 'pending-joins', 'students', 'live-activity', 'assignments', 'curriculum'];
process.exit(/^https?:$/.test(url.protocol) && protectedRoutes.includes(segments[0]) ? 0 : 1);
NODE
}

resolve_target_url() {
  local normalized
  normalized=$(normalize_url "$TARGET_URL")
  RESOLVED_URL=$normalized
  if target_supports_auto_login "$normalized"; then
    RESOLVED_URL=$(node - "$normalized" <<'NODE'
const [target] = process.argv.slice(2);
const url = new URL(target);
// href preserves even empty query/fragment delimiters, unlike search and hash.
if (/^https?:$/.test(url.protocol) && url.pathname === '/' && !url.href.includes('?') && !url.href.includes('#')) {
  url.pathname = '/dashboard';
}
process.stdout.write(url.href);
NODE
    )
    if [ "$RESOLVED_URL" != "$normalized" ]; then
      ROOT_RESOLVED=1
      echo "teacher portal root resolved to /dashboard: $TARGET_URL -> $RESOLVED_URL" >&2
    fi
  fi
}

valid_axi_session_name() {
  [ -n "$1" ] || return 1
  [ "${#1}" -le 64 ] || return 1
  case "$1" in
    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-]*)
      return 1
      ;;
  esac
  [ -n "$(printf '%s' "$1" | tr -d '.')" ] || return 1
}

curl_timeout_valid() {
  node - "$1" <<'NODE' >/dev/null 2>&1 || return 1
const raw = process.argv[2];
const syntax = /^\+?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?$/i;
const value = Number(raw);
process.exit(syntax.test(raw) && Number.isFinite(value) && value >= 0.001 ? 0 : 1);
NODE
  curl --silent --show-error --max-time "$1" --version >/dev/null 2>&1
}

identity_json_field() {
  node - "$1" "$2" "${3:-optional}" <<'NODE'
const fs = require('fs');
const [file, field, mode] = process.argv.slice(2);
let identity;
try {
  identity = JSON.parse(fs.readFileSync(file, 'utf8'));
} catch (error) {
  console.error(`could not read browser QA identity: ${error.message}`);
  process.exit(1);
}
const value = identity[field];
if (typeof value !== 'string') {
  if (mode === 'required') {
    console.error(`browser QA identity missing string field ${field}`);
    process.exit(1);
  }
  process.exit(0);
}
process.stdout.write(value);
NODE
}

axi() (
  local status=0
  if [ "$ATTACH_BINDING_READY" -eq 1 ]; then
    verify_attached_session_binding
  fi
  unset CHROME_DEVTOOLS_AXI_PORT CHROME_DEVTOOLS_AXI_AUTO_CONNECT
  export CHROME_DEVTOOLS_AXI_SESSION="$AXI_SESSION_NAME"
  export CHROME_DEVTOOLS_AXI_BROWSER_URL="$BROWSER_URL"
  chrome-devtools-axi "$@" || status=$?
  if [ "$ATTACH_BINDING_READY" -eq 1 ]; then
    verify_attached_session_binding
  fi
  return "$status"
)

# One JSON line per run, so failure rates and stage distribution are answerable
# after the fact instead of only from whatever terminal saw the run.
json_quote() {
  local LC_ALL=C value=$1 result='"' char code
  while [ -n "$value" ]; do
    char=${value%"${value#?}"}
    value=${value#?}
    case "$char" in
      '"') result="$result\\\"" ;;
      "\\") result="$result\\\\" ;;
      $'\b') result="$result\\b" ;;
      $'\f') result="$result\\f" ;;
      $'\n') result="$result\\n" ;;
      $'\r') result="$result\\r" ;;
      $'\t') result="$result\\t" ;;
      *)
        LC_ALL=C printf -v code '%d' "'$char"
        if [ "$code" -lt 32 ]; then
          printf -v char '\\u%04x' "$code"
        fi
        result="$result$char"
        ;;
    esac
  done
  JSON_RESULT="$result\""
}

json_nullable() {
  if [ -n "$1" ]; then
    json_quote "$1"
  else
    JSON_RESULT=null
  fi
}

append_ledger() {
  local LC_ALL=C status=$1 dir ts_json stage_json reason_json url_json resolved_json out_json session_json axi_json
  [ -n "$LEDGER_FILE" ] || return 0
  dir=$(dirname "$LEDGER_FILE")
  mkdir -p "$dir" >/dev/null 2>&1 || return 0
  json_quote "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; ts_json=$JSON_RESULT
  json_quote "$STAGE"; stage_json=$JSON_RESULT
  json_nullable "$BLOCK_REASON"; reason_json=$JSON_RESULT
  json_nullable "$TARGET_URL"; url_json=$JSON_RESULT
  json_nullable "$RESOLVED_URL"; resolved_json=$JSON_RESULT
  json_nullable "$OUT_DIR"; out_json=$JSON_RESULT
  json_nullable "$LOGICAL_SESSION_NAME"; session_json=$JSON_RESULT
  json_nullable "$AXI_SESSION_NAME"; axi_json=$JSON_RESULT
  printf '{"ts":%s,"status":%s,"stage":%s,"reason":%s,"url":%s,"resolved_url":%s,"out_dir":%s,"session":%s,"axi_session":%s}\n' \
    "$ts_json" "$status" "$stage_json" "$reason_json" "$url_json" "$resolved_json" "$out_json" "$session_json" "$axi_json" \
    >> "$LEDGER_FILE" 2>/dev/null || true
}

release_mcp_compat_lock() {
  local lock_pid
  [ -n "$MCP_COMPAT_LOCK_PID" ] || return 0
  lock_pid=$MCP_COMPAT_LOCK_PID
  MCP_COMPAT_LOCK_PID=
  kill -TERM "$lock_pid" >/dev/null 2>&1 || true
  wait "$lock_pid" >/dev/null 2>&1 || true
}

remove_mcp_compat_staging() {
  local staging_dir
  [ -n "$MCP_COMPAT_STAGING_DIR" ] || return 0
  staging_dir=$MCP_COMPAT_STAGING_DIR
  MCP_COMPAT_STAGING_DIR=
  rm -rf "$staging_dir" >/dev/null 2>&1 || true
}

remove_mcp_output_dir() {
  local output_dir
  [ -n "$MCP_OUTPUT_DIR" ] || return 0
  output_dir=$MCP_OUTPUT_DIR
  MCP_OUTPUT_DIR=
  rm -rf "$output_dir" >/dev/null 2>&1 || true
}

cleanup() {
  local status=$?
  trap - EXIT
  trap '' HUP INT TERM
  LC_ALL=C append_ledger "$status"
  if [ "$STOP_AXI_ON_CLEANUP" -eq 1 ] && [ -n "$AXI_SESSION_NAME" ]; then
    axi stop >/dev/null 2>&1 || true
  fi
  remove_mcp_output_dir
  remove_mcp_compat_staging
  release_mcp_compat_lock
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
      BROWSER_URL_SET=1
      shift 2
      ;;
    --session)
      [ "$#" -ge 2 ] || die_usage "--session requires a value"
      SESSION_INPUT=$2
      shift 2
      ;;
    --select-identity)
      [ "$#" -ge 2 ] || die_usage "--select-identity requires a value"
      MODE=select
      IDENTITY_INPUT=$2
      shift 2
      ;;
    --axi-session)
      [ "$#" -ge 2 ] || die_usage "--axi-session requires a value"
      AXI_SESSION_INPUT=$2
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

case "$MODE" in
  qa)
    [ -n "$TARGET_URL" ] || die_usage "--url is required"
    [ -n "$OUT_DIR" ] || die_usage "--out is required"
    [ -z "$IDENTITY_INPUT" ] || die_usage "--url cannot be combined with --select-identity"
    [ -z "$AXI_SESSION_INPUT" ] || die_usage "--axi-session applies only with --select-identity"
    ;;
  select)
    [ -n "$IDENTITY_INPUT" ] || die_usage "--select-identity is required"
    [ -z "$TARGET_URL" ] || die_usage "--url cannot be combined with --select-identity"
    [ -z "$SESSION_INPUT" ] || die_usage "--session applies only with --url; use --axi-session with --select-identity"
    [ "$START_IF_NEEDED" -eq 0 ] || die_usage "--start-if-needed cannot be combined with --select-identity"
    if [ -z "$AXI_SESSION_INPUT" ] && [ -n "$INHERITED_AXI_SESSION" ]; then
      AXI_SESSION_INPUT=$INHERITED_AXI_SESSION
    fi
    [ -n "$AXI_SESSION_INPUT" ] || die_usage "--axi-session is required with --select-identity"
    valid_axi_session_name "$AXI_SESSION_INPUT" \
      || die_usage "--axi-session must be 1-64 characters of A-Z, a-z, 0-9, dot, underscore, or dash"
    AXI_SESSION_NAME=$AXI_SESSION_INPUT
    LOGICAL_SESSION_NAME="attach-$AXI_SESSION_NAME"
    STOP_AXI_ON_CLEANUP=0
    ;;
  *)
    die_usage "unknown mode: $MODE"
    ;;
esac

command -v chrome-devtools-axi >/dev/null 2>&1 || blocked "chrome-devtools-axi is not installed or not on PATH"
command -v curl >/dev/null 2>&1 || blocked "curl is not installed or not on PATH"
command -v node >/dev/null 2>&1 || blocked "node is not installed or not on PATH"
curl_timeout_valid "$CURL_TIMEOUT" || CURL_TIMEOUT=2

BROWSER_URL=${BROWSER_URL%/}
[ -z "$OUT_DIR" ] || mkdir -p "$OUT_DIR" || blocked "could not create evidence directory: $OUT_DIR"

if [ "$MODE" = qa ]; then
  rm -f "$OUT_DIR/report.md" "$OUT_DIR/teacher-session.json"
  resolve_target_url
  if target_requires_teacher_session "$RESOLVED_URL"; then TEACHER_SESSION_REQUIRED=1; fi
  if [ -n "$SESSION_INPUT" ]; then
    LOGICAL_SESSION_NAME="fmqa-$(sanitize_token "$SESSION_INPUT")"
  else
    LOGICAL_SESSION_NAME="fmqa-$(sanitize_token "$(basename "$OUT_DIR")")"
  fi
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-browser-qa.XXXXXX")
WARNINGS_FILE="$TMP_DIR/warnings.txt"
: > "$WARNINGS_FILE"
if [ "$ROOT_RESOLVED" -eq 1 ]; then
  printf '%s\n' "- teacher portal root resolved to /dashboard: $TARGET_URL -> $RESOLVED_URL" >> "$WARNINGS_FILE"
fi
LANDED_PAGES_FILE="$TMP_DIR/landed-pages.txt"
: > "$LANDED_PAGES_FILE"

if [ "$MODE" = select ]; then
  [ -f "$IDENTITY_INPUT" ] || blocked "browser QA identity file does not exist: $IDENTITY_INPUT"
  IDENTITY_BROWSER_URL=$(identity_json_field "$IDENTITY_INPUT" browser_url required) \
    || blocked "could not read browser QA identity browser_url: $IDENTITY_INPUT"
  TARGET_URL=$(identity_json_field "$IDENTITY_INPUT" active_url required) \
    || blocked "could not read browser QA identity active_url: $IDENTITY_INPUT"
  ATTACH_EXPECTED_TITLE=$(identity_json_field "$IDENTITY_INPUT" title required) \
    || blocked "could not read browser QA identity title: $IDENTITY_INPUT"
  IDENTITY_BROWSER_URL=${IDENTITY_BROWSER_URL%/}
  if [ "$BROWSER_URL_SET" -eq 1 ] && [ "$BROWSER_URL" != "$IDENTITY_BROWSER_URL" ]; then
    blocked "browser endpoint override does not match browser QA identity: expected $IDENTITY_BROWSER_URL got $BROWSER_URL"
  fi
  BROWSER_URL=$IDENTITY_BROWSER_URL
  RESOLVED_URL=$(normalize_url "$TARGET_URL")
fi

target_reachable() {
  curl --globoff --fail -sS --max-time "$CURL_TIMEOUT" --output /dev/null "$RESOLVED_URL" >/dev/null 2>&1
}

if [ "$MODE" = qa ]; then
  STAGE=target-reachability
  target_reachable \
    || blocked "target host is unreachable; likely torn-down feature branch for exact QA URL: $RESOLVED_URL"
fi

mcp_compat_package_json() {
  printf '%s/node_modules/chrome-devtools-mcp/package.json\n' "$1"
}

mcp_compat_script() {
  printf '%s/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js\n' "$1"
}

mcp_compat_valid() {
  local install_dir=$1 package_json script
  package_json=$(mcp_compat_package_json "$install_dir")
  script=$(mcp_compat_script "$install_dir")
  node - "$package_json" "$script" "$MCP_COMPAT_VERSION" <<'NODE' >/dev/null 2>&1 || return 1
const fs = require('fs');
const path = require('path');
const [packageJsonPath, scriptPath, expectedVersion] = process.argv.slice(2);
const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'));
const expectedBin = './build/src/bin/chrome-devtools-mcp.js';
if (packageJson.name !== 'chrome-devtools-mcp') process.exit(1);
if (packageJson.version !== expectedVersion) process.exit(1);
if (!packageJson.bin || packageJson.bin['chrome-devtools-mcp'] !== expectedBin) process.exit(1);
if (path.resolve(path.dirname(packageJsonPath), expectedBin) !== path.resolve(scriptPath)) process.exit(1);
const stat = fs.statSync(scriptPath);
if (!stat.isFile() || stat.size === 0) process.exit(1);
NODE
  node --check "$script" >/dev/null 2>&1 || return 1
  node - "$script" <<'NODE' >/dev/null 2>&1
const { spawnSync } = require('child_process');
const scriptPath = process.argv[2];
const probe = spawnSync(process.execPath, [scriptPath, '--help'], {
  env: {
    ...process.env,
    CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS: '1',
    CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS: '1',
  },
  stdio: 'ignore',
  timeout: 5000,
  killSignal: 'SIGKILL',
});
if (probe.error || probe.signal || probe.status !== 0) process.exit(1);
NODE
}

acquire_mcp_compat_lock() {
  local lock_path=$1 ready_file lock_token lock_status=0
  command -v perl >/dev/null 2>&1 \
    || blocked "perl is required to coordinate the chrome-devtools-mcp compatibility cache"
  ready_file="$TMP_DIR/mcp-lock-ready"
  lock_token="$$:$(sanitize_token "$(basename "$TMP_DIR")")"
  rm -f "$ready_file"
  perl - "$lock_path" "$ready_file" "$$" "$lock_token" <<'PERL' &
use strict;
use warnings;
use Fcntl qw(:flock :DEFAULT :mode SEEK_SET O_NOFOLLOW);
use IO::Handle;

my ($lock_path, $ready_file, $parent_pid, $lock_token) = @ARGV;
sysopen my $lock, $lock_path, O_RDWR | O_CREAT | O_NOFOLLOW, 0600 or exit 2;
my @lock_stat = stat $lock;
my @path_stat = lstat $lock_path;
exit 6 unless @lock_stat && @path_stat;
exit 6 unless S_ISREG($lock_stat[2]) && $lock_stat[3] == 1 && $lock_stat[4] == $<;
exit 6 unless $lock_stat[0] == $path_stat[0] && $lock_stat[1] == $path_stat[1];
chmod 0600, $lock_path or exit 6;
my $running = 1;
$SIG{HUP} = $SIG{INT} = $SIG{TERM} = sub { $running = 0 };
while ($running && getppid() == $parent_pid) {
  last if flock($lock, LOCK_EX | LOCK_NB);
  select undef, undef, undef, 0.05;
}
exit 3 unless $running && getppid() == $parent_pid;
@lock_stat = stat $lock;
@path_stat = lstat $lock_path;
exit 6 unless @lock_stat && @path_stat;
exit 6 unless S_ISREG($lock_stat[2]) && $lock_stat[3] == 1 && $lock_stat[4] == $<;
exit 6 unless $lock_stat[0] == $path_stat[0] && $lock_stat[1] == $path_stat[1];
seek $lock, 0, SEEK_SET or exit 4;
truncate $lock, 0 or exit 4;
print {$lock} "$parent_pid\t$$\t$lock_token\n" or exit 4;
$lock->flush or exit 4;
open my $ready, '>', $ready_file or exit 5;
print {$ready} "$lock_token\n" or exit 5;
close $ready or exit 5;
while ($running && getppid() == $parent_pid) {
  select undef, undef, undef, 0.05;
}
seek $lock, 0, SEEK_SET;
truncate $lock, 0;
close $lock;
PERL
  MCP_COMPAT_LOCK_PID=$!
  while [ ! -s "$ready_file" ]; do
    if ! kill -0 "$MCP_COMPAT_LOCK_PID" 2>/dev/null; then
      wait "$MCP_COMPAT_LOCK_PID" || lock_status=$?
      MCP_COMPAT_LOCK_PID=
      blocked "could not acquire chrome-devtools-mcp compatibility cache lock ($lock_status): $lock_path"
    fi
    sleep "${FM_BROWSER_QA_MCP_LOCK_SLEEP:-0.1}"
  done
}

prepare_mcp_compat_lock_file() {
  local cache_parent=$1 canonical_parent canonical_cache lock_dir lock_key
  canonical_parent=$(cd "$cache_parent" && pwd -P) \
    || blocked "could not resolve chrome-devtools-mcp compatibility cache parent: $cache_parent"
  canonical_cache="$canonical_parent/$(basename "$MCP_COMPAT_DIR")"
  lock_dir="$HOME/.local/share/fm-browser-qa/locks"
  [ ! -L "$lock_dir" ] \
    || blocked "chrome-devtools-mcp compatibility lock directory must not be a symlink: $lock_dir"
  if [ -e "$lock_dir" ] && [ ! -d "$lock_dir" ]; then
    blocked "chrome-devtools-mcp compatibility lock path is not a directory: $lock_dir"
  fi
  mkdir -p "$lock_dir" \
    || blocked "could not create chrome-devtools-mcp compatibility lock directory: $lock_dir"
  chmod 700 "$lock_dir" \
    || blocked "could not secure chrome-devtools-mcp compatibility lock directory: $lock_dir"
  lock_key=$(node -e \
    'const crypto=require("crypto"); process.stdout.write(crypto.createHash("sha256").update(process.argv[1]).digest("hex"))' \
    "$canonical_cache") \
    || blocked "could not identify chrome-devtools-mcp compatibility cache lock: $canonical_cache"
  MCP_COMPAT_LOCK_FILE="$lock_dir/chrome-devtools-mcp-$MCP_COMPAT_VERSION-$lock_key.lock"
}

ensure_mcp_compat() {
  local cache_parent default_cache_dir install_output install_error replace_invalid=0
  if [ "${CHROME_DEVTOOLS_AXI_MCP_PATH+x}" = x ]; then
    return 0
  fi
  [ -n "${HOME:-}" ] || blocked "HOME is not set; cannot prepare the chrome-devtools-mcp compatibility cache"
  default_cache_dir="$HOME/.local/share/fm-browser-qa/chrome-devtools-mcp-$MCP_COMPAT_VERSION"
  MCP_COMPAT_DIR=${FM_BROWSER_QA_MCP_COMPAT_DIR:-$default_cache_dir}
  [ "$MCP_COMPAT_DIR" != "$default_cache_dir" ] || replace_invalid=1
  if ! mcp_compat_valid "$MCP_COMPAT_DIR"; then
    if [ "$replace_invalid" -eq 0 ] && { [ -e "$MCP_COMPAT_DIR" ] || [ -L "$MCP_COMPAT_DIR" ]; }; then
      blocked "refusing to replace an invalid custom chrome-devtools-mcp compatibility cache: $MCP_COMPAT_DIR"
    fi
    command -v npm >/dev/null 2>&1 \
      || blocked "npm is required to install chrome-devtools-mcp $MCP_COMPAT_VERSION for chrome-devtools-axi compatibility"
    cache_parent=$(dirname "$MCP_COMPAT_DIR")
    mkdir -p "$cache_parent" \
      || blocked "could not create chrome-devtools-mcp compatibility cache parent: $cache_parent"
    prepare_mcp_compat_lock_file "$cache_parent"
    acquire_mcp_compat_lock "$MCP_COMPAT_LOCK_FILE"
    if ! mcp_compat_valid "$MCP_COMPAT_DIR"; then
      MCP_COMPAT_STAGING_DIR=$(mktemp -d "$cache_parent/.chrome-devtools-mcp-$MCP_COMPAT_VERSION.staging.XXXXXX") \
        || blocked "could not create chrome-devtools-mcp compatibility staging directory in: $cache_parent"
      install_output="$TMP_DIR/mcp-install.out"
      install_error="$TMP_DIR/mcp-install.err"
      if ! npm install --prefix "$MCP_COMPAT_STAGING_DIR" --no-save --no-package-lock \
        --ignore-scripts --omit=dev "chrome-devtools-mcp@$MCP_COMPAT_VERSION" \
        > "$install_output" 2> "$install_error"; then
        blocked "could not install chrome-devtools-mcp $MCP_COMPAT_VERSION compatibility cache: $(stream_detail "$install_error" "$install_output")"
      fi
      mcp_compat_valid "$MCP_COMPAT_STAGING_DIR" \
        || blocked "installed chrome-devtools-mcp compatibility cache failed validation: $MCP_COMPAT_STAGING_DIR"
      if [ -e "$MCP_COMPAT_DIR" ] || [ -L "$MCP_COMPAT_DIR" ]; then
        [ "$replace_invalid" -eq 1 ] \
          || blocked "refusing to replace an invalid custom chrome-devtools-mcp compatibility cache: $MCP_COMPAT_DIR"
        rm -rf "$MCP_COMPAT_DIR" \
          || blocked "could not replace invalid chrome-devtools-mcp compatibility cache: $MCP_COMPAT_DIR"
      fi
      mv "$MCP_COMPAT_STAGING_DIR" "$MCP_COMPAT_DIR" \
        || blocked "could not publish chrome-devtools-mcp compatibility cache: $MCP_COMPAT_DIR"
      MCP_COMPAT_STAGING_DIR=
    fi
    mcp_compat_valid "$MCP_COMPAT_DIR" \
      || blocked "chrome-devtools-mcp compatibility cache is invalid after publish: $MCP_COMPAT_DIR"
    release_mcp_compat_lock
  fi
  mcp_compat_valid "$MCP_COMPAT_DIR" \
    || blocked "chrome-devtools-mcp compatibility cache is invalid after install: $MCP_COMPAT_DIR"
  CHROME_DEVTOOLS_AXI_MCP_PATH=$(mcp_compat_script "$MCP_COMPAT_DIR")
  export CHROME_DEVTOOLS_AXI_MCP_PATH
}

STAGE=mcp-compat
ensure_mcp_compat
if [ "$MODE" = qa ]; then
  AXI_SESSION_NAME="fmqa-$(sanitize_token "$(basename "$TMP_DIR")")"
fi
STAGE=browser-check

append_warning() {
  printf '%s\n' "- $1" >> "$WARNINGS_FILE"
}

browser_json_url() {
  printf '%s/json/version\n' "$BROWSER_URL"
}

browser_reachable() {
  curl -fsS --max-time "$CURL_TIMEOUT" "$(browser_json_url)" >/dev/null 2>&1
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
    "$RESOLVED_URL" >/dev/null 2>&1 \
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


parse_eval_identity() {
  node - "$1" "$2" "${3:-}" <<'NODE'
const fs = require('fs');
const [input, output, bindingFile] = process.argv.slice(2);
const text = fs.readFileSync(input, 'utf8');
const result = text.split('\n').find(line => line.startsWith('result:'))?.slice(7).trim();
if (!result) {
  console.error('missing result line');
  process.exit(1);
}
let value;
try {
  value = JSON.parse(result);
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
  title: typeof value.title === 'string' ? value.title : '',
  ...(value.teacher_session ? { teacher_session: Object.fromEntries(
    ['status', 'reason', 'api_origin', 'http_status', 'principal_valid', 'role_valid', 'active', 'shell_ready']
      .filter(key => ['string', 'number', 'boolean'].includes(typeof value.teacher_session[key]))
      .map(key => [key, value.teacher_session[key]])) } : {}),
  ...(bindingFile && fs.existsSync(bindingFile) ? { browser_target_ids: JSON.parse(fs.readFileSync(bindingFile, 'utf8')) } : {}),
}, null, 2) + '\n');
NODE
}

write_identity() {
  node - "$1" "$2" "$BROWSER_URL" "$LOGICAL_SESSION_NAME" "$AXI_SESSION_NAME" "$TARGET_URL" "$RESOLVED_URL" "$OUT_DIR/identity.json" "$TEACHER_SESSION_REQUIRED" <<'NODE'
const fs = require('fs');
const [identityFile, pageId, browserUrl, logicalSessionName, axiSessionName, requestedUrl, resolvedUrl, output, sessionRequired] = process.argv.slice(2);
const identity = JSON.parse(fs.readFileSync(identityFile, 'utf8'));
fs.writeFileSync(output, JSON.stringify({
  page_id: pageId,
  requested_url: requestedUrl,
  resolved_url: resolvedUrl,
  teacher_session_required: sessionRequired === '1',
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
  node - "$1" "$2" "${3:-$AUTH_CHECK_MODE}" <<'NODE'
const [href, title, mode] = process.argv.slice(2);
const h = String(href || '').toLowerCase();
const t = String(title || '').toLowerCase();
if (h.includes('/cdn-cgi/access/login') || t.includes('cloudflare access') || (mode !== 'cloudflare-only' && /\bsign[ -]?in\b/.test(t))) {
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

mcp_call() {
  FM_QA_MCP_TOOL=$1 FM_QA_MCP_ARGS=$2 FM_QA_MCP_PORT_FILE="$TMP_DIR/mcp-port.json" \
    FM_QA_AXI_PAGES_FILE="${3:-}" axi run <<'NODE'
import { existsSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const cli = pathToFileURL(realpathSync(process.argv[1]));
const portFile = process.env.FM_QA_MCP_PORT_FILE;
const pagesFile = process.env.FM_QA_AXI_PAGES_FILE;
const name = process.env.FM_QA_MCP_TOOL;
const args = JSON.parse(process.env.FM_QA_MCP_ARGS);
let raw;
if (pagesFile) {
  const { callTool } = await import(new URL('../src/client.js', cli));
  raw = await callTool(name, args);
} else {
  if (!existsSync(portFile)) {
    const { ensureBridge } = await import(new URL('../src/client.js', cli));
    writeFileSync(portFile, JSON.stringify(await ensureBridge()));
  }
  const port = JSON.parse(readFileSync(portFile, 'utf8'));
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('invalid AXI bridge port');
  const response = await fetch(`http://127.0.0.1:${port}/call`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name, args }),
    signal: AbortSignal.timeout(120000),
  });
  const result = await response.json();
  if (!response.ok || result.error || typeof result.result !== 'string') {
    throw new Error(result.error || 'AXI bridge did not return an MCP result');
  }
  raw = result.result;
}
if (typeof raw !== 'string') throw new Error('AXI bridge did not return an MCP result');
if (/^Note: the browser was restarted or reconnected since the last call\./m.test(raw) ||
    /^Note: the previously selected page (?:was closed|is no longer listed)\./m.test(raw)) {
  throw new Error('MCP browser context changed during page probe');
}
if (name === 'evaluate_script') {
  const match = raw.match(/Script ran on page and returned:\n```json\n([\s\S]*?)\n```/);
  if (!match) throw new Error(`could not evaluate browser page identity: ${raw}`);
  console.log(`result: ${JSON.stringify(JSON.parse(match[1]))}`);
} else {
  const pages = [];
  const ids = new Set();
  let inPages = false;
  for (const line of raw.split('\n')) {
    if (line.startsWith('## ')) {
      inPages = line === '## Pages' || line === '## Extension Pages';
      continue;
    }
    if (!inPages || !line.trim()) continue;
    const page = line.match(/^(\d+): /);
    if (!page || ids.has(page[1])) throw new Error('could not parse an unambiguous MCP page inventory');
    ids.add(page[1]);
    pages.push({ id: page[1], label: line.slice(page[0].length) });
  }
  if (pagesFile) {
    // AXI's formatted rows can replace a titled URL with its first title token.
    // Use their IDs only; raw MCP labels retain the URL and selection marker.
    // See test_real_mcp_to_axi_inventory_conversion in tests/fm-browser-qa.test.sh.
    const lines = readFileSync(pagesFile, 'utf8').trim().split('\n');
    const empty = lines[0] === 'pages: 0 pages open';
    const header = lines[0].match(/^pages\[(\d+)\]\{id,url,selected\}:$/);
    if (!empty && !header) throw new Error('could not parse an unambiguous AXI page inventory');
    const count = empty ? 0 : Number(header[1]);
    const pageIds = new Set();
    for (const line of lines.slice(1, count + 1)) {
      const row = line.match(/^  (\d+),.*,(?:true|false)$/);
      if (!row || pageIds.has(row[1])) throw new Error('could not parse an unambiguous AXI page inventory');
      pageIds.add(row[1]);
    }
    const tail = lines.slice(count + 1).filter(line => line.trim());
    if (pageIds.size !== count || (tail.length && !/^help\[\d+\]:$/.test(tail[0]))) {
      throw new Error('could not parse an unambiguous AXI page inventory');
    }
    if (ids.size !== pageIds.size || [...ids].some(id => !pageIds.has(id))) {
      throw new Error('AXI page inventory changed during recovery');
    }
  }
  if (name === 'select_page' && !ids.has(String(args.pageId))) {
    throw new Error(`could not select browser page ${args.pageId}: ${raw}`);
  }
  if (name === 'new_page' && !pages.length) throw new Error(`could not open browser page: ${raw}`);
  console.log(JSON.stringify(pages));
}
NODE
}

page_inventory() {
  if ! mcp_call list_pages '{}' > "$TMP_DIR/mcp-inventory.json" 2> "$TMP_DIR/mcp-inventory.err"; then
    if [ -s "$TMP_DIR/mcp-inventory.json" ] || [ -s "$TMP_DIR/mcp-inventory.err" ]; then
      cat "$TMP_DIR/mcp-inventory.err" >&2
      cat "$TMP_DIR/mcp-inventory.json" >&2
      return 1
    fi
    if ! axi pages > "$TMP_DIR/axi-pages-fallback.txt" 2> "$TMP_DIR/axi-pages-fallback.err"; then
      cat "$TMP_DIR/axi-pages-fallback.err" >&2
      cat "$TMP_DIR/axi-pages-fallback.txt" >&2
      return 1
    fi
    mcp_call list_pages '{}' "$TMP_DIR/axi-pages-fallback.txt" > "$TMP_DIR/mcp-inventory.json" || return 1
  fi
  curl --fail -sS --max-time "$CURL_TIMEOUT" "$BROWSER_URL/json/list" > "$TMP_DIR/browser-inventory.json" || return 1
  node - "$TMP_DIR/mcp-inventory.json" "$TMP_DIR/browser-inventory.json" <<'NODE'
const fs = require('fs');
const [pagesFile, targetsFile] = process.argv.slice(2);
const pages = JSON.parse(fs.readFileSync(pagesFile, 'utf8'));
const targets = JSON.parse(fs.readFileSync(targetsFile, 'utf8'));
if (!Array.isArray(targets)) throw new Error('browser did not return a full-title inventory');
const ids = new Set();
const identities = targets.filter(target => target.type === 'page').map(target => {
  if (typeof target.id !== 'string' || !target.id || ids.has(target.id) ||
      typeof target.url !== 'string' || typeof target.title !== 'string') {
    throw new Error('browser returned an invalid full-title inventory');
  }
  ids.add(target.id);
  return { id: target.id, href: target.url, title: target.title };
});
console.log(JSON.stringify({ pages, identities }));
NODE
}

inventory_lookup() {
  node - "$@" <<'NODE'
const fs = require('fs');
const [file, mode, value, wanted] = process.argv.slice(2);
const { pages, identities } = JSON.parse(fs.readFileSync(file, 'utf8'));
const suffix = /^(?: \[selected\])?(?: isolatedContext=.*)?$/;
let matches;
if (mode === 'ids') {
  matches = pages;
} else if (mode === 'identity' || mode === 'selected-identity' || mode === 'identity-count') {
  const { href, title, browser_target_ids: boundIds } = JSON.parse(fs.readFileSync(value, 'utf8'));
  const current = identities.filter(identity => identity.href === href && identity.title === title);
  if (mode === 'identity-count') {
    console.log(current.length);
    process.exit(0);
  }
  const shortTitle = title.length > 50 ? title.slice(0, 47) + '...' : title;
  const label = shortTitle ? `${shortTitle} (${href})` : href;
  const metadata = mode === 'selected-identity' ? /^ \[selected\](?: isolatedContext=.*)?$/ : suffix;
  const hasIdentity = boundIds
    ? (mode === 'identity' ? boundIds.every(id => current.some(identity => identity.id === id))
      : current.some(identity => boundIds.includes(identity.id)))
    : current.length > 0;
  matches = pages.filter(page => hasIdentity && (!wanted || page.id === wanted) &&
    page.label.startsWith(label) && metadata.test(page.label.slice(label.length)));
} else if (mode === 'url') {
  matches = pages.filter(page => {
    if (wanted && page.id !== wanted) return false;
    if (page.label.startsWith(value) && suffix.test(page.label.slice(value.length))) return true;
    const end = page.label.lastIndexOf(` (${value})`);
    return end >= 0 && suffix.test(page.label.slice(end + value.length + 3));
  });
} else {
  throw new Error('unknown inventory lookup');
}
for (const page of matches) console.log(page.id);
NODE
}

probe_page() {
  local page_id=$1 out_json=$2 safe_id err_file evaluated_json pages_file binding_file eval_args attempts_left=2
  eval_args=${3:-}
  [ -n "$eval_args" ] || eval_args='{"function":"() => ({href: location.href, title: document.title})"}'
  safe_id=$(safe_page_id "$page_id")
  err_file="$TMP_DIR/probe-$safe_id.err"
  evaluated_json="$TMP_DIR/probe-evaluated-$safe_id.json"
  pages_file="$TMP_DIR/probe-pages-$safe_id.out"
  binding_file="$TMP_DIR/probe-targets-$safe_id.json"
  mcp_call select_page "{\"pageId\":$page_id}" > "$TMP_DIR/select-$safe_id.out" 2> "$err_file" || return 1
  while [ "$attempts_left" -gt 0 ]; do
    attempts_left=$((attempts_left - 1))
    mcp_call evaluate_script "$eval_args" > "$TMP_DIR/eval-$safe_id.out" 2> "$err_file" || return 1
    parse_eval_identity "$TMP_DIR/eval-$safe_id.out" "$evaluated_json" "$binding_file" 2> "$err_file" || return 1
    page_inventory > "$pages_file" 2> "$err_file" || return 1
    if [ "$(inventory_lookup "$pages_file" selected-identity "$evaluated_json" "$page_id")" = "$page_id" ]; then
      node - "$evaluated_json" "$pages_file" "$binding_file" <<'NODE' 2> "$err_file" || return 1
const fs = require('fs');
const [identityFile, pagesFile, bindingFile] = process.argv.slice(2);
const identity = JSON.parse(fs.readFileSync(identityFile, 'utf8'));
const { identities } = JSON.parse(fs.readFileSync(pagesFile, 'utf8'));
const boundIds = identity.browser_target_ids;
identity.browser_target_ids = identities.filter(current => current.href === identity.href && current.title === identity.title &&
  (!boundIds || boundIds.includes(current.id))).map(current => current.id);
if (!identity.browser_target_ids.length) throw new Error('browser target identity changed during page probe');
fs.writeFileSync(bindingFile, JSON.stringify(identity.browser_target_ids));
fs.writeFileSync(identityFile, JSON.stringify(identity) + '\n');
NODE
      cp "$evaluated_json" "$out_json" 2> "$err_file" || return 1
      return 0
    fi
  done
  echo "browser page identity or selection changed while confirming page $page_id" > "$err_file"
  return 1
}

probe_error() {
  local safe_id
  safe_id=$(safe_page_id "$1")
  stream_detail "$TMP_DIR/probe-$safe_id.err" "$TMP_DIR/select-$safe_id.out" \
    "$TMP_DIR/eval-$safe_id.out" "$TMP_DIR/probe-pages-$safe_id.out"
}

list_page_ids() {
  local label=$1
  if ! page_inventory > "$TMP_DIR/pages-$label.txt" 2> "$TMP_DIR/pages-$label.err"; then
    blocked "could not enumerate browser pages: $(stream_detail "$TMP_DIR/pages-$label.err" "$TMP_DIR/pages-$label.txt")"
  fi
  inventory_lookup "$TMP_DIR/pages-$label.txt" ids
}

landing_page_id() {
  local matches
  matches=$(inventory_lookup "$TMP_DIR/pages-after-open.txt" selected-identity "$1")
  [ -n "$matches" ] && [ "$(printf '%s\n' "$matches" | wc -l | tr -d '[:space:]')" = 1 ] || return 1
  printf '%s\n' "$matches"
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

verify_attached_session_binding() {
  STAGE=attach-session
  if ! node - "$AXI_SESSION_NAME" "$BROWSER_URL" "$TMP_DIR/attach-start.out" "$TMP_DIR/attach-binding.json" "${1:-verify}" <<'NODE' 2> "$TMP_DIR/attach-binding.err"
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');
const [session, expected, startFile, bindingFile, mode] = process.argv.slice(2);
try {
  const stateDir = path.join(os.homedir(), '.chrome-devtools-axi', ...(session === 'default' ? [] : ['sessions', session]));
  const stateFile = path.join(stateDir, 'bridge.pid');
  const binding = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
  const original = mode === 'capture' ? binding : JSON.parse(fs.readFileSync(bindingFile, 'utf8'));
  const requireOriginal = current => {
    if (current.pid !== original.pid || current.port !== original.port) {
      throw new Error('AXI session bridge changed during attachment; rerun page discovery');
    }
  };
  requireOriginal(binding);
  const ports = [...fs.readFileSync(startFile, 'utf8').matchAll(/^port:\s*(\d+)\s*$/gm)];
  if (!Number.isSafeInteger(binding.pid) || binding.pid <= 0 || ports.length !== 1 || Number(ports[0][1]) !== binding.port) {
    throw new Error('AXI session state does not identify the ready bridge');
  }
  const bridge = execFileSync('ps', ['eww', '-p', String(binding.pid), '-o', 'command='], {
    encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'],
  });
  if (!/(?:^|\/)chrome-devtools-axi-bridge\.(?:js|ts)(?:\s|$)/.test(bridge)) {
    throw new Error('AXI session bridge process could not be verified');
  }
  const setting = name => {
    const values = [...bridge.matchAll(new RegExp(`(?:^|\\s)${name}=(\\S*)`, 'g'))];
    if (values.length > 1) throw new Error('AXI bridge connection settings are ambiguous');
    return values[0]?.[1];
  };
  if (setting('CHROME_DEVTOOLS_AXI_SESSION') !== session || Number(setting('CHROME_DEVTOOLS_AXI_PORT')) !== binding.port) {
    throw new Error('AXI bridge process does not match the named session');
  }
  const endpoint = setting('CHROME_DEVTOOLS_AXI_BROWSER_URL');
  if (!endpoint || setting('CHROME_DEVTOOLS_AXI_AUTO_CONNECT') === '1') {
    throw new Error('AXI bridge has no verifiable explicit browser endpoint');
  }
  const actual = endpoint.replace(/\/$/, '');
  if (actual !== expected) throw new Error(`browser endpoint mismatch: expected ${expected} got ${actual}`);
  requireOriginal(JSON.parse(fs.readFileSync(stateFile, 'utf8')));
  if (mode === 'capture') fs.writeFileSync(bindingFile, JSON.stringify({ pid: binding.pid, port: binding.port }));
} catch (error) {
  console.error(error.stderr !== undefined ? 'could not inspect the running AXI bridge' : error.message);
  process.exit(1);
}
NODE
  then
    blocked "could not verify attached AXI session browser endpoint: $(stream_detail "$TMP_DIR/attach-binding.err")"
  fi
}

write_attached_identity() {
  [ -n "$OUT_DIR" ] || return 0
  node - "$IDENTITY_INPUT" "$1" "$2" "$BROWSER_URL" "$AXI_SESSION_NAME" "$OUT_DIR" <<'NODE'
const fs = require('fs');
const path = require('path');
const [sourceFile, identityFile, pageId, browserUrl, axiSessionName, outputDir] = process.argv.slice(2);
const source = JSON.parse(fs.readFileSync(sourceFile, 'utf8'));
const identity = JSON.parse(fs.readFileSync(identityFile, 'utf8'));
const attached = {
  page_id: pageId,
  page_id_scope: 'selected AXI session only',
  requested_url: source.requested_url ?? '',
  active_url: identity.href,
  title: identity.title,
  browser_url: browserUrl,
  axi_session: axiSessionName,
  source_identity: sourceFile,
  source_page_id: source.page_id ?? null,
  source_axi_session: source.axi_session ?? '',
  selected_at: new Date().toISOString(),
};
fs.writeFileSync(path.join(outputDir, 'attached-identity.json'), JSON.stringify(attached, null, 2) + '\n');
fs.writeFileSync(path.join(outputDir, 'attached-report.md'), [
  '# Browser QA Attached Page Selection',
  '',
  `- Active URL: ${attached.active_url}`,
  `- Title: ${attached.title}`,
  `- Attached page ID: ${attached.page_id}`,
  `- Page ID scope: ${attached.page_id_scope}`,
  `- Browser endpoint: ${attached.browser_url}`,
  `- AXI session: ${attached.axi_session}`,
  `- Source identity: ${attached.source_identity}`,
  '',
].join('\n'));
NODE
}

scan_attached_pages() {
  local scan_dir=$1 ids=$2 pages_file=$3 page_id identity_json href
  mkdir -p "$scan_dir"
  : > "$scan_dir/matches.tsv"
  for page_id in $ids; do
    identity_json="$scan_dir/page-$(safe_page_id "$page_id").json"
    if ! probe_page "$page_id" "$identity_json"; then
      if [ "$(inventory_lookup "$pages_file" url "$NORM_TARGET_URL" "$page_id")" = "$page_id" ]; then
        blocked "could not prove attached browser page $page_id identity: $(probe_error "$page_id")"
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

select_attached_identity_page() {
  local ids scan_dir matches url_count title_matches title_count match_line page_id
  local final_identity final_href final_title
  local candidate_dir candidate_id candidate_identity candidate_href pending_ids pages_file attempts_left=3
  STAGE=attach-page-scan
  scan_dir="$TMP_DIR/attach-scan"
  ids=$(list_page_ids attach)
  scan_attached_pages "$scan_dir" "$ids" "$TMP_DIR/pages-attach.txt"
  matches="$scan_dir/matches.tsv"
  url_count=$(count_lines "$matches")
  if [ "$url_count" -eq 0 ]; then
    blocked "no browser tabs match attached browser QA identity URL: $NORM_TARGET_URL"
  fi
  if [ "$url_count" -gt 1 ]; then
    title_matches="$scan_dir/title-matches.tsv"
    node - "$IDENTITY_INPUT" "$matches" <<'NODE' > "$title_matches"
const fs = require('fs');
const [sourceFile, matchesFile] = process.argv.slice(2);
const { title } = JSON.parse(fs.readFileSync(sourceFile, 'utf8'));
for (const line of fs.readFileSync(matchesFile, 'utf8').split('\n').filter(Boolean)) {
  const identityFile = line.slice(line.indexOf('\t') + 1);
  if (JSON.parse(fs.readFileSync(identityFile, 'utf8')).title === title) process.stdout.write(line + '\n');
}
NODE
    title_count=$(count_lines "$title_matches")
    if [ "$title_count" -eq 0 ]; then
      blocked "multiple tabs match attached browser QA identity URL but none match the verified title: $ATTACH_EXPECTED_TITLE"
    fi
    if [ "$title_count" -gt 1 ]; then
      blocked "multiple tabs match attached browser QA identity URL and title; cannot choose a unique page: $NORM_TARGET_URL"
    fi
    matches=$title_matches
  fi

  match_line=$(sed -n '1p' "$matches")
  page_id=$(printf '%s\n' "$match_line" | cut -f1)
  final_identity="$TMP_DIR/attached-final-identity.json"
  candidate_dir="$TMP_DIR/attach-reconciled"
  mkdir -p "$candidate_dir"
  pages_file="$TMP_DIR/probe-pages-$(safe_page_id "$page_id").out"
  while :; do
    STAGE=attach-identity
    if ! probe_page "$page_id" "$final_identity"; then
      blocked "could not prove attached browser page $page_id identity after selection: $(probe_error "$page_id")"
    fi
    final_href=$(json_field "$final_identity" href)
    final_title=$(json_field "$final_identity" title)
    if [ "$final_href" != "$NORM_TARGET_URL" ]; then
      blocked "attached browser page drifted after selection: expected $NORM_TARGET_URL got $final_href"
    fi
    if ! node - "$IDENTITY_INPUT" "$final_identity" <<'NODE'
const fs = require('fs');
const [sourceFile, identityFile] = process.argv.slice(2);
process.exit(JSON.parse(fs.readFileSync(sourceFile, 'utf8')).title === JSON.parse(fs.readFileSync(identityFile, 'utf8')).title ? 0 : 1);
NODE
    then
      blocked "attached browser page title mismatch after selection: expected $ATTACH_EXPECTED_TITLE got $final_title"
    fi

    pending_ids=
    ids=$(inventory_lookup "$pages_file" url "$NORM_TARGET_URL")
    for candidate_id in $ids; do
      [ "$candidate_id" != "$page_id" ] || continue
      candidate_identity="$candidate_dir/page-$(safe_page_id "$candidate_id").json"
      if [ ! -f "$candidate_identity" ] ||
         [ "$(inventory_lookup "$pages_file" identity "$candidate_identity" "$candidate_id")" != "$candidate_id" ]; then
        pending_ids="$pending_ids $candidate_id"
        continue
      fi
      candidate_href=$(json_field "$candidate_identity" href)
      if [ "$candidate_href" = "$NORM_TARGET_URL" ] && node - "$IDENTITY_INPUT" "$candidate_identity" <<'NODE'
const fs = require('fs');
const [sourceFile, identityFile] = process.argv.slice(2);
process.exit(JSON.parse(fs.readFileSync(sourceFile, 'utf8')).title === JSON.parse(fs.readFileSync(identityFile, 'utf8')).title ? 0 : 1);
NODE
      then
        blocked "multiple tabs match attached browser QA identity URL and title; cannot choose a unique page: $NORM_TARGET_URL"
      fi
    done
    if [ -z "$pending_ids" ]; then
      if [ "$(inventory_lookup "$pages_file" identity-count "$final_identity")" -ne 1 ]; then
        blocked "multiple tabs match attached browser QA identity URL and title; cannot choose a unique page: $NORM_TARGET_URL"
      fi
      break
    fi
    [ "$attempts_left" -gt 0 ] || blocked "attached browser page candidates kept changing; cannot prove a unique page: $NORM_TARGET_URL"
    attempts_left=$((attempts_left - 1))
    STAGE=attach-page-scan
    for candidate_id in $pending_ids; do
      candidate_identity="$candidate_dir/page-$(safe_page_id "$candidate_id").json"
      if ! probe_page "$candidate_id" "$candidate_identity"; then
        blocked "could not prove attached browser page $candidate_id identity during candidate reconciliation: $(probe_error "$candidate_id")"
      fi
    done
  done
  verify_attached_session_binding
  STAGE=attach-evidence
  write_attached_identity "$final_identity" "$page_id" || blocked "could not publish attached browser QA evidence"
  [ -z "$OUT_DIR" ] || rm -f "$OUT_DIR/FAILED.md"
  echo "ok: selected attached browser QA page $page_id in AXI session $AXI_SESSION_NAME"
  echo "browser_url: $BROWSER_URL"
  echo "axi_session: $AXI_SESSION_NAME"
}

is_app_login_page() {
  node - "$1" "$RESOLVED_URL" <<'NODE'
const [href, target] = process.argv.slice(2);
try {
  const landed = new URL(href);
  const wanted = new URL(target);
  if (landed.host !== wanted.host) process.exit(1);
  process.exit(landed.pathname === '/login' || landed.pathname.startsWith('/login/') ? 0 : 1);
} catch {
  process.exit(1);
}
NODE
}

teacher_session_function() {
  cat <<'TEACHER_SESSION_JS'
async () => {
  const initial = { href: location.href, title: document.title };
  const proof = { status: 'unverified', reason: 'browser_state_unavailable' };
  const finish = (status, reason) => {
    proof.status = status;
    proof.reason = reason;
    if (location.href !== initial.href || document.title !== initial.title) {
      proof.status = 'unverified';
      proof.reason = 'page_changed';
    }
    return { href: location.href, title: document.title, teacher_session: proof };
  };
  try {
    const page = new URL(initial.href);
    const host = page.hostname;
    const apiHost = host === 'teachers.typing.com' ? 'api.typing.com'
      : host === 'teachers-dev.typing.com' ? 'api-dev.typing.com'
        : /^teachers-[a-z0-9-]+\.typing\.com$/.test(host) ? host.replace(/^teachers-/, 'teachers-api-') : '';
    if (page.protocol !== 'https:' || !apiHost) return finish('unverified', 'unsupported_api_configuration');
    const candidates = performance.getEntriesByType('resource').flatMap(entry => {
      try {
        const url = new URL(entry.name);
        return ['/teachers/account/self', '/teachers/globals'].includes(url.pathname) ? [url] : [];
      } catch { return []; }
    });
    if (!candidates.length) return finish('unverified', 'missing_api_configuration');
    if (candidates.some(url => url.protocol !== 'https:' || url.username || url.password || url.port || url.hostname !== apiHost)) {
      return finish('unverified', 'conflicting_api_configuration');
    }
    proof.api_origin = `https://${apiHost}`;
    const token = localStorage.getItem('teacher_jwt_token');
    if (typeof token !== 'string' || !token.trim()) return finish('unauthenticated', 'missing_token');
    const globals = window.FTWGLOBALS_BE_API;
    const languages = globals?.languages;
    const known = key => typeof key === 'string' && languages && Object.prototype.hasOwnProperty.call(languages, key);
    const stored = localStorage.getItem('tc:language');
    const segment = page.pathname.split('/')[1];
    const language = known(stored) ? stored : known(segment) ? segment : globals?.defaultLanguage ?? 'en';
    const controller = new AbortController();
    let timer;
    let response, body;
    try {
      const expired = new Promise((_, reject) => {
        timer = setTimeout(() => {
          controller.abort();
          const error = new Error(); error.name = 'AbortError'; reject(error);
        }, 5000);
      });
      const request = async () => {
        response = await fetch(`${proof.api_origin}/teachers/account/self`, {
          method: 'GET', cache: 'no-store', credentials: 'include', redirect: 'error', signal: controller.signal,
          headers: { 'Content-Type': 'application/json', Accept: 'application/json', 'x-app-site': 'typing',
            'x-language': language, Authorization: `Bearer ${token}` },
        });
        proof.http_status = response.status;
        if (response.status === 200) body = await response.json();
      };
      await Promise.race([request(), expired]);
    } catch (error) {
      return finish('unverified', error?.name === 'AbortError' ? 'request_timeout' : 'request_or_json_error');
    } finally { clearTimeout(timer); }
    if (response.status === 401) return finish('unauthenticated', 'http_401');
    if (response.status !== 200) return finish('unverified', 'unexpected_http_status');
    const data = body?.data;
    if (!data || typeof data !== 'object' || Array.isArray(data)) return finish('unverified', 'unexpected_account_schema');
    proof.principal_valid = Number.isSafeInteger(data.teacher_id) && data.teacher_id > 0;
    proof.role_valid = ['teacher', 'school_admin', 'district_admin', 'billing_admin'].includes(data.role);
    if (!proof.principal_valid) return finish('unusable', 'invalid_principal');
    if (!proof.role_valid) return finish('unusable', 'invalid_role');
    if (data.active !== 0 && data.active !== 1) return finish('unverified', 'unexpected_active_schema');
    proof.active = data.active === 1;
    if (!proof.active) return finish('unusable', 'inactive_account');
    const visible = node => node && node.getClientRects().length > 0 &&
      !['hidden', 'collapse'].includes(getComputedStyle(node).visibility) && getComputedStyle(node).display !== 'none';
    const header = document.querySelector('#root-layout header');
    proof.shell_ready = ['#root-layout', '#root-layout-main'].every(selector => visible(document.querySelector(selector))) && !!visible(header);
    if (!proof.shell_ready) return finish('unverified', 'shell_not_ready');
    if (/shared\.roles\.(?:undefined|null)\b/.test(header.innerText || '')) return finish('unusable', 'unresolved_header_role');
    const loggedOut = [...document.querySelectorAll('[data-modal-panel] h2, [role="dialog"] h2')].some(node => visible(node) &&
      /^(?:logged out|desconectado|app\.logged_out_notice_title)$/i.test((node.innerText || '').trim().replace(/\s+/g, ' ')));
    if (loggedOut) return finish('unusable', 'logged_out_dialog');
    return finish('authenticated', 'verified');
  } catch { return finish('unverified', 'browser_state_unavailable'); }
}
TEACHER_SESSION_JS
}

write_teacher_session() {
  node - "$FINAL_IDENTITY" "$PAGE_ID" "$TARGET_URL" "$RESOLVED_URL" "$OUT_DIR/teacher-session.json" <<'NODE'
const fs = require('fs');
const [file, pageId, requestedUrl, resolvedUrl, output] = process.argv.slice(2);
const identity = JSON.parse(fs.readFileSync(file, 'utf8'));
const proof = identity.teacher_session || {};
if (!['authenticated', 'unauthenticated', 'unusable', 'unverified'].includes(proof.status) ||
    (proof.status === 'authenticated' && (proof.reason !== 'verified' || proof.http_status !== 200 ||
      !['principal_valid', 'role_valid', 'active', 'shell_ready'].every(key => proof[key] === true)))) {
  proof.status = 'unverified'; proof.reason = 'unsupported_session_proof';
}
fs.writeFileSync(output, JSON.stringify({ schema: 1, page_id: pageId, requested_url: requestedUrl,
  resolved_url: resolvedUrl, active_url: identity.href, checked_at: new Date().toISOString(),
  ...proof }, null, 2) + '\n');
NODE
}

run_login_helper() {
  local login_url helper_status=0
  [ "$LOGIN_ATTEMPTED" -eq 0 ] || blocked "teacher portal auto-login was already attempted once"
  LOGIN_ATTEMPTED=1
  [ -f "$LOGIN_HELPER" ] \
    || blocked "teacher portal requires authentication but the auto-login helper is missing: $LOGIN_HELPER"
  login_url=$(node -e 'process.stdout.write(new URL(process.argv[1]).origin + "/login")' "$RESOLVED_URL") \
    || blocked "could not derive a login URL from: $RESOLVED_URL"
  echo "teacher portal requires authentication; logging in with teaching-verify credentials" >&2
  node "$LOGIN_HELPER" --browser-url "$BROWSER_URL" --login-url "$login_url" \
    > "$TMP_DIR/login-helper.out" 2> "$TMP_DIR/login-helper.err" || helper_status=$?
  case "$helper_status" in
    0)
      AUTH_CHECK_MODE=cloudflare-only
      append_warning "auto-logged in to $login_url with teaching-verify credentials"
      ;;
    3)
      auth_blocked
      ;;
    *)
      blocked "teacher portal auto-login failed (exit $helper_status): $(stream_detail "$TMP_DIR/login-helper.err" "$TMP_DIR/login-helper.out")"
      ;;
  esac
}

record_navigation_identity() {
  local identity_json=$1 page_id=${2:-}
  OBSERVED_URL=$(json_field "$identity_json" href)
  printf -- '- page %s: %s - %s\n' "${page_id:-pending}" "$OBSERVED_URL" "$(json_field "$identity_json" title)" >> "$LANDED_PAGES_FILE"
  if [ "$ROOT_RESOLVED" -eq 1 ]; then
    write_identity "$identity_json" "$page_id"
  fi
}

check_navigation_auth() {
  local href=$1 title=$2
  if is_auth_blocked "$href" "$title"; then
    if [ "$TEACHER_SESSION_REQUIRED" -eq 1 ] && is_app_login_page "$href" &&
       ! is_auth_blocked "$href" "$title" cloudflare-only; then
      return 0
    fi
    auth_blocked
  fi
}

open_target_page() {
  local landing_identity=$1 existing_page_id=${2:-}
  local args tool=new_page
  if [ -n "$existing_page_id" ]; then
    if ! probe_page "$existing_page_id" "$TMP_DIR/recovery-page-identity.json"; then
      blocked "could not prove browser page $existing_page_id identity before recovery navigation: $(probe_error "$existing_page_id")"
    fi
    tool=navigate_page
  fi
  args=$(node -e 'console.log(JSON.stringify({url: process.argv[1], ...(process.argv[2] === "navigate_page" ? {type: "url"} : {})}))' "$RESOLVED_URL" "$tool")
  if ! mcp_call "$tool" "$args" > "$TMP_DIR/newpage.out" 2> "$TMP_DIR/newpage.err"; then
    blocked "could not open exact QA URL in authenticated browser: $(stream_detail "$TMP_DIR/newpage.err" "$TMP_DIR/newpage.out")"
  fi
  sleep "${FM_BROWSER_QA_OPEN_SETTLE:-1}"
  if ! mcp_call evaluate_script '{"function":"() => ({href: location.href, title: document.title})"}' > "$TMP_DIR/newpage-eval.out" 2> "$TMP_DIR/newpage-eval.err"; then
    blocked "could not prove browser landing page identity: $(stream_detail "$TMP_DIR/newpage-eval.err" "$TMP_DIR/newpage-eval.out")"
  fi
  if ! parse_eval_identity "$TMP_DIR/newpage-eval.out" "$landing_identity" 2> "$TMP_DIR/newpage-parse.err"; then
    blocked "could not prove browser landing page identity: $(stream_detail "$TMP_DIR/newpage-parse.err" "$TMP_DIR/newpage-eval.out")"
  fi
}

NORM_TARGET_URL=$RESOLVED_URL

if [ "$MODE" = select ]; then
  STAGE=attach-session
  if ! axi start > "$TMP_DIR/attach-start.out" 2> "$TMP_DIR/attach-start.err"; then
    blocked "could not start attached AXI session: $(stream_detail "$TMP_DIR/attach-start.err" "$TMP_DIR/attach-start.out")"
  fi
  verify_attached_session_binding capture
  ATTACH_BINDING_READY=1
  select_attached_identity_page
  STAGE="done"
  exit 0
fi

STAGE=page-scan
SCAN_DIR="$TMP_DIR/scan-initial"
INITIAL_SCAN_DIR=$SCAN_DIR
INITIAL_IDS=$(list_page_ids initial)
scan_pages "$SCAN_DIR" "$INITIAL_IDS" tolerate
MATCHES="$SCAN_DIR/matches.tsv"
MATCH_COUNT=$(count_lines "$MATCHES")

navigate_target_page() {
  local existing_page_id=${1:-}
  LANDING_IDS=
  LANDING_IDENTITY="$TMP_DIR/newpage-identity.json"
  open_target_page "$LANDING_IDENTITY" "$existing_page_id"
  record_navigation_identity "$LANDING_IDENTITY"
  if is_auth_blocked "$(json_field "$LANDING_IDENTITY" href)" "$(json_field "$LANDING_IDENTITY" title)"; then
    check_navigation_auth "$(json_field "$LANDING_IDENTITY" href)" "$(json_field "$LANDING_IDENTITY" title)"
  fi
  POST_IDS=$(list_page_ids after-open)
  if ! LANDING_PAGE_ID=$(landing_page_id "$LANDING_IDENTITY"); then
    if ! mcp_call evaluate_script '{"function":"() => ({href: location.href, title: document.title})"}' > "$TMP_DIR/newpage-eval.out" 2> "$TMP_DIR/newpage-eval.err" ||
       ! parse_eval_identity "$TMP_DIR/newpage-eval.out" "$LANDING_IDENTITY" 2> "$TMP_DIR/newpage-parse.err"; then
      blocked "could not prove browser landing page identity: $(stream_detail "$TMP_DIR/newpage-eval.err" "$TMP_DIR/newpage-parse.err")"
    fi
    if is_auth_blocked "$(json_field "$LANDING_IDENTITY" href)" "$(json_field "$LANDING_IDENTITY" title)"; then
      record_navigation_identity "$LANDING_IDENTITY"
      check_navigation_auth "$(json_field "$LANDING_IDENTITY" href)" "$(json_field "$LANDING_IDENTITY" title)"
    fi
    POST_IDS=$(list_page_ids after-open)
    if ! LANDING_PAGE_ID=$(landing_page_id "$LANDING_IDENTITY"); then
      blocked "could not prove browser landing page identity: $(stream_detail "$TMP_DIR/pages-after-open.err" "$TMP_DIR/pages-after-open.txt")"
    fi
  fi
  if [ -n "$existing_page_id" ] && [ "$LANDING_PAGE_ID" != "$existing_page_id" ]; then
    blocked "browser page changed during recovery navigation: expected $existing_page_id got $LANDING_PAGE_ID"
  fi
  AUTHORITATIVE_IDENTITY="$TMP_DIR/newpage-authoritative-identity.json"
  if ! probe_page "$LANDING_PAGE_ID" "$AUTHORITATIVE_IDENTITY"; then
    blocked "could not prove browser page $LANDING_PAGE_ID identity: $(probe_error "$LANDING_PAGE_ID")"
  fi
  AUTHORITATIVE_HREF=$(json_field "$AUTHORITATIVE_IDENTITY" href)
  AUTHORITATIVE_TITLE=$(json_field "$AUTHORITATIVE_IDENTITY" title)
  record_navigation_identity "$AUTHORITATIVE_IDENTITY" "$LANDING_PAGE_ID"
  if is_auth_blocked "$AUTHORITATIVE_HREF" "$AUTHORITATIVE_TITLE"; then
    check_navigation_auth "$AUTHORITATIVE_HREF" "$AUTHORITATIVE_TITLE"
  fi
  for page_id in $POST_IDS; do
    if [ "$page_id" = "$LANDING_PAGE_ID" ]; then
      post_identity="$TMP_DIR/post-open-page-$(safe_page_id "$page_id").json"
      if probe_page "$page_id" "$post_identity"; then
        post_href=$(json_field "$post_identity" href)
        post_title=$(json_field "$post_identity" title)
        record_navigation_identity "$post_identity" "$page_id"
        if is_auth_blocked "$post_href" "$post_title"; then
          check_navigation_auth "$post_href" "$post_title"
        fi
        if [ "$post_href" = "$NORM_TARGET_URL" ]; then
          AUTHORITATIVE_IDENTITY=$post_identity
          AUTHORITATIVE_HREF=$post_href
          AUTHORITATIVE_TITLE=$post_title
        fi
      fi
      continue
    fi
    if [ -n "$existing_page_id" ]; then
      LANDING_IDS="$LANDING_IDS $page_id"
      continue
    fi
    known=0
    for known_id in $INITIAL_IDS; do
      if [ "$page_id" = "$known_id" ]; then
        known=1
        break
      fi
    done
    if [ "$known" -eq 0 ]; then
      LANDING_IDS="$LANDING_IDS $page_id"
      continue
    fi
    initial_identity="$INITIAL_SCAN_DIR/page-$(safe_page_id "$page_id").json"
    [ -f "$initial_identity" ] || continue
    post_identity="$TMP_DIR/post-open-page-$(safe_page_id "$page_id").json"
    if ! probe_page "$page_id" "$post_identity"; then
      continue
    fi
    initial_href=$(json_field "$initial_identity" href)
    initial_title=$(json_field "$initial_identity" title)
    post_href=$(json_field "$post_identity" href)
    post_title=$(json_field "$post_identity" title)
    if [ "$post_href" != "$initial_href" ] || [ "$post_title" != "$initial_title" ]; then
      LANDING_IDS="$LANDING_IDS $page_id"
    fi
  done
  FALLBACK_IDS=
  for page_id in $LANDING_IDS; do
    if [ "$page_id" != "$LANDING_PAGE_ID" ]; then
      FALLBACK_IDS="$FALLBACK_IDS $page_id"
    fi
  done
  SCAN_DIR="$TMP_DIR/scan-after-open"
  scan_pages "$SCAN_DIR" "$FALLBACK_IDS" tolerate
  MATCHES="$SCAN_DIR/matches.tsv"
  if [ -n "$existing_page_id" ] && [ "$AUTHORITATIVE_HREF" != "$NORM_TARGET_URL" ]; then
    blocked "login helper returned success, but navigation verification failed: $RESOLVED_URL"
  fi
  if [ "$AUTHORITATIVE_HREF" = "$NORM_TARGET_URL" ]; then
    printf '%s\t%s\n' "$LANDING_PAGE_ID" "$AUTHORITATIVE_IDENTITY" >> "$MATCHES"
  fi
  MATCH_COUNT=$(count_lines "$MATCHES")
}

if [ "$MATCH_COUNT" -eq 0 ]; then
  navigate_target_page
  if [ "$MATCH_COUNT" -eq 0 ] && is_app_login_page "$AUTHORITATIVE_HREF" &&
     [ "$TEACHER_SESSION_REQUIRED" -eq 1 ]; then
    STAGE=auto-login
    run_login_helper
    STAGE=page-scan
    INITIAL_SCAN_DIR="$TMP_DIR/scan-before-login-retry"
    INITIAL_IDS=$(list_page_ids before-login-retry)
    scan_pages "$INITIAL_SCAN_DIR" "$INITIAL_IDS" tolerate
    navigate_target_page
  fi
  if [ "$MATCH_COUNT" -eq 0 ]; then
    if [ "$AUTH_CHECK_MODE" = cloudflare-only ]; then
      blocked "exact QA URL is not open after teacher portal auto-login; login helper returned success, but navigation verification failed: $RESOLVED_URL"
    fi
    blocked "exact QA URL is not open after navigation: $RESOLVED_URL"
  fi
fi

if [ "$MATCH_COUNT" -gt 1 ]; then
  blocked "multiple tabs match the exact QA URL; close duplicates and retry: $RESOLVED_URL"
fi

verify_final_identity() {
  MATCH_LINE=$(sed -n '1p' "$MATCHES")
  PAGE_ID=$(printf '%s\n' "$MATCH_LINE" | cut -f1)
  FINAL_IDENTITY="$TMP_DIR/final-identity.json"
  if ! probe_page "$PAGE_ID" "$FINAL_IDENTITY" "${1:-}"; then
    blocked "could not prove browser page $PAGE_ID identity: $(probe_error "$PAGE_ID")"
  fi
  FINAL_HREF=$(json_field "$FINAL_IDENTITY" href)
  FINAL_TITLE=$(json_field "$FINAL_IDENTITY" title)
  OBSERVED_URL=$FINAL_HREF
  write_identity "$FINAL_IDENTITY" "$PAGE_ID"

  if is_auth_blocked "$FINAL_HREF" "$FINAL_TITLE"; then
    auth_blocked
  fi

  if [ "$AUTH_CHECK_MODE" = cloudflare-only ] && is_auth_blocked "$FINAL_HREF" "$FINAL_TITLE" all; then
    blocked "login helper returned success, but the selected page still requires sign-in; navigation verification failed: $FINAL_HREF"
  fi

  if [ "$FINAL_HREF" != "$RESOLVED_URL" ]; then
    if [ "$AUTH_CHECK_MODE" = cloudflare-only ]; then
      blocked "selected browser tab URL mismatch; login helper returned success, but navigation verification failed: expected $RESOLVED_URL got $FINAL_HREF"
    fi
    blocked "selected browser tab URL mismatch: expected $RESOLVED_URL got $FINAL_HREF"
  fi
}

STAGE=identity
verify_final_identity

if [ "$TEACHER_SESSION_REQUIRED" -eq 1 ]; then
  SESSION_ARGS=$(teacher_session_function | node -e 'let functionText=""; process.stdin.on("data", chunk => functionText += chunk); process.stdin.on("end", () => console.log(JSON.stringify({function:functionText})))')
  while :; do
    STAGE=teacher-session
    verify_final_identity "$SESSION_ARGS"
    write_teacher_session
    SESSION_STATUS=$(json_field "$OUT_DIR/teacher-session.json" status)
    SESSION_REASON=$(json_field "$OUT_DIR/teacher-session.json" reason)
    case "$SESSION_STATUS" in
      authenticated) break ;;
      unauthenticated)
        if [ "$LOGIN_ATTEMPTED" -eq 0 ]; then
          STAGE=auto-login
          run_login_helper
          STAGE=page-scan
          INITIAL_SCAN_DIR="$TMP_DIR/scan-before-session-login"
          INITIAL_IDS=$(list_page_ids before-session-login)
          scan_pages "$INITIAL_SCAN_DIR" "$INITIAL_IDS" tolerate
          navigate_target_page "$PAGE_ID"
          [ "$MATCH_COUNT" -gt 0 ] || blocked "login helper returned success, but navigation verification failed: $RESOLVED_URL"
          [ "$MATCH_COUNT" -eq 1 ] || blocked "multiple tabs match the exact QA URL after teacher portal auto-login: $RESOLVED_URL"
          STAGE=identity
          verify_final_identity
          continue
        fi
        ;;
    esac
    HELPER_DETAIL=
    [ "$LOGIN_ATTEMPTED" -eq 0 ] || HELPER_DETAIL="login helper returned success, but "
    blocked "${HELPER_DETAIL}usable teacher session verification failed ($SESSION_STATUS: $SESSION_REASON); see teacher-session.json"
  done
fi

STAGE=snapshot
if ! axi snapshot > "$OUT_DIR/snapshot.txt" 2> "$TMP_DIR/snapshot.err"; then
  blocked "snapshot evidence failed: $(stream_detail "$TMP_DIR/snapshot.err" "$OUT_DIR/snapshot.txt")"
fi
[ -s "$OUT_DIR/snapshot.txt" ] || blocked "snapshot evidence was empty: $(stream_detail "$TMP_DIR/snapshot.err")"

STAGE=screenshot
MCP_OUTPUT_DIR=$(mktemp -d "/tmp/fm-browser-qa-mcp.XXXXXX") \
  || blocked "could not create MCP-compatible screenshot staging directory"
SCREENSHOT_TMP="$MCP_OUTPUT_DIR/screenshot.png"
if ! axi screenshot "$SCREENSHOT_TMP" > "$TMP_DIR/screenshot.out" 2> "$TMP_DIR/screenshot.err"; then
  blocked "screenshot evidence failed: $(stream_detail "$TMP_DIR/screenshot.err" "$TMP_DIR/screenshot.out")"
fi
# axi can exit 0 without producing the file, and it echoes the path it resolved,
# so surface both streams here rather than reporting a bare "was empty".
[ -s "$SCREENSHOT_TMP" ] || blocked "screenshot evidence was empty: $(stream_detail "$TMP_DIR/screenshot.out" "$TMP_DIR/screenshot.err")"
cp "$SCREENSHOT_TMP" "$OUT_DIR/screenshot.png" \
  || blocked "could not publish screenshot evidence: $OUT_DIR/screenshot.png"
[ -s "$OUT_DIR/screenshot.png" ] || blocked "published screenshot evidence was empty: $OUT_DIR/screenshot.png"

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
  echo "- Requested URL: $TARGET_URL"
  echo "- Resolved URL: $RESOLVED_URL"
  echo "- Active URL: $FINAL_HREF"
  echo "- Title: $FINAL_TITLE"
  echo "- Page ID: $PAGE_ID"
  if [ -f "$OUT_DIR/teacher-session.json" ]; then
    echo "- Teacher session: authenticated, active account and usable portal shell verified"
  fi
  echo "- Browser endpoint: $BROWSER_URL"
  echo "- Logical evidence session: $LOGICAL_SESSION_NAME"
  echo "- AXI bridge session: $AXI_SESSION_NAME"
  echo
  echo "## Evidence"
  echo
  echo "- identity.json"
  [ ! -f "$OUT_DIR/teacher-session.json" ] || echo "- teacher-session.json"
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
