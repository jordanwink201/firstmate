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
# Diagnostics: blocked runs leave FAILED.md after the evidence directory exists,
# and every exit best-effort appends JSONL to FM_BROWSER_QA_LEDGER or the default
# $HOME/.local/share/fm-browser-qa/runs.jsonl when either path is available.
# Usage:
#   fm-browser-qa.sh --url <exact-url> --out <dir> [--browser-url <url>] [--session <name>] [--start-if-needed]
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
OUT_DIR=
BROWSER_URL=http://127.0.0.1:9222
SESSION_INPUT=
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
# chrome-devtools-mcp 1.8.0 requires pageId while AXI still relies on selected-page state.
# Remove this pin after AXI sends pageId or supports disabling page-id routing.
MCP_COMPAT_VERSION=1.7.0

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

curl_timeout_valid() {
  node - "$1" <<'NODE' >/dev/null 2>&1 || return 1
const raw = process.argv[2];
const syntax = /^\+?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?$/i;
const value = Number(raw);
process.exit(syntax.test(raw) && Number.isFinite(value) && value >= 0.001 ? 0 : 1);
NODE
  curl --silent --show-error --max-time "$1" --version >/dev/null 2>&1
}

axi() (
  unset CHROME_DEVTOOLS_AXI_PORT
  export CHROME_DEVTOOLS_AXI_SESSION="$AXI_SESSION_NAME"
  export CHROME_DEVTOOLS_AXI_BROWSER_URL="$BROWSER_URL"
  chrome-devtools-axi "$@"
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
  local LC_ALL=C status=$1 dir ts_json stage_json reason_json url_json out_json session_json axi_json
  [ -n "$LEDGER_FILE" ] || return 0
  dir=$(dirname "$LEDGER_FILE")
  mkdir -p "$dir" >/dev/null 2>&1 || return 0
  json_quote "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; ts_json=$JSON_RESULT
  json_quote "$STAGE"; stage_json=$JSON_RESULT
  json_nullable "$BLOCK_REASON"; reason_json=$JSON_RESULT
  json_nullable "$TARGET_URL"; url_json=$JSON_RESULT
  json_nullable "$OUT_DIR"; out_json=$JSON_RESULT
  json_nullable "$LOGICAL_SESSION_NAME"; session_json=$JSON_RESULT
  json_nullable "$AXI_SESSION_NAME"; axi_json=$JSON_RESULT
  printf '{"ts":%s,"status":%s,"stage":%s,"reason":%s,"url":%s,"out_dir":%s,"session":%s,"axi_session":%s}\n' \
    "$ts_json" "$status" "$stage_json" "$reason_json" "$url_json" "$out_json" "$session_json" "$axi_json" \
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
  if [ -n "$AXI_SESSION_NAME" ]; then
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
curl_timeout_valid "$CURL_TIMEOUT" || CURL_TIMEOUT=2

BROWSER_URL=${BROWSER_URL%/}
mkdir -p "$OUT_DIR" || blocked "could not create evidence directory: $OUT_DIR"

if [ -n "$SESSION_INPUT" ]; then
  LOGICAL_SESSION_NAME="fmqa-$(sanitize_token "$SESSION_INPUT")"
else
  LOGICAL_SESSION_NAME="fmqa-$(sanitize_token "$(basename "$OUT_DIR")")"
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-browser-qa.XXXXXX")
WARNINGS_FILE="$TMP_DIR/warnings.txt"
: > "$WARNINGS_FILE"

target_reachable() {
  curl --fail -sS --max-time "$CURL_TIMEOUT" --output /dev/null "$TARGET_URL" >/dev/null 2>&1
}

STAGE=target-reachability
target_reachable \
  || blocked "target host is unreachable; likely torn-down feature branch for exact QA URL: $TARGET_URL"

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
AXI_SESSION_NAME="fmqa-$(sanitize_token "$(basename "$TMP_DIR")")"
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

selected_page_id() {
  awk '
    /^[[:space:]]*[A-Za-z0-9_.-]+,/ && /,true[[:space:]]*$/ {
      gsub(/^[[:space:]]*/, "", $0)
      sub(/,.*/, "", $0)
      selected = $0
      count++
    }
    END {
      if (count != 1) exit 1
      print selected
    }
  ' "$1"
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
  local landing_identity=$1
  if ! axi newpage "$TARGET_URL" > "$TMP_DIR/newpage.out" 2> "$TMP_DIR/newpage.err"; then
    blocked "could not open exact QA URL in authenticated browser: $(stream_detail "$TMP_DIR/newpage.err" "$TMP_DIR/newpage.out")"
  fi
  sleep "${FM_BROWSER_QA_OPEN_SETTLE:-1}"
  if ! axi eval '({href: location.href, title: document.title})' > "$TMP_DIR/newpage-eval.out" 2> "$TMP_DIR/newpage-eval.err"; then
    blocked "could not prove browser landing page identity: $(stream_detail "$TMP_DIR/newpage-eval.err" "$TMP_DIR/newpage-eval.out")"
  fi
  if ! parse_eval_identity "$TMP_DIR/newpage-eval.out" "$landing_identity" 2> "$TMP_DIR/newpage-parse.err"; then
    blocked "could not prove browser landing page identity: $(stream_detail "$TMP_DIR/newpage-parse.err" "$TMP_DIR/newpage-eval.out")"
  fi
}

NORM_TARGET_URL=$(normalize_url "$TARGET_URL")

STAGE=page-scan
SCAN_DIR="$TMP_DIR/scan-initial"
INITIAL_SCAN_DIR=$SCAN_DIR
INITIAL_IDS=$(list_page_ids initial)
scan_pages "$SCAN_DIR" "$INITIAL_IDS" tolerate
MATCHES="$SCAN_DIR/matches.tsv"
MATCH_COUNT=$(count_lines "$MATCHES")

if [ "$MATCH_COUNT" -eq 0 ]; then
  LANDING_IDS=
  LANDING_IDENTITY="$TMP_DIR/newpage-identity.json"
  open_target_page "$LANDING_IDENTITY"
  if is_auth_blocked "$(json_field "$LANDING_IDENTITY" href)" "$(json_field "$LANDING_IDENTITY" title)"; then
    auth_blocked
  fi
  POST_IDS=$(list_page_ids after-open)
  if ! LANDING_PAGE_ID=$(selected_page_id "$TMP_DIR/pages-after-open.txt"); then
    blocked "could not prove browser landing page identity: $(stream_detail "$TMP_DIR/pages-after-open.err" "$TMP_DIR/pages-after-open.txt")"
  fi
  for page_id in $POST_IDS; do
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
  SCAN_DIR="$TMP_DIR/scan-after-open"
  scan_pages "$SCAN_DIR" "$LANDING_IDS" strict
  MATCHES="$SCAN_DIR/matches.tsv"
  MATCH_COUNT=$(count_lines "$MATCHES")
  if [ "$MATCH_COUNT" -eq 0 ]; then
    AUTHORITATIVE_IDENTITY="$TMP_DIR/newpage-authoritative-identity.json"
    if ! probe_page "$LANDING_PAGE_ID" "$AUTHORITATIVE_IDENTITY"; then
      blocked "could not prove browser page $LANDING_PAGE_ID identity: $(probe_error "$LANDING_PAGE_ID")"
    fi
    if is_auth_blocked "$(json_field "$AUTHORITATIVE_IDENTITY" href)" "$(json_field "$AUTHORITATIVE_IDENTITY" title)"; then
      auth_blocked
    fi
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
