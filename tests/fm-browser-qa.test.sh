#!/usr/bin/env bash
# Behavior tests for bin/fm-browser-qa.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-browser-qa)
REAL_NODE=$(command -v node || true)
REAL_CURL=$(command -v curl || true)
REAL_AXI_BIN=$(command -v chrome-devtools-axi || true)
REAL_MCP_RESPONSE=${FM_TEST_REAL_MCP_RESPONSE:-${HOME:-}/.local/share/fm-browser-qa/chrome-devtools-mcp-1.7.0/node_modules/chrome-devtools-mcp/build/src/McpResponse.js}

[ -n "$REAL_NODE" ] || fail "node is required for fm-browser-qa tests"
[ -n "$REAL_CURL" ] || fail "curl is required for fm-browser-qa tests"
export FM_REAL_CURL=$REAL_CURL

make_fake_browser_tools() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")

  cat > "$fakebin/node" <<SH
#!/usr/bin/env bash
exec "$REAL_NODE" "\$@"
SH
  chmod +x "$fakebin/node"

  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
url=${*: -1}
fail_http=0
max_time=
previous=
for arg in "$@"; do
  case "$arg" in
    -f|--fail|--fail-with-body) fail_http=1 ;;
  esac
  if [ "$previous" = "--max-time" ]; then
    max_time=$arg
  fi
  previous=$arg
done
if [ "$url" = "--version" ]; then
  exec "$FM_REAL_CURL" "$@"
fi
if [ -e "$FM_FAKE_BROWSER_DIR/curl_timeout.log" ]; then
  printf '%s\n' "$max_time" >> "$FM_FAKE_BROWSER_DIR/curl_timeout.log"
fi
if [ -e "$FM_FAKE_BROWSER_DIR/curl.log" ]; then
  printf '%s\n' "$url" >> "$FM_FAKE_BROWSER_DIR/curl.log"
fi
case "$url" in
  */json/version)
    [ ! -e "$FM_FAKE_BROWSER_DIR/browser_down" ] || exit 7
    ;;
  *)
    [ ! -e "$FM_FAKE_BROWSER_DIR/target_down" ] || exit 7
    if [ -e "$FM_FAKE_BROWSER_DIR/target_http_error" ] && [ "$fail_http" -eq 1 ]; then
      exit 22
    fi
    ;;
esac
if [ -e "$FM_FAKE_BROWSER_DIR/curl_fail" ]; then
  exit 7
fi
printf '{"Browser":"fake"}\n'
SH
  chmod +x "$fakebin/curl"

  cat > "$fakebin/open" <<'SH'
#!/usr/bin/env bash
mkdir -p "$FM_FAKE_BROWSER_DIR"
printf '%s\n' "$*" >> "$FM_FAKE_BROWSER_DIR/open.log"
rm -f "$FM_FAKE_BROWSER_DIR/browser_down"
exit 0
SH
  chmod +x "$fakebin/open"

  cat > "$fakebin/osascript" <<'SH'
#!/usr/bin/env bash
mkdir -p "$FM_FAKE_BROWSER_DIR"
printf '%s\n' "$*" >> "$FM_FAKE_BROWSER_DIR/osascript.log"
exit 0
SH
  chmod +x "$fakebin/osascript"

  cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_FAKE_BROWSER_DIR/lsof.out" ]; then
  cat "$FM_FAKE_BROWSER_DIR/lsof.out"
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/lsof"

  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "eww" ]; then
  if [ -e "$FM_FAKE_BROWSER_DIR/inspect_real_bridge" ]; then
    exec /bin/ps "$@"
  fi
  cat "$FM_FAKE_BROWSER_DIR/bridge-process.out"
  exit
fi
if [ "${1:-}" = "-p" ]; then
  pid=${2:?}
  if [ -f "$FM_FAKE_BROWSER_DIR/ps_$pid.out" ]; then
    cat "$FM_FAKE_BROWSER_DIR/ps_$pid.out"
    exit 0
  fi
fi
exec /bin/ps "$@"
SH
  chmod +x "$fakebin/ps"

  "$REAL_NODE" - "$dir/axi-runtime" "$ROOT/tests/fixtures/fm-browser-qa-axi.mjs" <<'NODE'
const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');
const [root, fixture] = process.argv.slice(2);
fs.mkdirSync(path.join(root, 'dist/bin'), { recursive: true });
fs.mkdirSync(path.join(root, 'dist/src'), { recursive: true });
fs.writeFileSync(path.join(root, 'package.json'), JSON.stringify({ type: 'module' }));
const source = JSON.stringify(pathToFileURL(fixture).href);
fs.writeFileSync(path.join(root, 'dist/bin/chrome-devtools-axi.js'), `import { run } from ${source}; await run();\n`);
fs.writeFileSync(path.join(root, 'dist/src/client.js'), `export { callTool, ensureBridge } from ${source};\n`);
NODE

  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
set -eu

dir=${FM_FAKE_BROWSER_DIR:?}
cmd=${1:-}
inventory_mode=$cmd
if [ "$cmd" = run ]; then
  exec node "$dir/../axi-runtime/dist/bin/chrome-devtools-axi.js" run
fi
[ "$cmd" != raw-pages ] || cmd=pages
shift || true
mkdir -p "$dir"
printf '%s\t%s\t%s\t%s\n' "$cmd" "${CHROME_DEVTOOLS_AXI_SESSION:-}" "${CHROME_DEVTOOLS_AXI_BROWSER_URL:-}" "${CHROME_DEVTOOLS_AXI_MCP_PATH:-}" >> "$dir/axi.log"

next_id() {
  local max=0 id
  for file in "$dir"/page_*; do
    [ -e "$file" ] || continue
    id=${file##*/page_}
    case "$id" in
      *[!0-9]*|'') ;;
      *) [ "$id" -gt "$max" ] && max=$id ;;
    esac
  done
  printf '%s\n' "$((max + 1))"
}

page_file() {
  printf '%s/page_%s\n' "$dir" "$1"
}

page_href() {
  cut -f1 "$(page_file "$1")"
}

page_title() {
  cut -f2- "$(page_file "$1")"
}

if [ -f "$dir/reconnect_mcp_before" ]; then
  read -r reconnect_command reconnect_count < "$dir/reconnect_mcp_before"
  if [ "$cmd" = "$reconnect_command" ]; then
    command_count=0
    [ ! -f "$dir/reconnect_command_count" ] || command_count=$(cat "$dir/reconnect_command_count")
    command_count=$((command_count + 1))
    printf '%s\n' "$command_count" > "$dir/reconnect_command_count"
    if [ "$command_count" -eq "$reconnect_count" ]; then
      state_dir="$HOME/.chrome-devtools-axi/sessions/${CHROME_DEVTOOLS_AXI_SESSION:-default}"
      if [ -f "$state_dir/bridge.pid" ]; then
        cp "$state_dir/bridge.pid" "$dir/bridge-before-mcp-reconnect.json"
      fi
      cp "$dir/page_7" "$dir/page_1"
      printf 'https://teachers.example.test/dashboard\tDashboard\n' > "$dir/page_7"
      printf '1\n' > "$dir/selected"
      : > "$dir/mcp_reconnected"
      : > "$dir/mcp_reconnect_notice"
    fi
  fi
fi

case "$cmd" in
  start)
    state_dir="$HOME/.chrome-devtools-axi"
    if [ "${CHROME_DEVTOOLS_AXI_SESSION:-default}" != default ]; then
      state_dir="$state_dir/sessions/$CHROME_DEVTOOLS_AXI_SESSION"
    fi
    mkdir -p "$state_dir"
    if [ ! -e "$state_dir/bridge.pid" ]; then
      printf '{"pid":42420,"port":9666}\n' > "$state_dir/bridge.pid"
      printf 'node /axi/chrome-devtools-axi-bridge.js CHROME_DEVTOOLS_AXI_SESSION=%s CHROME_DEVTOOLS_AXI_PORT=9666 CHROME_DEVTOOLS_AXI_BROWSER_URL=%s CHROME_DEVTOOLS_AXI_AUTO_CONNECT=%s\n' \
        "$CHROME_DEVTOOLS_AXI_SESSION" "$CHROME_DEVTOOLS_AXI_BROWSER_URL" "${CHROME_DEVTOOLS_AXI_AUTO_CONNECT:-}" > "$dir/bridge-process.out"
    fi
    printf 'status: ready\nport: 9666\n'
    ;;
  pages)
    node "$dir/../axi-runtime/dist/bin/chrome-devtools-axi.js" "$inventory_mode"
    ;;
  selectpage)
    id=${1:?}
    [ -e "$(page_file "$id")" ] || { echo "no such page: $id" >&2; exit 1; }
    if [ -e "$dir/unprobeable_once_$id" ]; then
      rm -f "$dir/unprobeable_once_$id"
      echo "cannot attach to page $id" >&2
      exit 1
    fi
    if [ -e "$dir/unprobeable_$id" ]; then
      echo "cannot attach to page $id" >&2
      exit 1
    fi
    printf '%s\n' "$id" > "$dir/selected"
    printf 'page:\n  title: %s\n' "$(page_title "$id")"
    ;;
  eval)
    id=$(cat "$dir/selected")
    [ -n "$id" ] || { echo "no selected page" >&2; exit 1; }
    count_file="$dir/eval_count_$id"
    count=0
    [ -e "$count_file" ] && count=$(cat "$count_file")
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file"
    href=$(page_href "$id")
    title=$(page_title "$id")
    if [ -e "$dir/mismatch_on_final" ] && [ "$count" -gt 1 ]; then
      href="https://example.test/wrong"
      printf '%s\t%s\n' "$href" "$title" > "$(page_file "$id")"
    fi
    expr=${1:?}
    node - "$href" "$title" "$expr" <<'NODE'
const [href, title, expr] = process.argv.slice(2);
const location = { href };
const document = { title };
const value = eval(expr);
// Match real chrome-devtools-axi output: the eval value is stringified twice.
process.stdout.write(`result: ${JSON.stringify(JSON.stringify(value))}\n`);
NODE
    if [ -e "$dir/delayed_redirect_$id" ]; then
      IFS='	' read -r redirect_count redirect_href redirect_title < "$dir/delayed_redirect_$id"
      if [ "$count" -eq "$redirect_count" ]; then
        printf '%s\t%s\n' "$redirect_href" "$redirect_title" > "$(page_file "$id")"
      fi
    fi
    if [ -f "$dir/switch_selection_after_eval" ]; then
      read -r probe_id probe_count selected_id < "$dir/switch_selection_after_eval"
      if [ "$id" = "$probe_id" ] && [ "$count" -eq "$probe_count" ]; then
        if [ -e "$dir/copy_identity_on_selection_switch" ]; then
          cp "$(page_file "$id")" "$(page_file "$selected_id")"
        fi
        printf '%s\n' "$selected_id" > "$dir/selected"
        : > "$dir/selection_switched"
      fi
    fi
    ;;
  newpage)
    url=${1:?}
    : > "$dir/newpage_started"
    if [ -e "$dir/newpage_redirect" ]; then
      IFS='	' read -r href title < "$dir/newpage_redirect"
    else
      href=$url
      title=${FM_FAKE_BROWSER_TITLE:-QA Target}
    fi
    if [ -e "$dir/newpage_reuses_page" ]; then
      id=$(cat "$dir/newpage_reuses_page")
    else
      id=$(next_id)
    fi
    printf '%s\t%s\n' "$href" "$title" > "$(page_file "$id")"
    printf '%s\n' "$id" > "$dir/selected"
    if [ -e "$dir/newpage_mutates_page" ]; then
      IFS='	' read -r mutate_id mutate_href mutate_title < "$dir/newpage_mutates_page"
      printf '%s\t%s\n' "$mutate_href" "$mutate_title" > "$(page_file "$mutate_id")"
    fi
    printf '%s\n' "$url" >> "$dir/newpage.log"
    printf 'page:\n  title: %s\n' "$title"
    ;;
  snapshot)
    if [ -n "${FM_FAKE_SNAPSHOT_DELAY:-}" ]; then
      : > "$dir/snapshot_started"
      sleep "$FM_FAKE_SNAPSHOT_DELAY"
    fi
    if [ -e "$dir/snapshot_fail" ]; then
      echo "snapshot exploded" >&2
      exit 1
    fi
    printf 'snapshot for %s\n' "$(cat "$dir/selected")"
    ;;
  screenshot)
    path=${1:?}
    printf '%s\n' "$path" >> "$dir/screenshot-path.log"
    if [ -e "$dir/screenshot_fail" ]; then
      echo "screenshot exploded" >&2
      exit 1
    fi
    if [ -e "$dir/screenshot_temp_only" ]; then
      case "$path" in
        /tmp/fm-browser-qa-mcp.*/*) ;;
        *)
          printf 'screenshot: %s\n' "$path"
          exit 0
          ;;
      esac
    fi
    printf 'fake png\n' > "$path"
    ;;
  console)
    if [ -e "$dir/console_fail" ]; then
      echo "console exploded" >&2
      exit 1
    fi
    printf 'console ok\n'
    ;;
  network)
    if [ -e "$dir/network_fail" ]; then
      echo "network exploded" >&2
      exit 1
    fi
    printf 'network ok\n'
    ;;
  stop)
    : > "$dir/axi_stopped"
    if [ -e "$dir/stop_fail" ]; then
      echo "stop exploded" >&2
      exit 1
    fi
    printf 'stopped\n'
    ;;
  *)
    echo "unexpected chrome-devtools-axi command: $cmd" >&2
    exit 1
    ;;
esac
if [ -f "$dir/replace_bridge_at" ]; then
  read -r replacement_command replacement_count < "$dir/replace_bridge_at"
  if [ "$cmd" = "$replacement_command" ]; then
    command_count=0
    [ ! -f "$dir/replacement_command_count" ] || command_count=$(cat "$dir/replacement_command_count")
    command_count=$((command_count + 1))
    printf '%s\n' "$command_count" > "$dir/replacement_command_count"
    if [ "$command_count" -eq "$replacement_count" ]; then
      state_dir="$HOME/.chrome-devtools-axi"
      if [ "${CHROME_DEVTOOLS_AXI_SESSION:-default}" != default ]; then
        state_dir="$state_dir/sessions/$CHROME_DEVTOOLS_AXI_SESSION"
      fi
      printf '{"pid":42430,"port":9666}\n' > "$state_dir/bridge.pid"
      cp "$dir/page_7" "$dir/page_2"
      printf 'https://teachers.example.test/dashboard\tDashboard\n' > "$dir/page_1"
      cp "$dir/page_1" "$dir/page_7"
      printf '1\n' > "$dir/selected"
      : > "$dir/bridge_replaced"
      printf 'bridge-replaced\n' >> "$dir/axi.log"
    fi
  fi
fi
SH
  chmod +x "$fakebin/chrome-devtools-axi"

  printf '%s\n' "$fakebin"
}

write_page() {
  local dir=$1 id=$2 href=$3 title=$4
  mkdir -p "$dir"
  printf '%s\t%s\n' "$href" "$title" > "$dir/page_$id"
}

write_identity_json() {
  local file=$1 page_id=$2 active_url=$3 title=$4 browser_url=${5:-http://127.0.0.1:9222}
  mkdir -p "$(dirname "$file")"
  "$REAL_NODE" - "$file" "$page_id" "$active_url" "$title" "$browser_url" <<'NODE'
const fs = require('fs');
const [file, pageId, activeUrl, title, browserUrl] = process.argv.slice(2);
fs.writeFileSync(file, JSON.stringify({
  page_id: pageId,
  requested_url: activeUrl,
  active_url: activeUrl,
  title,
  browser_url: browserUrl,
  session: 'fmqa-wrapper',
  axi_session: 'fmqa-wrapper-local',
  captured_at: '2026-09-10T00:00:00.000Z',
}, null, 2) + '\n');
NODE
}

compat_lock_path() {
  local home=$1 cache_dir=$2 cache_parent canonical_cache lock_key
  cache_parent=$(dirname "$cache_dir")
  mkdir -p "$cache_parent"
  canonical_cache="$(cd "$cache_parent" && pwd -P)/$(basename "$cache_dir")"
  lock_key=$("$REAL_NODE" -e \
    'const crypto=require("crypto"); process.stdout.write(crypto.createHash("sha256").update(process.argv[1]).digest("hex"))' \
    "$canonical_cache")
  printf '%s/.local/share/fm-browser-qa/locks/chrome-devtools-mcp-1.7.0-%s.lock\n' "$home" "$lock_key"
}

run_qa() {
  local fakebin=$1 browser_dir=$2
  local -a env_args
  shift 2
  env_args=(
    "PATH=$fakebin:/usr/bin:/bin"
    "FM_FAKE_BROWSER_DIR=$browser_dir"
    "FM_BROWSER_QA_OPEN_SETTLE=0"
  )
  if [[ " $* " = *" --select-identity "* ]]; then
    env_args+=("HOME=$browser_dir/home")
  fi
  if [ "${CHROME_DEVTOOLS_AXI_MCP_PATH+x}" = x ]; then
    env_args+=("CHROME_DEVTOOLS_AXI_MCP_PATH=$CHROME_DEVTOOLS_AXI_MCP_PATH")
  else
    env_args+=("CHROME_DEVTOOLS_AXI_MCP_PATH=/operator/chrome-devtools-mcp.js")
  fi
  if [ "${FM_BROWSER_QA_PROFILE_DIR+x}" = x ]; then
    env_args+=("FM_BROWSER_QA_PROFILE_DIR=$FM_BROWSER_QA_PROFILE_DIR")
  fi
  env "${env_args[@]}" bash "$ROOT/bin/fm-browser-qa.sh" "$@" 2>&1
}

assert_axi_cleanup() {
  local browser_dir=$1 identity=$2 label=$3
  node - "$browser_dir/axi.log" "$identity" <<'NODE' || fail "$label"
const fs = require('fs');
const [logFile, identityFile] = process.argv.slice(2);
const identity = JSON.parse(fs.readFileSync(identityFile, 'utf8'));
const rows = fs.readFileSync(logFile, 'utf8').trim().split('\n').filter(Boolean).map((line) => line.split('\t'));
const stops = rows.filter(([command]) => command === 'stop');
if (stops.length !== 1) throw new Error(`expected one stop, got ${stops.length}`);
if (!identity.axi_session || identity.axi_session === identity.session) throw new Error('identity did not distinguish AXI and logical sessions');
if (!/^[A-Za-z0-9._-]{1,64}$/.test(identity.axi_session)) throw new Error('AXI session is invalid');
if (rows.some(([, session, browserUrl]) => session !== identity.axi_session || browserUrl !== identity.browser_url)) throw new Error('AXI command used the wrong session or browser endpoint');
if (rows.some(([command]) => command === 'close')) throw new Error('AXI attempted to close the browser');
NODE
}

assert_tmp_root_empty() {
  local dir=$1 label=$2
  [ -z "$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit)" ] || fail "$label"
}

assert_ledger_block_reason() {
  local ledger=$1 expected_stage=$2 expected_reason=$3 label=$4
  node - "$ledger" "$expected_stage" "$expected_reason" <<'NODE' || fail "$label"
const fs = require('fs');
const [ledger, expectedStage, expectedReason] = process.argv.slice(2);
const rows = fs.readFileSync(ledger, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
const expectedKeys = ['axi_session', 'out_dir', 'reason', 'session', 'stage', 'status', 'ts', 'url'].sort();
if (rows.length !== 1) process.exit(1);
const row = rows[0];
const keys = Object.keys(row).sort();
if (JSON.stringify(keys) !== JSON.stringify(expectedKeys)) process.exit(1);
if (row.status !== 1 || row.stage !== expectedStage || row.reason !== expectedReason) process.exit(1);
NODE
}

test_requires_url_and_out() {
  local dir fakebin out status
  dir="$TMP_ROOT/args"
  fakebin=$(make_fake_browser_tools "$dir")

  set +e
  out=$(run_qa "$fakebin" "$dir/browser" --out "$dir/evidence")
  status=$?
  set -e
  expect_code 2 "$status" "missing --url should exit 2"
  assert_contains "$out" "--url is required" "missing --url should explain the problem"

  set +e
  out=$(run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa")
  status=$?
  set -e
  expect_code 2 "$status" "missing --out should exit 2"
  assert_contains "$out" "--out is required" "missing --out should explain the problem"
  pass "fm-browser-qa.sh: requires --url and --out"
}

test_missing_chrome_devtools_axi_blocks() {
  local dir fakebin out status
  dir="$TMP_ROOT/missing-axi"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/node" <<SH
#!/usr/bin/env bash
exec "$REAL_NODE" "\$@"
SH
  chmod +x "$fakebin/node"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
printf '{"Browser":"fake"}\n'
SH
  chmod +x "$fakebin/curl"

  set +e
  out=$(FM_BROWSER_QA_LEDGER="$dir/runs.jsonl" PATH="$fakebin:/usr/bin:/bin" \
    bash "$ROOT/bin/fm-browser-qa.sh" --url "https://example.test/qa" --out "$dir/evidence" 2>&1)
  status=$?
  set -e
  expect_code 1 "$status" "missing chrome-devtools-axi should exit 1"
  assert_contains "$out" "blocked: chrome-devtools-axi is not installed" \
    "missing chrome-devtools-axi should be blocked"
  node - "$dir/runs.jsonl" <<'NODE' || fail "missing chrome-devtools-axi should append one blocked ledger row"
const fs = require('fs');
const rows = fs.readFileSync(process.argv[2], 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
if (rows.length !== 1) process.exit(1);
if (rows[0].status !== 1 || rows[0].stage !== 'init') process.exit(1);
if (!rows[0].reason?.includes('chrome-devtools-axi is not installed')) process.exit(1);
NODE
  pass "fm-browser-qa.sh: missing chrome-devtools-axi blocks and records the run"
}

test_missing_node_blocks_and_records_ledger() {
  local dir fakebin out status target_url tool
  dir="$TMP_ROOT/missing-node"
  target_url='https://example.test/qa?value="quoted"\path'
  fakebin=$(fm_fakebin "$dir")
  for tool in date dirname mkdir; do
    ln -s "$(command -v "$tool")" "$fakebin/$tool"
  done
  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/chrome-devtools-axi"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/curl"

  set +e
  out=$(FM_BROWSER_QA_LEDGER="$dir/runs.jsonl" PATH="$fakebin" \
    /bin/bash "$ROOT/bin/fm-browser-qa.sh" --url "$target_url" --out "$dir/evidence" 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "missing node should exit 1"
  assert_contains "$out" "blocked: node is not installed" "missing node should be blocked"
  node - "$dir/runs.jsonl" "$target_url" <<'NODE' || fail "missing node should append one blocked ledger row"
const fs = require('fs');
const [ledger, expectedUrl] = process.argv.slice(2);
const rows = fs.readFileSync(ledger, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
if (rows.length !== 1) process.exit(1);
if (rows[0].status !== 1 || rows[0].stage !== 'init') process.exit(1);
if (!rows[0].reason?.includes('node is not installed')) process.exit(1);
if (rows[0].url !== expectedUrl) process.exit(1);
NODE
  pass "fm-browser-qa.sh: missing node blocks and records the run"
}

test_pinned_mcp_compatibility_cache_is_installed_once() {
  local dir fakebin expected_path npm_calls
  dir="$TMP_ROOT/mcp-compat"
  fakebin=$(make_fake_browser_tools "$dir")
  write_page "$dir/browser" 1 "https://example.test/qa" "QA Page"

  cat > "$fakebin/npm" <<'SH'
#!/usr/bin/env bash
set -eu
dir=${FM_FAKE_BROWSER_DIR:?}
printf '%s\n' "$*" >> "$dir/npm.log"
prefix=
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--prefix" ]; then
    prefix=$2
    shift 2
    continue
  fi
  shift
done
[ -n "$prefix" ] || exit 2
package_dir="$prefix/node_modules/chrome-devtools-mcp"
mkdir -p "$package_dir/build/src/bin"
printf '{"name":"chrome-devtools-mcp","version":"1.7.0","type":"module","bin":{"chrome-devtools-mcp":"./build/src/bin/chrome-devtools-mcp.js"}}\n' > "$package_dir/package.json"
printf "await import('./chrome-devtools-mcp-main.js');\n" > "$package_dir/build/src/bin/chrome-devtools-mcp.js"
printf "if (process.argv.includes('--help')) process.exit(0);\n" > "$package_dir/build/src/bin/chrome-devtools-mcp-main.js"
SH
  chmod +x "$fakebin/npm"

  expected_path="$dir/home/.local/share/fm-browser-qa/chrome-devtools-mcp-1.7.0/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js"
  env \
    "PATH=$fakebin:/usr/bin:/bin" \
    "HOME=$dir/home" \
    "FM_FAKE_BROWSER_DIR=$dir/browser" \
    "FM_BROWSER_QA_OPEN_SETTLE=0" \
    bash "$ROOT/bin/fm-browser-qa.sh" --url "https://example.test/qa" --out "$dir/evidence-one" >/dev/null
  env \
    "PATH=$fakebin:/usr/bin:/bin" \
    "HOME=$dir/home" \
    "FM_FAKE_BROWSER_DIR=$dir/browser" \
    "FM_BROWSER_QA_OPEN_SETTLE=0" \
    bash "$ROOT/bin/fm-browser-qa.sh" --url "https://example.test/qa" --out "$dir/evidence-two" >/dev/null

  npm_calls=$(wc -l < "$dir/browser/npm.log" | tr -d '[:space:]')
  [ "$npm_calls" -eq 1 ] || fail "pinned MCP compatibility package should install once, got $npm_calls installs"
  [ -f "$expected_path" ] || fail "pinned MCP compatibility script was not cached at the expected path"
  awk -F '\t' -v expected="$expected_path" '$4 != expected { exit 1 }' "$dir/browser/axi.log" \
    || fail "AXI commands did not all use the pinned MCP compatibility path"
  pass "fm-browser-qa.sh: pinned MCP compatibility cache is installed once and reused"
}

test_partial_mcp_compatibility_cache_is_repaired() {
  local dir fakebin cache_dir package_dir expected_path npm_calls status
  dir="$TMP_ROOT/mcp-partial-cache"
  fakebin=$(make_fake_browser_tools "$dir")
  write_page "$dir/browser" 1 "https://example.test/qa" "QA Page"
  cache_dir="$dir/home/.local/share/fm-browser-qa/chrome-devtools-mcp-1.7.0"
  package_dir="$cache_dir/node_modules/chrome-devtools-mcp"
  expected_path="$package_dir/build/src/bin/chrome-devtools-mcp.js"
  mkdir -p "$package_dir/build/src/bin"
  printf '{"name":"chrome-devtools-mcp","version":"1.7.0","type":"module","bin":{"chrome-devtools-mcp":"./build/src/bin/chrome-devtools-mcp.js"}}\n' > "$package_dir/package.json"
  printf "await import('./chrome-devtools-mcp-main.js');\n" > "$expected_path"

  cat > "$fakebin/npm" <<'SH'
#!/usr/bin/env bash
set -eu
dir=${FM_FAKE_BROWSER_DIR:?}
printf '%s\n' "$*" >> "$dir/npm.log"
prefix=
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--prefix" ]; then
    prefix=$2
    shift 2
    continue
  fi
  shift
done
[ -n "$prefix" ] || exit 2
package_dir="$prefix/node_modules/chrome-devtools-mcp"
mkdir -p "$package_dir/build/src/bin"
printf '{"name":"chrome-devtools-mcp","version":"1.7.0","type":"module","bin":{"chrome-devtools-mcp":"./build/src/bin/chrome-devtools-mcp.js"}}\n' > "$package_dir/package.json"
printf "await import('./chrome-devtools-mcp-main.js');\n" > "$package_dir/build/src/bin/chrome-devtools-mcp.js"
printf "if (process.argv.includes('--help')) process.exit(0);\n" > "$package_dir/build/src/bin/chrome-devtools-mcp-main.js"
SH
  chmod +x "$fakebin/npm"

  set +e
  env \
    "PATH=$fakebin:/usr/bin:/bin" \
    "HOME=$dir/home" \
    "FM_BROWSER_QA_LEDGER=$dir/runs.jsonl" \
    "FM_FAKE_BROWSER_DIR=$dir/browser" \
    "FM_BROWSER_QA_OPEN_SETTLE=0" \
    bash "$ROOT/bin/fm-browser-qa.sh" --url "https://example.test/qa" --out "$dir/evidence" >/dev/null
  status=$?
  set -e

  expect_code 0 "$status" "partial compatibility cache should be repaired"
  npm_calls=$(wc -l < "$dir/browser/npm.log" | tr -d '[:space:]')
  [ "$npm_calls" -eq 1 ] || fail "partial compatibility cache should be reinstalled once, got $npm_calls installs"
  assert_present "$package_dir/build/src/bin/chrome-devtools-mcp-main.js" \
    "partial compatibility cache was not replaced with a runtime-complete install"
  awk -F '\t' -v expected="$expected_path" '$4 != expected { exit 1 }' "$dir/browser/axi.log" \
    || fail "AXI commands did not use the repaired compatibility cache"
  pass "fm-browser-qa.sh: partial MCP compatibility cache is repaired"
}

test_concurrent_mcp_cache_install_waits_for_atomic_publish() {
  local dir fakebin cache_dir expected_path lock_file pid_one pid_two pid_three status_one status_two status_three tries npm_calls
  dir="$TMP_ROOT/mcp-concurrent"
  fakebin=$(make_fake_browser_tools "$dir")
  write_page "$dir/browser" 1 "https://example.test/qa" "QA Page"

  cat > "$fakebin/npm" <<'SH'
#!/usr/bin/env bash
set -eu
dir=${FM_FAKE_BROWSER_DIR:?}
printf '%s\n' "$*" >> "$dir/npm.log"
prefix=
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--prefix" ]; then
    prefix=$2
    shift 2
    continue
  fi
  shift
done
[ -n "$prefix" ] || exit 2
package_dir="$prefix/node_modules/chrome-devtools-mcp"
mkdir -p "$package_dir/build/src/bin"
printf '{"name":"chrome-devtools-mcp","version":"1.7.0","type":"module","bin":{"chrome-devtools-mcp":"./build/src/bin/chrome-devtools-mcp.js"}}\n' > "$package_dir/package.json"
printf "await import('./chrome-devtools-mcp-main.js');\n" > "$package_dir/build/src/bin/chrome-devtools-mcp.js"
printf "if (process.argv.includes('--help')) process.exit(0);\n" > "$package_dir/build/src/bin/chrome-devtools-mcp-main.js"
: > "$dir/install_started"
while [ ! -e "$dir/install_release" ]; do
  sleep 0.05
done
SH
  chmod +x "$fakebin/npm"

  cache_dir="$dir/home/.local/share/fm-browser-qa/chrome-devtools-mcp-1.7.0"
  expected_path="$cache_dir/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js"
  lock_file=$(compat_lock_path "$dir/home" "$cache_dir")
  mkdir -p "$(dirname "$lock_file")"
  printf '999999\t999999\tstale-owner\n' > "$lock_file"
  env \
    "PATH=$fakebin:/usr/bin:/bin" \
    "HOME=$dir/home" \
    "FM_BROWSER_QA_LEDGER=$dir/one.jsonl" \
    "FM_FAKE_BROWSER_DIR=$dir/browser" \
    "FM_BROWSER_QA_OPEN_SETTLE=0" \
    bash "$ROOT/bin/fm-browser-qa.sh" --url "https://example.test/qa" --out "$dir/evidence-one" > "$dir/one.out" 2>&1 &
  pid_one=$!
  tries=40
  while [ ! -e "$dir/browser/install_started" ] && [ "$tries" -gt 0 ]; do
    sleep 0.05
    tries=$((tries - 1))
  done
  [ -e "$dir/browser/install_started" ] || fail "first compatibility install did not start"

  env \
    "PATH=$fakebin:/usr/bin:/bin" \
    "HOME=$dir/home" \
    "FM_BROWSER_QA_LEDGER=$dir/two.jsonl" \
    "FM_FAKE_BROWSER_DIR=$dir/browser" \
    "FM_BROWSER_QA_OPEN_SETTLE=0" \
    bash "$ROOT/bin/fm-browser-qa.sh" --url "https://example.test/qa" --out "$dir/evidence-two" > "$dir/two.out" 2>&1 &
  pid_two=$!
  env \
    "PATH=$fakebin:/usr/bin:/bin" \
    "HOME=$dir/home" \
    "FM_BROWSER_QA_LEDGER=$dir/three.jsonl" \
    "FM_FAKE_BROWSER_DIR=$dir/browser" \
    "FM_BROWSER_QA_OPEN_SETTLE=0" \
    bash "$ROOT/bin/fm-browser-qa.sh" --url "https://example.test/qa" --out "$dir/evidence-three" > "$dir/three.out" 2>&1 &
  pid_three=$!
  sleep 0.2

  assert_absent "$expected_path" "compatibility cache should not publish before installation completes"
  assert_absent "$dir/browser/axi.log" "a concurrent waiter should not use an unpublished compatibility cache"
  : > "$dir/browser/install_release"
  set +e
  wait "$pid_one"
  status_one=$?
  wait "$pid_two"
  status_two=$?
  wait "$pid_three"
  status_three=$?
  set -e

  expect_code 0 "$status_one" "first concurrent compatibility install run should succeed"
  expect_code 0 "$status_two" "waiting concurrent compatibility run should succeed"
  expect_code 0 "$status_three" "third concurrent compatibility run should succeed"
  npm_calls=$(wc -l < "$dir/browser/npm.log" | tr -d '[:space:]')
  [ "$npm_calls" -eq 1 ] || fail "concurrent compatibility runs should install once, got $npm_calls installs"
  assert_present "$expected_path" "validated compatibility cache was not published"
  [ ! -s "$lock_file" ] || fail "compatibility cache lock retained an owner after concurrent runs"
  [ -z "$(find "$(dirname "$cache_dir")" -maxdepth 1 -name '*.staging.*' -print -quit)" ] \
    || fail "compatibility staging directory remained after concurrent runs"
  awk -F '\t' -v expected="$expected_path" '$4 != expected { exit 1 }' "$dir/browser/axi.log" \
    || fail "concurrent AXI commands did not use the atomically published compatibility cache"
  pass "fm-browser-qa.sh: stale lock and concurrent installers serialize atomic publication"
}

test_failed_mcp_install_is_not_published() {
  local dir fakebin cache_dir lock_file out status
  dir="$TMP_ROOT/mcp-install-fail"
  fakebin=$(make_fake_browser_tools "$dir")
  write_page "$dir/browser" 1 "https://example.test/qa" "QA Page"

  cat > "$fakebin/npm" <<'SH'
#!/usr/bin/env bash
set -eu
dir=${FM_FAKE_BROWSER_DIR:?}
prefix=
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--prefix" ]; then
    prefix=$2
    shift 2
    continue
  fi
  shift
done
[ -n "$prefix" ] || exit 2
package_dir="$prefix/node_modules/chrome-devtools-mcp"
mkdir -p "$package_dir/build/src/bin"
printf '{"name":"chrome-devtools-mcp","version":"1.7.0","bin":{"chrome-devtools-mcp":"./build/src/bin/chrome-devtools-mcp.js"}}\n' > "$package_dir/package.json"
printf '// incomplete chrome-devtools-mcp\n' > "$package_dir/build/src/bin/chrome-devtools-mcp.js"
printf 'registry unavailable\n' >&2
exit 9
SH
  chmod +x "$fakebin/npm"

  cache_dir="$dir/home/.local/share/fm-browser-qa/chrome-devtools-mcp-1.7.0"
  lock_file=$(compat_lock_path "$dir/home" "$cache_dir")
  set +e
  out=$(env \
    "PATH=$fakebin:/usr/bin:/bin" \
    "HOME=$dir/home" \
    "FM_BROWSER_QA_LEDGER=$dir/runs.jsonl" \
    "FM_FAKE_BROWSER_DIR=$dir/browser" \
    "FM_BROWSER_QA_OPEN_SETTLE=0" \
    bash "$ROOT/bin/fm-browser-qa.sh" --url "https://example.test/qa" --out "$dir/evidence" 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "failed compatibility install should block"
  assert_contains "$out" "registry unavailable" "failed compatibility install should preserve npm diagnostics"
  assert_absent "$cache_dir" "failed compatibility install should not publish a cache"
  [ ! -s "$lock_file" ] || fail "compatibility cache lock retained an owner after failed install"
  [ -z "$(find "$(dirname "$cache_dir")" -maxdepth 1 -name '*.staging.*' -print -quit)" ] \
    || fail "compatibility staging directory remained after failed install"
  assert_absent "$dir/browser/axi.log" "failed compatibility install should not start AXI"
  pass "fm-browser-qa.sh: failed compatibility install is not published"
}

test_invalid_custom_mcp_cache_is_preserved() {
  local dir fakebin custom_cache out status
  dir="$TMP_ROOT/mcp-custom-invalid"
  fakebin=$(make_fake_browser_tools "$dir")
  write_page "$dir/browser" 1 "https://example.test/qa" "QA Page"
  custom_cache="$dir/operator-data"
  mkdir -p "$custom_cache"
  printf 'keep me\n' > "$custom_cache/important.txt"

  set +e
  out=$(env \
    "PATH=$fakebin:/usr/bin:/bin" \
    "HOME=$dir/home" \
    "FM_BROWSER_QA_MCP_COMPAT_DIR=$custom_cache" \
    "FM_BROWSER_QA_LEDGER=$dir/runs.jsonl" \
    "FM_FAKE_BROWSER_DIR=$dir/browser" \
    "FM_BROWSER_QA_OPEN_SETTLE=0" \
    bash "$ROOT/bin/fm-browser-qa.sh" --url "https://example.test/qa" --out "$dir/evidence" 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "invalid custom compatibility path should block"
  assert_contains "$out" "refusing to replace an invalid custom" \
    "invalid custom compatibility path should explain the ownership boundary"
  assert_grep "keep me" "$custom_cache/important.txt" \
    "invalid custom compatibility path should preserve unrelated data"
  assert_absent "$dir/browser/npm.log" "invalid custom compatibility path should fail before installation"
  pass "fm-browser-qa.sh: invalid custom compatibility cache is preserved"
}

test_compatibility_lock_refuses_symlink_sidecar() {
  local dir fakebin cache_dir lock_file important out status
  dir="$TMP_ROOT/mcp-lock-symlink"
  fakebin=$(make_fake_browser_tools "$dir")
  fm_fake_exit0 "$fakebin" npm
  write_page "$dir/browser" 1 "https://example.test/qa" "QA Page"
  cache_dir="$dir/operator-cache/chrome-devtools-mcp-1.7.0"
  lock_file=$(compat_lock_path "$dir/home" "$cache_dir")
  important="$dir/important.txt"
  printf 'keep me\n' > "$important"
  mkdir -p "$(dirname "$lock_file")"
  ln -s "$important" "$lock_file"

  set +e
  out=$(env \
    "PATH=$fakebin:/usr/bin:/bin" \
    "HOME=$dir/home" \
    "FM_BROWSER_QA_MCP_COMPAT_DIR=$cache_dir" \
    "FM_BROWSER_QA_LEDGER=$dir/runs.jsonl" \
    "FM_FAKE_BROWSER_DIR=$dir/browser" \
    "FM_BROWSER_QA_OPEN_SETTLE=0" \
    bash "$ROOT/bin/fm-browser-qa.sh" --url "https://example.test/qa" --out "$dir/evidence" 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "symlink compatibility lock should block"
  assert_contains "$out" "could not acquire chrome-devtools-mcp compatibility cache lock" \
    "symlink compatibility lock should fail closed"
  assert_grep "keep me" "$important" "symlink compatibility lock should preserve its target"
  assert_absent "$cache_dir" "symlink compatibility lock should block before installation"
  pass "fm-browser-qa.sh: compatibility lock refuses a symlink sidecar"
}

test_explicit_mcp_path_bypasses_compatibility_cache() {
  local dir fakebin
  dir="$TMP_ROOT/mcp-override"
  fakebin=$(make_fake_browser_tools "$dir")
  write_page "$dir/browser" 1 "https://example.test/qa" "QA Page"

  CHROME_DEVTOOLS_AXI_MCP_PATH=/operator/custom-mcp.js \
    run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$dir/evidence" >/dev/null

  assert_absent "$dir/browser/npm.log" "explicit MCP path should bypass compatibility installation"
  awk -F '\t' '$4 != "/operator/custom-mcp.js" { exit 1 }' "$dir/browser/axi.log" \
    || fail "AXI commands did not preserve the explicit MCP path"
  pass "fm-browser-qa.sh: explicit MCP path bypasses the compatibility cache"
}

test_explicit_mcp_path_works_without_home() {
  local dir fakebin status
  dir="$TMP_ROOT/mcp-override-no-home"
  fakebin=$(make_fake_browser_tools "$dir")
  write_page "$dir/browser" 1 "https://example.test/qa" "QA Page"

  set +e
  env -u HOME \
    "PATH=$fakebin:/usr/bin:/bin" \
    "CHROME_DEVTOOLS_AXI_MCP_PATH=/operator/custom-mcp.js" \
    "FM_BROWSER_QA_LEDGER=$dir/runs.jsonl" \
    "FM_FAKE_BROWSER_DIR=$dir/browser" \
    "FM_BROWSER_QA_OPEN_SETTLE=0" \
    bash "$ROOT/bin/fm-browser-qa.sh" --url "https://example.test/qa" --out "$dir/evidence" >/dev/null
  status=$?
  set -e

  expect_code 0 "$status" "explicit MCP path should run without HOME"
  assert_absent "$dir/browser/npm.log" "explicit MCP path without HOME should bypass compatibility installation"
  awk -F '\t' '$4 != "/operator/custom-mcp.js" { exit 1 }' "$dir/browser/axi.log" \
    || fail "AXI commands did not preserve the explicit MCP path without HOME"
  node - "$dir/runs.jsonl" <<'NODE' || fail "explicit ledger path should record a HOME-less run"
const fs = require('fs');
const rows = fs.readFileSync(process.argv[2], 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
if (rows.length !== 1 || rows[0].status !== 0) process.exit(1);
NODE
  pass "fm-browser-qa.sh: explicit MCP path works without HOME"
}

test_unreachable_target_blocks_before_opening_browser_tab() {
  local dir fakebin out status target_url curl_count
  dir="$TMP_ROOT/target-down"
  fakebin=$(make_fake_browser_tools "$dir")
  target_url="https://feature-down.example.test/qa"
  mkdir -p "$dir/browser"
  : > "$dir/browser/target_down"
  : > "$dir/browser/curl.log"

  set +e
  out=$(FM_BROWSER_QA_LEDGER="$dir/runs.jsonl" \
    run_qa "$fakebin" "$dir/browser" --url "$target_url" --out "$dir/evidence" --start-if-needed)
  status=$?
  set -e

  expect_code 1 "$status" "unreachable target should exit 1"
  assert_contains "$out" "blocked: target host is unreachable; likely torn-down feature branch for exact QA URL: $target_url" \
    "unreachable target should report the likely torn-down feature branch"
  curl_count=$(wc -l < "$dir/browser/curl.log" | tr -d '[:space:]')
  [ "$curl_count" -eq 1 ] || fail "unreachable target should be checked once, got $curl_count curl calls"
  assert_grep "$target_url" "$dir/browser/curl.log" "unreachable target check should curl the exact target URL"
  assert_absent "$dir/browser/open.log" "unreachable target should not start Chrome"
  assert_absent "$dir/browser/newpage_started" "unreachable target should not open a browser tab"
  assert_absent "$dir/browser/axi.log" "unreachable target should not start an AXI bridge"
  assert_ledger_block_reason "$dir/runs.jsonl" "target-reachability" \
    "target host is unreachable; likely torn-down feature branch for exact QA URL: $target_url" \
    "unreachable target should record the distinct likely torn-down reason"
  pass "fm-browser-qa.sh: unreachable target blocks before opening a browser tab"
}

test_http_error_target_blocks_before_opening_browser_tab() {
  local dir fakebin out status target_url
  dir="$TMP_ROOT/target-http-error"
  fakebin=$(make_fake_browser_tools "$dir")
  target_url="https://feature-down.example.test/qa"
  mkdir -p "$dir/browser"
  : > "$dir/browser/target_http_error"

  set +e
  out=$(run_qa "$fakebin" "$dir/browser" --url "$target_url" --out "$dir/evidence" --start-if-needed)
  status=$?
  set -e

  expect_code 1 "$status" "HTTP error target should exit 1"
  assert_contains "$out" "blocked: target host is unreachable; likely torn-down feature branch for exact QA URL: $target_url" \
    "HTTP error target should report the likely torn-down feature branch"
  assert_absent "$dir/browser/open.log" "HTTP error target should not start Chrome"
  assert_absent "$dir/browser/newpage_started" "HTTP error target should not open a browser tab"
  assert_absent "$dir/browser/axi.log" "HTTP error target should not start an AXI bridge"
  pass "fm-browser-qa.sh: HTTP error target blocks before opening a browser tab"
}

test_curl_timeout_override_preserves_finite_values() {
  local dir fakebin expected
  dir="$TMP_ROOT/bounded-curl-timeout"
  fakebin=$(make_fake_browser_tools "$dir")
  write_page "$dir/browser" 1 "https://example.test/qa" "QA Page"
  : > "$dir/browser/curl_timeout.log"

  for expected in 10 2.92 999; do
    : > "$dir/browser/curl_timeout.log"
    FM_BROWSER_QA_CURL_TIMEOUT=$expected \
      run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$dir/evidence-$expected" >/dev/null
    awk -v expected="$expected" '$0 != expected { exit 1 } END { if (NR != 2) exit 1 }' \
      "$dir/browser/curl_timeout.log" \
      || fail "finite curl timeout $expected should be preserved for target and browser checks"
  done

  for expected in 0 0.0009 invalid 1e16 1e9999; do
    : > "$dir/browser/curl_timeout.log"
    FM_BROWSER_QA_CURL_TIMEOUT=$expected \
      run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$dir/evidence-invalid-$expected" >/dev/null
    awk '$0 != "2" { exit 1 } END { if (NR != 2) exit 1 }' "$dir/browser/curl_timeout.log" \
      || fail "invalid or unbounded curl timeout $expected should use the bounded default"
  done

  pass "fm-browser-qa.sh: curl timeout override preserves finite values"
}

test_browser_unreachable_without_start_blocks() {
  local dir fakebin out status
  dir="$TMP_ROOT/browser-down"
  fakebin=$(make_fake_browser_tools "$dir")
  mkdir -p "$dir/browser"
  : > "$dir/browser/browser_down"

  set +e
  out=$(run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$dir/evidence")
  status=$?
  set -e
  expect_code 1 "$status" "unreachable browser should exit 1"
  assert_contains "$out" "blocked: Chrome remote-debugging endpoint is not reachable" \
    "unreachable browser should be blocked"
  pass "fm-browser-qa.sh: unreachable browser blocks without --start-if-needed"
}

test_start_if_needed_uses_persistent_visible_profile() {
  local dir fakebin evidence
  dir="$TMP_ROOT/start-browser"
  fakebin=$(make_fake_browser_tools "$dir")
  mkdir -p "$dir/browser"
  : > "$dir/browser/browser_down"
  evidence="$dir/evidence"

  FM_BROWSER_QA_PROFILE_DIR="$dir/profile" \
    run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$evidence" --start-if-needed >/dev/null

  assert_grep "--remote-debugging-port=9222" "$dir/browser/open.log" \
    "started Chrome without the requested DevTools port"
  assert_grep "--user-data-dir=$dir/profile" "$dir/browser/open.log" \
    "started Chrome without a persistent QA profile"
  assert_grep "--new-window" "$dir/browser/open.log" \
    "started Chrome without a visible new window"
  assert_grep "https://example.test/qa" "$dir/browser/open.log" \
    "started Chrome without the exact QA URL"
  assert_grep "Google Chrome" "$dir/browser/osascript.log" \
    "started Chrome without foregrounding the QA window"
  assert_present "$evidence/identity.json" "identity evidence missing after starting browser"
  pass "fm-browser-qa.sh: --start-if-needed uses a persistent visible Chrome profile"
}

test_start_if_needed_refuses_existing_temporary_profile() {
  local dir fakebin out status
  dir="$TMP_ROOT/temp-profile"
  fakebin=$(make_fake_browser_tools "$dir")
  mkdir -p "$dir/browser"
  printf '12345\n' > "$dir/browser/lsof.out"
  printf '%s\n' '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --remote-debugging-port=9222 --user-data-dir=/tmp/fm-visible-cad-chrome --new-window https://example.test/qa' > "$dir/browser/ps_12345.out"

  set +e
  out=$(FM_BROWSER_QA_PROFILE_DIR="$dir/profile" \
    run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$dir/evidence" --start-if-needed)
  status=$?
  set -e

  expect_code 1 "$status" "existing temporary profile should exit 1"
  assert_contains "$out" "already using a temporary profile" \
    "temporary profile should be refused clearly"
  assert_contains "$out" "/tmp/fm-visible-cad-chrome" \
    "temporary profile path should be included"
  assert_contains "$out" "kill 12345" \
    "temporary profile blocker should name the PID cleanup"
  assert_absent "$dir/browser/open.log" \
    "temporary profile blocker should not start another Chrome"
  pass "fm-browser-qa.sh: --start-if-needed refuses an existing temporary Chrome profile"
}

test_start_if_needed_allows_existing_operator_profile() {
  local dir fakebin evidence profile
  dir="$TMP_ROOT/operator-profile"
  fakebin=$(make_fake_browser_tools "$dir")
  profile="/opt/fm-browser-qa/operator-chrome-profile"
  mkdir -p "$dir/browser"
  printf '23456\n' > "$dir/browser/lsof.out"
  printf '%s\n' "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --remote-debugging-port=9222 --user-data-dir=$profile --new-window https://example.test/qa" > "$dir/browser/ps_23456.out"
  write_page "$dir/browser" 1 "https://example.test/qa" "QA Page"
  evidence="$dir/evidence"

  FM_BROWSER_QA_PROFILE_DIR="$dir/profile" \
    run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$evidence" --start-if-needed >/dev/null

  assert_grep "uses profile $profile instead of $dir/profile" "$evidence/report.md" \
    "non-default operator profile should be allowed with a warning"
  assert_present "$evidence/identity.json" "identity evidence missing for operator profile"
  pass "fm-browser-qa.sh: --start-if-needed allows a stable operator Chrome profile"
}

test_exact_tab_selected_and_evidence_written() {
  local dir fakebin evidence identity
  dir="$TMP_ROOT/exact"
  fakebin=$(make_fake_browser_tools "$dir")
  write_page "$dir/browser" 1 "https://example.test/qa" "QA Page"
  evidence="$dir/evidence"

  run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$evidence" --session exact >/dev/null

  identity="$evidence/identity.json"
  assert_present "$identity" "identity evidence missing"
  node -e 'const fs=require("fs"); const j=JSON.parse(fs.readFileSync(process.argv[1])); if (j.requested_url !== "https://example.test/qa" || j.title !== "QA Page" || j.session !== "fmqa-exact" || !j.axi_session) process.exit(1)' "$identity" \
    || fail "identity evidence has wrong URL/title/session"
  assert_present "$evidence/snapshot.txt" "snapshot evidence missing"
  assert_present "$evidence/screenshot.png" "screenshot evidence missing"
  assert_present "$evidence/report.md" "report evidence missing"
  assert_grep "Exact URL: https://example.test/qa" "$evidence/report.md" "report missing exact URL"
  pass "fm-browser-qa.sh: exact tab is selected and evidence is written"
}

test_no_exact_tab_opens_new_page_then_verifies() {
  local dir fakebin evidence
  dir="$TMP_ROOT/open-new"
  fakebin=$(make_fake_browser_tools "$dir")
  write_page "$dir/browser" 1 "https://example.test/other" "Other"
  evidence="$dir/evidence"

  run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$evidence" >/dev/null

  assert_grep "https://example.test/qa" "$dir/browser/newpage.log" "newpage was not opened with exact URL"
  assert_grep '"requested_url": "https://example.test/qa"' "$evidence/identity.json" \
    "identity evidence did not verify opened page"
  pass "fm-browser-qa.sh: opens a missing exact tab and verifies it"
}

test_multiple_exact_tabs_refused() {
  local dir fakebin out status
  dir="$TMP_ROOT/multiple"
  fakebin=$(make_fake_browser_tools "$dir")
  write_page "$dir/browser" 1 "https://example.test/qa" "QA One"
  write_page "$dir/browser" 2 "https://example.test/qa" "QA Two"

  set +e
  out=$(run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$dir/evidence")
  status=$?
  set -e
  expect_code 1 "$status" "multiple exact tabs should exit 1"
  assert_contains "$out" "blocked: multiple tabs match the exact QA URL" \
    "multiple exact tabs should be refused"
  pass "fm-browser-qa.sh: refuses multiple exact tabs"
}

test_selected_url_mismatch_refused() {
  local dir fakebin out status
  dir="$TMP_ROOT/mismatch"
  fakebin=$(make_fake_browser_tools "$dir")
  write_page "$dir/browser" 1 "https://example.test/qa" "QA Page"
  : > "$dir/browser/mismatch_on_final"

  set +e
  out=$(run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$dir/evidence")
  status=$?
  set -e
  expect_code 1 "$status" "selected URL mismatch should exit 1"
  assert_contains "$out" "blocked: selected browser tab URL mismatch" \
    "selected URL mismatch should be refused"
  pass "fm-browser-qa.sh: selected URL mismatch is refused"
}

test_auth_blocked_reported() {
  local dir fakebin out status
  dir="$TMP_ROOT/auth"
  fakebin=$(make_fake_browser_tools "$dir")
  mkdir -p "$dir/browser"
  write_page "$dir/browser" 1 "https://example.cloudflareaccess.com/cdn-cgi/access/login" "Cloudflare Access"
  printf '%s\t%s\n' "https://example.cloudflareaccess.com/cdn-cgi/access/login" "Cloudflare Access" > "$dir/browser/newpage_redirect"
  printf '%s\n' 1 > "$dir/browser/newpage_reuses_page"

  set +e
  out=$(FM_BROWSER_QA_LEDGER="$dir/runs.jsonl" \
    run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$dir/evidence")
  status=$?
  set -e
  expect_code 1 "$status" "auth page should exit 1"
  assert_contains "$out" "blocked: authenticated browser session expired" \
    "auth page should be reported as authenticated-session blocked"
  assert_grep "Google Chrome" "$dir/browser/osascript.log" \
    "auth block should foreground the QA Chrome window"
  assert_not_contains "$out" "exact QA URL is not open after navigation" \
    "Cloudflare landed URL should not fall through to generic navigation failure"
  assert_ledger_block_reason "$dir/runs.jsonl" "page-scan" \
    "authenticated browser session expired; sign in to the foregrounded QA Chrome window, then rerun" \
    "auth page should record the distinct authentication-expired reason"
  pass "fm-browser-qa.sh: auth/sign-in pages block clearly"
}

test_delayed_auth_redirect_is_reprobed_authoritatively() {
  local dir fakebin out status target_url
  dir="$TMP_ROOT/auth-delayed"
  fakebin=$(make_fake_browser_tools "$dir")
  target_url="https://example.test/qa"
  write_page "$dir/browser" 1 "https://example.test/other" "Other"
  printf '%s\n' 1 > "$dir/browser/newpage_reuses_page"
  printf '%s\t%s\t%s\n' 2 "https://example.cloudflareaccess.com/cdn-cgi/access/login" "Cloudflare Access" \
    > "$dir/browser/delayed_redirect_1"

  set +e
  out=$(FM_BROWSER_QA_LEDGER="$dir/runs.jsonl" \
    run_qa "$fakebin" "$dir/browser" --url "$target_url" --out "$dir/evidence")
  status=$?
  set -e

  expect_code 1 "$status" "delayed auth redirect should exit 1"
  assert_contains "$out" "blocked: authenticated browser session expired; sign in to the foregrounded QA Chrome window, then rerun" \
    "delayed auth redirect should report the exact authenticated-session-expired message"
  assert_not_contains "$out" "exact QA URL is not open after navigation" \
    "delayed auth redirect should not fall through to generic navigation failure"
  assert_ledger_block_reason "$dir/runs.jsonl" "page-scan" \
    "authenticated browser session expired; sign in to the foregrounded QA Chrome window, then rerun" \
    "delayed auth redirect should record the distinct authentication-expired reason"
  pass "fm-browser-qa.sh: delayed auth redirect is re-probed authoritatively"
}

test_later_reused_tab_auth_observation_is_reconciled() {
  local dir fakebin out status target_url
  dir="$TMP_ROOT/auth-later-reused"
  fakebin=$(make_fake_browser_tools "$dir")
  target_url="https://example.test/qa"
  write_page "$dir/browser" 1 "https://example.test/other" "Other"
  printf '%s\n' 1 > "$dir/browser/newpage_reuses_page"
  printf '%s\t%s\n' "https://example.test/loading" "Loading" > "$dir/browser/newpage_redirect"
  printf '%s\t%s\t%s\n' 3 "https://example.cloudflareaccess.com/cdn-cgi/access/login" "Cloudflare Access" \
    > "$dir/browser/delayed_redirect_1"

  set +e
  out=$(FM_BROWSER_QA_LEDGER="$dir/runs.jsonl" \
    run_qa "$fakebin" "$dir/browser" --url "$target_url" --out "$dir/evidence")
  status=$?
  set -e

  expect_code 1 "$status" "later reused-tab auth redirect should exit 1"
  assert_contains "$out" "blocked: authenticated browser session expired; sign in to the foregrounded QA Chrome window, then rerun" \
    "later reused-tab auth redirect should retain the exact session-expired message"
  assert_not_contains "$out" "exact QA URL is not open after navigation" \
    "later reused-tab auth redirect should not fall through to generic navigation failure"
  assert_ledger_block_reason "$dir/runs.jsonl" "page-scan" \
    "authenticated browser session expired; sign in to the foregrounded QA Chrome window, then rerun" \
    "later reused-tab auth redirect should record the distinct authentication-expired reason"
  pass "fm-browser-qa.sh: later reused-tab auth observation is reconciled"
}

test_late_new_landing_auth_is_reconciled() {
  local dir fakebin out status target_url
  dir="$TMP_ROOT/auth-late-new"
  fakebin=$(make_fake_browser_tools "$dir")
  target_url="https://example.test/qa"
  mkdir -p "$dir/browser"
  printf '%s\t%s\n' "https://example.test/loading" "Loading" > "$dir/browser/newpage_redirect"
  printf '%s\t%s\t%s\n' 2 "https://example.cloudflareaccess.com/cdn-cgi/access/login" "Cloudflare Access" \
    > "$dir/browser/delayed_redirect_1"

  set +e
  out=$(FM_BROWSER_QA_LEDGER="$dir/runs.jsonl" \
    run_qa "$fakebin" "$dir/browser" --url "$target_url" --out "$dir/evidence")
  status=$?
  set -e

  expect_code 1 "$status" "late new landing auth redirect should exit 1"
  assert_contains "$out" "blocked: authenticated browser session expired; sign in to the foregrounded QA Chrome window, then rerun" \
    "late new landing auth redirect should retain the exact session-expired message"
  assert_not_contains "$out" "exact QA URL is not open after navigation" \
    "late new landing auth redirect should not fall through to generic navigation failure"
  assert_ledger_block_reason "$dir/runs.jsonl" "page-scan" \
    "authenticated browser session expired; sign in to the foregrounded QA Chrome window, then rerun" \
    "late new landing auth redirect should record the distinct authentication-expired reason"
  pass "fm-browser-qa.sh: late new landing auth is reconciled"
}

test_late_unidentified_landing_auth_is_reconciled() {
  local dir fakebin out status target_url
  dir="$TMP_ROOT/auth-late-unidentified"
  fakebin=$(make_fake_browser_tools "$dir")
  target_url="https://example.test/qa"
  write_page "$dir/browser" 1 "https://example.test/other" "Other"
  : > "$dir/browser/unprobeable_once_1"
  printf '%s\n' 1 > "$dir/browser/newpage_reuses_page"
  printf '%s\t%s\n' "https://example.test/loading" "Loading" > "$dir/browser/newpage_redirect"
  printf '%s\t%s\t%s\n' 2 "https://example.cloudflareaccess.com/cdn-cgi/access/login" "Cloudflare Access" \
    > "$dir/browser/delayed_redirect_1"

  set +e
  out=$(FM_BROWSER_QA_LEDGER="$dir/runs.jsonl" \
    run_qa "$fakebin" "$dir/browser" --url "$target_url" --out "$dir/evidence")
  status=$?
  set -e

  expect_code 1 "$status" "late unidentified landing auth redirect should exit 1"
  assert_contains "$out" "blocked: authenticated browser session expired; sign in to the foregrounded QA Chrome window, then rerun" \
    "late unidentified landing auth redirect should retain the exact session-expired message"
  assert_not_contains "$out" "exact QA URL is not open after navigation" \
    "late unidentified landing auth redirect should not fall through to generic navigation failure"
  assert_ledger_block_reason "$dir/runs.jsonl" "page-scan" \
    "authenticated browser session expired; sign in to the foregrounded QA Chrome window, then rerun" \
    "late unidentified landing auth redirect should record the distinct authentication-expired reason"
  pass "fm-browser-qa.sh: late unidentified landing auth is reconciled"
}

test_authoritative_exact_target_is_accepted() {
  local dir fakebin out status target_url
  dir="$TMP_ROOT/authoritative-exact"
  fakebin=$(make_fake_browser_tools "$dir")
  target_url="https://example.test/qa"
  write_page "$dir/browser" 1 "https://example.test/other" "Other"
  : > "$dir/browser/unprobeable_once_1"
  printf '%s\n' 1 > "$dir/browser/newpage_reuses_page"

  set +e
  out=$(run_qa "$fakebin" "$dir/browser" --url "$target_url" --out "$dir/evidence")
  status=$?
  set -e

  expect_code 0 "$status" "authoritative exact target should succeed"
  assert_not_contains "$out" "exact QA URL is not open after navigation" \
    "authoritative exact target should not report a navigation failure"
  assert_grep '"active_url": "https://example.test/qa"' "$dir/evidence/identity.json" \
    "authoritative exact target should be retained as the verified match"
  pass "fm-browser-qa.sh: authoritative exact target is accepted"
}

test_authoritative_auth_precedes_unprobeable_fallback() {
  local dir fakebin out status target_url
  dir="$TMP_ROOT/auth-before-fallback"
  fakebin=$(make_fake_browser_tools "$dir")
  target_url="https://example.test/qa"
  write_page "$dir/browser" 1 "https://example.test/other" "Other"
  printf '%s\n' 1 > "$dir/browser/newpage_reuses_page"
  printf '%s\t%s\t%s\n' 2 "https://example.cloudflareaccess.com/cdn-cgi/access/login" "Cloudflare Access" \
    > "$dir/browser/delayed_redirect_1"
  printf '%s\t%s\t%s\n' 2 "chrome://gpu" "GPU Internals" > "$dir/browser/newpage_mutates_page"
  : > "$dir/browser/unprobeable_2"

  set +e
  out=$(FM_BROWSER_QA_LEDGER="$dir/runs.jsonl" \
    run_qa "$fakebin" "$dir/browser" --url "$target_url" --out "$dir/evidence")
  status=$?
  set -e

  expect_code 1 "$status" "authoritative auth redirect should exit 1"
  assert_contains "$out" "blocked: authenticated browser session expired; sign in to the foregrounded QA Chrome window, then rerun" \
    "authoritative auth redirect should retain the exact session-expired message"
  assert_not_contains "$out" "could not prove browser page 2 identity" \
    "unprobeable fallback should not preempt the authoritative auth verdict"
  assert_not_contains "$out" "exact QA URL is not open after navigation" \
    "authoritative auth redirect should not fall through to generic navigation failure"
  assert_ledger_block_reason "$dir/runs.jsonl" "page-scan" \
    "authenticated browser session expired; sign in to the foregrounded QA Chrome window, then rerun" \
    "authoritative auth redirect should record the distinct authentication-expired reason"
  pass "fm-browser-qa.sh: authoritative auth precedes fallback probing"
}

test_unprobeable_fallback_preserves_navigation_failure() {
  local dir fakebin out status target_url
  dir="$TMP_ROOT/unprobeable-fallback"
  fakebin=$(make_fake_browser_tools "$dir")
  target_url="https://example.test/qa"
  write_page "$dir/browser" 1 "https://example.test/other" "Other"
  printf '%s\n' 1 > "$dir/browser/newpage_reuses_page"
  printf '%s\t%s\n' "https://example.test/elsewhere" "Elsewhere" > "$dir/browser/newpage_redirect"
  printf '%s\t%s\t%s\n' 2 "chrome://gpu" "GPU Internals" > "$dir/browser/newpage_mutates_page"
  : > "$dir/browser/unprobeable_2"

  set +e
  out=$(FM_BROWSER_QA_LEDGER="$dir/runs.jsonl" \
    run_qa "$fakebin" "$dir/browser" --url "$target_url" --out "$dir/evidence")
  status=$?
  set -e

  expect_code 1 "$status" "unresolved navigation with unprobeable fallback should exit 1"
  assert_contains "$out" "blocked: exact QA URL is not open after navigation: $target_url" \
    "unprobeable fallback should preserve the exact generic navigation message"
  assert_not_contains "$out" "could not prove browser page 2 identity" \
    "unprobeable fallback should not replace the navigation classification"
  assert_ledger_block_reason "$dir/runs.jsonl" "page-scan" \
    "exact QA URL is not open after navigation: $target_url" \
    "unprobeable fallback should record the distinct generic exact-URL reason"
  pass "fm-browser-qa.sh: unprobeable fallback preserves navigation failure"
}

test_duplicate_non_target_landing_preserves_exact_url_blocker() {
  local dir fakebin out status title index=0 target_url='https://example.test/qa'
  for title in 'Dashboard' 'Dashboard [selected]'; do
    index=$((index + 1))
    dir="$TMP_ROOT/duplicate-non-target-landing-$index"
    fakebin=$(make_fake_browser_tools "$dir")
    write_page "$dir/browser" 1 'https://example.test/dashboard' "$title"
    printf '%s\t%s\n' 'https://example.test/dashboard' "$title" > "$dir/browser/newpage_redirect"

    set +e
    out=$(FM_BROWSER_QA_LEDGER="$dir/runs.jsonl" \
      run_qa "$fakebin" "$dir/browser" --url "$target_url" --out "$dir/evidence")
    status=$?
    set -e

    expect_code 1 "$status" "a duplicate non-target landing should block the exact QA URL"
    assert_contains "$out" "blocked: exact QA URL is not open after navigation: $target_url" \
      "identical non-target tabs must preserve the exact-URL classification"
    assert_not_contains "$out" 'could not prove browser landing page identity' \
      "the selected landing should remain identifiable beside an identical tab"
    assert_ledger_block_reason "$dir/runs.jsonl" 'page-scan' \
      "exact QA URL is not open after navigation: $target_url" \
      "the duplicate redirect should record the exact-URL reason"
    [ "$(cat "$dir/browser/selected")" = 2 ] || fail "the redirected landing should remain selected"
    assert_present "$dir/browser/page_1" "the existing non-target tab must remain open"
    assert_present "$dir/browser/page_2" "the redirect fixture must create a second non-target tab"
    assert_absent "$dir/evidence/identity.json" "a non-target landing must not publish successful identity"
  done
  pass "fm-browser-qa.sh: identical non-target landings preserve the exact-URL blocker"
}

test_unprobeable_unrelated_tab_is_skipped() {
  local dir fakebin evidence
  dir="$TMP_ROOT/unprobeable-other"
  fakebin=$(make_fake_browser_tools "$dir")
  write_page "$dir/browser" 1 "chrome://gpu" "GPU Internals"
  : > "$dir/browser/unprobeable_1"
  write_page "$dir/browser" 2 "https://example.test/qa" "QA Page"
  evidence="$dir/evidence"

  run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$evidence" >/dev/null

  assert_present "$evidence/identity.json" "identity evidence missing despite healthy target tab"
  assert_grep "skipped browser page 1: could not probe it" "$evidence/report.md" \
    "report missing skipped-tab warning"
  pass "fm-browser-qa.sh: unprobeable unrelated tab is skipped, not blocking"
}

test_unrelated_sign_in_tab_does_not_report_auth_expired() {
  local dir fakebin out status
  dir="$TMP_ROOT/signin-other"
  fakebin=$(make_fake_browser_tools "$dir")
  write_page "$dir/browser" 1 "https://github.com/" "GitHub"
  printf '%s\t%s\t%s\n' 1 "https://github.com/login" "Sign in to GitHub" > "$dir/browser/newpage_mutates_page"
  printf '%s\t%s\n' "https://example.test/elsewhere" "Elsewhere" > "$dir/browser/newpage_redirect"

  set +e
  out=$(FM_BROWSER_QA_LEDGER="$dir/runs.jsonl" \
    run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$dir/evidence")
  status=$?
  set -e
  expect_code 1 "$status" "unresolved navigation should exit 1"
  assert_not_contains "$out" "authenticated browser session expired" \
    "unrelated sign-in tab must not trigger the auth verdict"
  assert_contains "$out" "blocked: exact QA URL is not open after navigation" \
    "unresolved navigation should report the navigation failure"
  assert_ledger_block_reason "$dir/runs.jsonl" "page-scan" \
    "exact QA URL is not open after navigation: https://example.test/qa" \
    "unresolved navigation should record the distinct generic exact-URL reason"
  pass "fm-browser-qa.sh: unrelated sign-in tab does not fake an auth verdict"
}

test_sign_in_substring_title_is_not_auth() {
  local dir fakebin evidence
  dir="$TMP_ROOT/signin-substring"
  fakebin=$(make_fake_browser_tools "$dir")
  write_page "$dir/browser" 1 "https://example.test/qa" "Assign in bulk"
  evidence="$dir/evidence"

  run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$evidence" >/dev/null

  assert_present "$evidence/identity.json" "identity evidence missing for non-auth title"
  pass "fm-browser-qa.sh: 'sign in' substring inside a word is not an auth verdict"
}

test_trailing_slash_url_is_normalized() {
  local dir fakebin evidence
  dir="$TMP_ROOT/normalize"
  fakebin=$(make_fake_browser_tools "$dir")
  write_page "$dir/browser" 1 "https://example.test/" "Home"
  evidence="$dir/evidence"

  run_qa "$fakebin" "$dir/browser" --url "https://example.test" --out "$evidence" >/dev/null

  node -e 'const fs=require("fs"); const j=JSON.parse(fs.readFileSync(process.argv[1])); if (j.requested_url !== "https://example.test" || j.active_url !== "https://example.test/") process.exit(1)' "$evidence/identity.json" \
    || fail "identity evidence did not record requested vs browser-normalized URL"
  assert_absent "$dir/browser/newpage.log" "normalized match should not open a new tab"
  pass "fm-browser-qa.sh: browser-equivalent trailing-slash URL matches without a new tab"
}

test_attached_identity_rediscovers_page_when_fresh_session_ids_differ() {
  local dir fakebin identity evidence out eval_out
  dir="$TMP_ROOT/attach-id-churn"
  fakebin=$(make_fake_browser_tools "$dir")
  identity="$dir/wrapper/identity.json"
  evidence="$dir/evidence"
  write_identity_json "$identity" 5 "https://teachers.example.test/login" "Login | Teacher Portal"
  write_page "$dir/browser" 3 "https://teachers.example.test/login" "Login | Teacher Portal"
  write_page "$dir/browser" 5 "https://feature.example.test/student/progress" "My Progress"

  out=$(run_qa "$fakebin" "$dir/browser" --select-identity "$identity" --axi-session followup --out "$evidence")

  assert_contains "$out" "ok: selected attached browser QA page 3 in AXI session followup" \
    "attached resolver should select the fresh session-local target id"
  [ "$(cat "$dir/browser/selected")" = 3 ] \
    || fail "attached resolver selected the stale wrapper page id instead of the rediscovered target"
  node - "$evidence/attached-identity.json" <<'NODE' || fail "attached resolver evidence should record the fresh page and stale source id distinctly"
const fs = require('fs');
const identity = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (identity.page_id !== '3') process.exit(1);
if (identity.source_page_id !== '5') process.exit(1);
if (identity.active_url !== 'https://teachers.example.test/login') process.exit(1);
if (identity.title !== 'Login | Teacher Portal') process.exit(1);
NODE
  eval_out=$(env \
    "PATH=$fakebin:/usr/bin:/bin" \
    "FM_FAKE_BROWSER_DIR=$dir/browser" \
    "CHROME_DEVTOOLS_AXI_BROWSER_URL=http://127.0.0.1:9222" \
    "CHROME_DEVTOOLS_AXI_SESSION=followup" \
    chrome-devtools-axi eval '({href: location.href, title: document.title})')
  assert_contains "$eval_out" "https://teachers.example.test/login" \
    "caller-owned attached AXI session should be ready for the intended page"
  assert_absent "$dir/browser/axi_stopped" \
    "attached resolver should leave the caller-owned AXI session available"
  pass "fm-browser-qa.sh: attached identity rediscovers a fresh session-local page id"
}

test_attached_identity_uses_title_to_select_unique_duplicate_url() {
  local dir fakebin identity out title index=0
  for title in 'Classes | Teacher Portal' 'C:\new\tab' $'Classes\tPortal'; do
    index=$((index + 1))
    dir="$TMP_ROOT/attach-title-disambiguates-$index"
    fakebin=$(make_fake_browser_tools "$dir")
    identity="$dir/wrapper/identity.json"
    write_identity_json "$identity" 4 "https://teachers.example.test/classes" "$title"
    write_page "$dir/browser" 1 "https://teachers.example.test/classes" "Loading"
    write_page "$dir/browser" 7 "https://teachers.example.test/classes" "$title"

    out=$(run_qa "$fakebin" "$dir/browser" --select-identity "$identity" --axi-session followup-title)

    assert_contains "$out" "ok: selected attached browser QA page 7 in AXI session followup-title" \
      "attached resolver should use the literal verified title to choose the unique matching URL"
    [ "$(cat "$dir/browser/selected")" = 7 ] \
      || fail "attached resolver did not select the unique URL/title match"
  done
  pass "fm-browser-qa.sh: attached identity uses literal titles to select a unique duplicate URL"
}

test_page_inventory_preserves_titled_urls_and_selection() {
  local dir fakebin identity title index=0 url='https://teachers.example.test/qa(a,b)?filter=(x,y)'
  for title in '' 'Classes' 'Classes [selected] (Review), café' 'A long classroom page title with more than fifty characters in its full title'; do
    index=$((index + 1))
    dir="$TMP_ROOT/inventory-titles-$index"
    fakebin=$(make_fake_browser_tools "$dir")
    identity="$dir/wrapper/identity.json"
    write_identity_json "$identity" 5 "$url" "$title"
    write_page "$dir/browser" 7 "$url" "$title"
    run_qa "$fakebin" "$dir/browser" --select-identity "$identity" --axi-session inventory-titles --out "$dir/evidence" >/dev/null \
      || fail "titled MCP inventory should preserve the selected page URL"
    node - "$identity" "$dir/evidence/attached-identity.json" <<'NODE' || fail "inventory normalization must preserve the full evaluated identity"
const fs = require('fs');
const [expected, actual] = process.argv.slice(2).map(file => JSON.parse(fs.readFileSync(file, 'utf8')));
if (actual.page_id !== '7' || actual.active_url !== expected.active_url || actual.title !== expected.title) process.exit(1);
NODE
  done
  pass "fm-browser-qa.sh: inventory preserves titled and untitled selected URLs"
}

test_opaque_url_tabs_preserve_target_selection() {
  local dir fakebin identity evidence out mode url='https://teachers.example.test/classes'
  for mode in qa attach; do
    dir="$TMP_ROOT/inventory-opaque-$mode"
    fakebin=$(make_fake_browser_tools "$dir")
    identity="$dir/wrapper/identity.json"
    write_identity_json "$identity" 5 "$url" 'Classes'
    write_page "$dir/browser" 2 'data:text/plain,Hello world' ''
    write_page "$dir/browser" 3 'data:text/plain,Hello world (example)' 'Plain text'
    write_page "$dir/browser" 4 'data:text/plain,Hello world [selected]' ''
    write_page "$dir/browser" 5 'data:text/plain,Hello world [selected] isolatedContext=space' ''
    write_page "$dir/browser" 7 "$url" 'Classes'
    printf '7\n' > "$dir/browser/selected"

    if [ "$mode" = attach ]; then
      out=$(run_qa "$fakebin" "$dir/browser" --select-identity "$identity" \
        --axi-session inventory-opaque --out "$dir/evidence") \
        || fail "opaque URL tabs must not block attachment to a healthy target"
      evidence="$dir/evidence/attached-identity.json"
    else
      out=$(run_qa "$fakebin" "$dir/browser" --url "$url" --out "$dir/evidence") \
        || fail "opaque URL tabs must not block existing-tab QA"
      evidence="$dir/evidence/identity.json"
    fi
    assert_not_contains "$out" 'skipped browser page' "titled and untitled opaque URLs should remain probeable when selected"
    assert_absent "$dir/browser/newpage.log" "mixed inventory should reuse the healthy exact target"
    [ "$(cat "$dir/browser/selected")" = 7 ] || fail "mixed inventory must leave the verified target selected"
    node - "$evidence" "$url" <<'NODE' || fail "mixed inventory must publish the current target identity"
const fs = require('fs');
const [file, url] = process.argv.slice(2);
const identity = JSON.parse(fs.readFileSync(file, 'utf8'));
if (identity.page_id !== '7' || identity.active_url !== url || identity.title !== 'Classes') process.exit(1);
NODE
  done
  pass "fm-browser-qa.sh: literal selection metadata in opaque URLs allows healthy target QA and attachment"
}

test_real_mcp_to_axi_inventory_conversion() {
  local dir fakebin identity axi_cli out mode
  if [ -z "$REAL_AXI_BIN" ] || [ ! -f "$REAL_MCP_RESPONSE" ]; then
    pass "fm-browser-qa.sh: real MCP/AXI inventory conversion (skip: installed dependencies unavailable)"
    return
  fi
  axi_cli=$("$REAL_AXI_BIN" run <<'NODE'
import fs from 'node:fs';
import path from 'node:path';
const binDir = path.dirname(fs.realpathSync(process.argv[1]));
const pkg = JSON.parse(fs.readFileSync(path.resolve(binDir, '../../package.json'), 'utf8'));
if (pkg.version === '0.1.26') console.log(path.resolve(binDir, '../src/cli.js'));
NODE
  )
  if [ -z "$axi_cli" ]; then
    pass "fm-browser-qa.sh: real MCP/AXI inventory conversion (skip: requires AXI 0.1.26)"
    return
  fi
  for mode in qa attach; do
    dir="$TMP_ROOT/real-inventory-$mode"
    fakebin=$(make_fake_browser_tools "$dir")
    identity="$dir/wrapper/identity.json"
    write_identity_json "$identity" 5 "https://teachers.example.test/classes" 'Classes'
    write_page "$dir/browser" 2 'data:text/plain,Hello world' ''
    write_page "$dir/browser" 3 'data:text/plain,Hello world (example)' 'Plain text'
    write_page "$dir/browser" 4 'data:text/plain,Hello world [selected]' ''
    write_page "$dir/browser" 7 "https://teachers.example.test/classes" 'Classes'
    printf '7\n' > "$dir/browser/selected"
    out=$(env PATH="$fakebin:/usr/bin:/bin" FM_FAKE_BROWSER_DIR="$dir/browser" \
      FM_TEST_MCP_RESPONSE="$REAL_MCP_RESPONSE" FM_TEST_AXI_CLI="$axi_cli" chrome-devtools-axi pages)
    assert_contains "$out" '7,Classes,false' "real AXI conversion must reproduce loss of the titled URL and selected marker"
    assert_contains "$out" '2,data:text/plain,Hello,false' "real AXI conversion should reproduce truncation of an opaque URL containing spaces"

    if [ "$mode" = attach ]; then
      out=$(FM_TEST_MCP_RESPONSE="$REAL_MCP_RESPONSE" FM_TEST_AXI_BRIDGE="${axi_cli%/*}/bridge.js" run_qa "$fakebin" "$dir/browser" \
        --select-identity "$identity" --axi-session real-inventory --out "$dir/evidence") \
        || fail "attachment must accept titled pages emitted by real MCP despite AXI's lossy pages conversion"
      assert_present "$dir/evidence/attached-identity.json" "real MCP attachment should publish evidence"
    else
      out=$(FM_TEST_MCP_RESPONSE="$REAL_MCP_RESPONSE" FM_TEST_AXI_BRIDGE="${axi_cli%/*}/bridge.js" run_qa "$fakebin" "$dir/browser" \
        --url "https://teachers.example.test/classes" --out "$dir/evidence") \
        || fail "existing-tab QA must accept titled pages emitted by real MCP"
      assert_present "$dir/evidence/identity.json" "real MCP QA should publish evidence"
      assert_absent "$dir/browser/newpage.log" "real MCP QA must reuse the existing exact page"
    fi
    assert_not_contains "$out" 'skipped browser page' "real MCP opaque URLs should remain probeable when selected"
    [ "$(cat "$dir/browser/selected")" = 7 ] || fail "real MCP inventory must retain the verified selected ID"
  done
  pass "fm-browser-qa.sh: real MCP-to-AXI conversion preserves successful titled-page QA through the raw inventory path"
}

test_attached_identity_rejects_existing_session_endpoint_mismatch() {
  local dir fakebin identity out status session
  for session in followup-endpoint default; do
    dir="$TMP_ROOT/attach-endpoint-$session"
    fakebin=$(make_fake_browser_tools "$dir")
    identity="$dir/wrapper/identity.json"
    write_identity_json "$identity" 5 "https://teachers.example.test/classes" "Classes" http://127.0.0.1:9333
    write_page "$dir/browser" 7 "https://teachers.example.test/classes" "Classes"
    run_qa "$fakebin" "$dir/browser" --select-identity "$identity" --axi-session "$session" >/dev/null \
      || fail "initial attachment should bind the fresh session"
    run_qa "$fakebin" "$dir/browser" --select-identity "$identity" --axi-session "$session" >/dev/null \
      || fail "existing session at the matching endpoint should be reusable"
    write_identity_json "$identity" 5 "https://teachers.example.test/classes" "Classes"
    : > "$dir/browser/axi.log"

    set +e
    out=$(run_qa "$fakebin" "$dir/browser" --select-identity "$identity" --axi-session "$session" --out "$dir/evidence")
    status=$?
    set -e

    expect_code 1 "$status" "existing wrong-endpoint session should be rejected despite matching URL/title"
    assert_contains "$out" "browser endpoint mismatch: expected http://127.0.0.1:9222 got http://127.0.0.1:9333" \
      "endpoint verification should compare the running bridge connection settings with the identity"
    assert_absent "$dir/evidence/attached-identity.json" "wrong endpoint must not publish successful identity"
    assert_present "$dir/evidence/FAILED.md" "wrong endpoint should publish failure evidence"
    awk -F '\t' '$1 != "start" { exit 1 }' "$dir/browser/axi.log" \
      || fail "wrong endpoint must be refused before enumerating, selecting, or stopping the session"
  done
  pass "fm-browser-qa.sh: attached identity verifies existing named and default session endpoints"
}

test_attached_identity_rejects_unverifiable_session_binding() {
  local dir fakebin identity out status scenario
  for scenario in missing-state wrong-port missing-process ambiguous-settings auto-connect wrong-session; do
    dir="$TMP_ROOT/attach-binding-$scenario"
    fakebin=$(make_fake_browser_tools "$dir")
    identity="$dir/wrapper/identity.json"
    write_identity_json "$identity" 5 "https://teachers.example.test/classes" "Classes"
    write_page "$dir/browser" 7 "https://teachers.example.test/classes" "Classes"
    run_qa "$fakebin" "$dir/browser" --select-identity "$identity" --axi-session followup-binding >/dev/null \
      || fail "initial attachment should succeed"
    case "$scenario" in
      missing-state) printf '{}\n' > "$dir/browser/home/.chrome-devtools-axi/sessions/followup-binding/bridge.pid" ;;
      wrong-port) printf '{"pid":42420,"port":9777}\n' > "$dir/browser/home/.chrome-devtools-axi/sessions/followup-binding/bridge.pid" ;;
      missing-process) : > "$dir/browser/bridge-process.out" ;;
      ambiguous-settings) printf ' CHROME_DEVTOOLS_AXI_BROWSER_URL=http://127.0.0.1:9222\n' >> "$dir/browser/bridge-process.out" ;;
      auto-connect) printf 'node /axi/chrome-devtools-axi-bridge.js CHROME_DEVTOOLS_AXI_SESSION=followup-binding CHROME_DEVTOOLS_AXI_PORT=9666 CHROME_DEVTOOLS_AXI_BROWSER_URL=http://127.0.0.1:9222 CHROME_DEVTOOLS_AXI_AUTO_CONNECT=1\n' > "$dir/browser/bridge-process.out" ;;
      wrong-session) printf 'node /axi/chrome-devtools-axi-bridge.js CHROME_DEVTOOLS_AXI_SESSION=other CHROME_DEVTOOLS_AXI_PORT=9666 CHROME_DEVTOOLS_AXI_BROWSER_URL=http://127.0.0.1:9222\n' > "$dir/browser/bridge-process.out" ;;
    esac
    : > "$dir/browser/axi.log"

    set +e
    out=$(run_qa "$fakebin" "$dir/browser" --select-identity "$identity" --axi-session followup-binding --out "$dir/evidence")
    status=$?
    set -e

    expect_code 1 "$status" "unverifiable session binding should be rejected: $scenario"
    assert_contains "$out" "blocked: could not verify attached AXI session browser endpoint" \
      "unverifiable binding should have an actionable blocker"
    awk -F '\t' '$1 != "start" { exit 1 }' "$dir/browser/axi.log" \
      || fail "unverifiable binding must be refused before page enumeration or selection"
    assert_absent "$dir/evidence/attached-identity.json" "unverifiable binding must not publish successful identity"
  done
  pass "fm-browser-qa.sh: attached identity refuses unverifiable session bindings"
}

test_attached_identity_reads_live_bridge_connection_settings() {
  local dir fakebin identity bridge_pid out status success_status
  dir="$TMP_ROOT/attach-live-binding"
  fakebin=$(make_fake_browser_tools "$dir")
  identity="$dir/wrapper/identity.json"
  write_identity_json "$identity" 5 "https://teachers.example.test/classes" "Classes"
  write_page "$dir/browser" 7 "https://teachers.example.test/classes" "Classes"
  mkdir -p "$dir/browser/home/.chrome-devtools-axi/sessions/live-binding"
  : > "$dir/browser/inspect_real_bridge"
  printf 'setInterval(() => {}, 1000);\n' > "$dir/chrome-devtools-axi-bridge.js"
  env CHROME_DEVTOOLS_AXI_SESSION=live-binding CHROME_DEVTOOLS_AXI_PORT=9666 \
    CHROME_DEVTOOLS_AXI_BROWSER_URL=http://127.0.0.1:9333 CHROME_DEVTOOLS_AXI_AUTO_CONNECT=0 \
    "$REAL_NODE" "$dir/chrome-devtools-axi-bridge.js" >/dev/null 2>&1 &
  bridge_pid=$!
  printf '{"pid":%s,"port":9666}\n' "$bridge_pid" > "$dir/browser/home/.chrome-devtools-axi/sessions/live-binding/bridge.pid"

  set +e
  out=$(run_qa "$fakebin" "$dir/browser" --select-identity "$identity" --axi-session live-binding --out "$dir/evidence")
  status=$?
  write_identity_json "$identity" 5 "https://teachers.example.test/classes" "Classes" http://127.0.0.1:9333
  run_qa "$fakebin" "$dir/browser" --select-identity "$identity" --axi-session live-binding --out "$dir/evidence" >/dev/null
  success_status=$?
  kill "$bridge_pid" >/dev/null 2>&1
  wait "$bridge_pid" >/dev/null 2>&1
  set -e

  expect_code 1 "$status" "live bridge endpoint mismatch should be rejected"
  assert_contains "$out" "browser endpoint mismatch: expected http://127.0.0.1:9222 got http://127.0.0.1:9333" \
    "binding check should read the actual running bridge environment"
  expect_code 0 "$success_status" "matching live bridge endpoint should permit attachment"
  assert_present "$dir/evidence/attached-identity.json" "matching live bridge should publish attachment evidence"
  pass "fm-browser-qa.sh: attached identity reads connection settings from a live bridge process"
}

test_attached_identity_explicit_endpoint_overrides_ambient_auto_connect() {
  local dir fakebin identity
  dir="$TMP_ROOT/attach-ambient-auto-connect"
  fakebin=$(make_fake_browser_tools "$dir")
  identity="$dir/wrapper/identity.json"
  write_identity_json "$identity" 5 "https://teachers.example.test/classes" "Classes"
  write_page "$dir/browser" 7 "https://teachers.example.test/classes" "Classes"

  CHROME_DEVTOOLS_AXI_AUTO_CONNECT=1 run_qa "$fakebin" "$dir/browser" \
    --select-identity "$identity" --axi-session followup-auto --out "$dir/evidence" >/dev/null \
    || fail "explicit identity endpoint should override ambient auto-connect for a fresh session"
  assert_present "$dir/evidence/attached-identity.json" "fresh session should attach to the explicit browser endpoint"
  pass "fm-browser-qa.sh: attached identity overrides ambient auto-connect for fresh sessions"
}

test_attached_identity_rejects_bridge_replacement_during_selection() {
  local dir fakebin identity boundary out status
  for boundary in pages:1 selectpage:1 eval:1 selectpage:2 eval:2; do
    dir="$TMP_ROOT/attach-replacement-${boundary/:/-}"
    fakebin=$(make_fake_browser_tools "$dir")
    identity="$dir/wrapper/identity.json"
    write_identity_json "$identity" 5 "https://teachers.example.test/classes" "Classes"
    write_page "$dir/browser" 7 "https://teachers.example.test/classes" "Classes"
    printf '%s %s\n' "${boundary%:*}" "${boundary#*:}" > "$dir/browser/replace_bridge_at"

    set +e
    out=$(run_qa "$fakebin" "$dir/browser" --select-identity "$identity" --axi-session followup-replacement --out "$dir/evidence")
    status=$?
    set -e

    assert_present "$dir/browser/bridge_replaced" "test must replace the bridge at $boundary"
    expect_code 1 "$status" "replacement at $boundary must invalidate attachment"
    assert_contains "$out" "AXI session bridge changed during attachment" \
      "same-endpoint replacement at $boundary should report lost bridge continuity"
    assert_not_contains "$out" "ok: selected attached browser QA page" "replacement must not report success"
    assert_present "$dir/evidence/FAILED.md" "replacement must leave failure evidence"
    assert_absent "$dir/evidence/attached-identity.json" "replacement must not publish stale identity"
    assert_absent "$dir/evidence/attached-report.md" "replacement must not publish stale report"
    [ "$(tail -n 1 "$dir/browser/axi.log")" = bridge-replaced ] \
      || fail "attachment must stop sending AXI commands after bridge replacement"
  done
  pass "fm-browser-qa.sh: attached identity rejects bridge replacement throughout discovery and selection"
}

test_attached_identity_preserves_final_selection_without_restart() {
  local dir fakebin identity out
  dir="$TMP_ROOT/attach-final-binding"
  fakebin=$(make_fake_browser_tools "$dir")
  identity="$dir/wrapper/identity.json"
  write_identity_json "$identity" 5 "https://teachers.example.test/classes" "Classes"
  write_page "$dir/browser" 7 "https://teachers.example.test/classes" "Classes"
  printf 'start 2\n' > "$dir/browser/replace_bridge_at"
  : > "$dir/browser/reconnect_during_probe_health"

  out=$(run_qa "$fakebin" "$dir/browser" --select-identity "$identity" --axi-session followup-final --out "$dir/evidence")

  assert_contains "$out" "ok: selected attached browser QA page 7" "stable attachment should succeed"
  assert_absent "$dir/browser/bridge_replaced" "final binding verification must not restart the bridge"
  assert_absent "$dir/browser/health_reconnected" "probe commands must not reconnect MCP through an intermediate health check"
  [ "$(wc -l < "$dir/browser/bridge-health.log" | tr -d '[:space:]')" = 1 ] \
    || fail "bridge readiness should be established only before discovery"
  [ "$(cat "$dir/browser/selected")" = 7 ] || fail "caller must retain the verified selected page"
  node - "$dir/evidence/attached-identity.json" "$dir/browser/selected" <<'NODE' || fail "published page ID must describe the caller's selected page"
const fs = require('fs');
const [identityFile, selectedFile] = process.argv.slice(2);
const identity = JSON.parse(fs.readFileSync(identityFile, 'utf8'));
if (identity.page_id !== fs.readFileSync(selectedFile, 'utf8').trim()) process.exit(1);
NODE
  pass "fm-browser-qa.sh: final attachment verification preserves the original bridge and selected page"
}

test_page_probes_reject_mcp_reconnection_with_unchanged_bridge() {
  local dir fakebin identity mode boundary out status
  for mode in attach qa; do
    for boundary in eval:2 pages:3; do
      dir="$TMP_ROOT/probe-mcp-reconnect-$mode-${boundary/:/-}"
      fakebin=$(make_fake_browser_tools "$dir")
      identity="$dir/wrapper/identity.json"
      write_identity_json "$identity" 5 "https://teachers.example.test/classes" "Classes"
      write_page "$dir/browser" 7 "https://teachers.example.test/classes" "Classes"
      printf '%s %s\n' "${boundary%:*}" "${boundary#*:}" > "$dir/browser/reconnect_mcp_before"

      set +e
      if [ "$mode" = attach ]; then
        out=$(run_qa "$fakebin" "$dir/browser" --select-identity "$identity" --axi-session followup-mcp --out "$dir/evidence")
      else
        out=$(run_qa "$fakebin" "$dir/browser" --url "https://teachers.example.test/classes" --out "$dir/evidence")
      fi
      status=$?
      set -e

      assert_present "$dir/browser/mcp_reconnected" "test must reconnect MCP before $boundary in $mode mode"
      expect_code 1 "$status" "MCP reconnection during the final probe must invalidate the discovered page ID"
      assert_contains "$out" "MCP browser context changed during page probe" \
        "MCP reconnection must be detected despite matching evaluated URL and title"
      assert_present "$dir/evidence/FAILED.md" "MCP reconnection should leave failure evidence"
      assert_absent "$dir/evidence/attached-identity.json" "MCP reconnection must not publish a stale attachment ID"
      assert_absent "$dir/evidence/identity.json" "MCP reconnection must not publish a stale QA page ID"
      assert_absent "$dir/evidence/attached-report.md" "MCP reconnection must not publish attachment success"
      assert_absent "$dir/evidence/report.md" "MCP reconnection must not publish QA success"
      node - "$dir/browser/page_1" "$identity" <<'NODE' || fail "reconnection fixture must preserve the expected URL and title"
const fs = require('fs');
const [pageFile, identityFile] = process.argv.slice(2);
const identity = JSON.parse(fs.readFileSync(identityFile, 'utf8'));
const [url, title] = fs.readFileSync(pageFile, 'utf8').trimEnd().split('\t');
if (identity.active_url !== url || identity.title !== title) process.exit(1);
NODE
      if [ "$mode" = attach ]; then
        node - "$dir/browser/bridge-before-mcp-reconnect.json" "$dir/browser/home/.chrome-devtools-axi/sessions/followup-mcp/bridge.pid" <<'NODE' || fail "MCP reconnect must leave the AXI bridge PID and port unchanged"
const fs = require('fs');
const [before, after] = process.argv.slice(2).map(file => JSON.parse(fs.readFileSync(file, 'utf8')));
if (before.pid !== 42420 || before.port !== 9666 || before.pid !== after.pid || before.port !== after.port) process.exit(1);
NODE
      fi
    done
  done
  pass "fm-browser-qa.sh: shared page probes reject MCP reconnection without bridge replacement"
}

test_page_probes_reject_selection_changes_after_evaluation() {
  local dir fakebin identity mode scenario out status
  for mode in attach qa; do
    for scenario in different same-identity; do
      dir="$TMP_ROOT/probe-selection-change-$mode-$scenario"
      fakebin=$(make_fake_browser_tools "$dir")
      identity="$dir/wrapper/identity.json"
      write_identity_json "$identity" 5 'https://teachers.example.test/classes' 'Classes'
      write_page "$dir/browser" 1 'https://teachers.example.test/dashboard' 'Dashboard'
      write_page "$dir/browser" 2 'data:text/plain,Hello world [selected]' ''
      write_page "$dir/browser" 7 'https://teachers.example.test/classes' 'Classes'
      printf '7 2 1\n' > "$dir/browser/switch_selection_after_eval"
      [ "$scenario" != same-identity ] || : > "$dir/browser/copy_identity_on_selection_switch"

      set +e
      if [ "$mode" = attach ]; then
        out=$(run_qa "$fakebin" "$dir/browser" --select-identity "$identity" --axi-session followup-selection --out "$dir/evidence")
      else
        out=$(run_qa "$fakebin" "$dir/browser" --url 'https://teachers.example.test/classes' --out "$dir/evidence")
      fi
      status=$?
      set -e

      assert_present "$dir/browser/selection_switched" "the fixture must change selection after the final page evaluation"
      expect_code 1 "$status" "an ordinary selection change must invalidate the final page probe"
      assert_contains "$out" 'browser page identity or selection changed while confirming page 7' \
        "the probe must reject a changed selection even when URL/title still match"
      [ "$(cat "$dir/browser/selected")" = 1 ] || fail "the fixture should leave the other page selected"
      assert_absent "$dir/browser/bridge_replaced" "the selection change must not replace the bridge"
      assert_absent "$dir/browser/mcp_reconnected" "the selection change must not reconnect MCP"
      assert_present "$dir/evidence/FAILED.md" "selection drift should leave failure evidence"
      assert_absent "$dir/evidence/identity.json" "selection drift must not publish successful QA identity"
      assert_absent "$dir/evidence/attached-identity.json" "selection drift must not publish successful attachment identity"
      assert_absent "$dir/evidence/report.md" "selection drift must not publish a QA success report"
      assert_absent "$dir/evidence/attached-report.md" "selection drift must not publish an attachment success report"
    done
  done
  pass "fm-browser-qa.sh: shared probes reject ordinary selection changes after identity evaluation"
}

test_attached_identity_successful_retry_clears_failure_marker() {
  local dir fakebin identity status
  dir="$TMP_ROOT/attach-retry"
  fakebin=$(make_fake_browser_tools "$dir")
  identity="$dir/wrapper/identity.json"
  write_identity_json "$identity" 5 "https://teachers.example.test/classes" "Classes"
  write_page "$dir/browser" 7 "https://teachers.example.test/dashboard" "Dashboard"

  set +e
  run_qa "$fakebin" "$dir/browser" --select-identity "$identity" --axi-session followup-retry --out "$dir/evidence" >/dev/null
  status=$?
  set -e
  expect_code 1 "$status" "first attachment should fail without a matching page"
  assert_present "$dir/evidence/FAILED.md" "first attachment should leave a failure marker"
  write_page "$dir/browser" 7 "https://teachers.example.test/classes" "Classes"

  mkdir "$dir/evidence/attached-report.md"
  set +e
  run_qa "$fakebin" "$dir/browser" --select-identity "$identity" --axi-session followup-retry --out "$dir/evidence" >/dev/null
  status=$?
  set -e
  expect_code 1 "$status" "failed report publication must not succeed"
  assert_present "$dir/evidence/FAILED.md" "failed publication must retain failure evidence"
  rmdir "$dir/evidence/attached-report.md"

  run_qa "$fakebin" "$dir/browser" --select-identity "$identity" --axi-session followup-retry --out "$dir/evidence" >/dev/null \
    || fail "retry should succeed once the page matches and evidence can be published"
  assert_present "$dir/evidence/attached-identity.json" "successful retry should publish attachment identity"
  assert_present "$dir/evidence/attached-report.md" "successful retry should publish attachment report"
  assert_absent "$dir/evidence/FAILED.md" "successful retry should clear the stale failure marker"
  pass "fm-browser-qa.sh: successful attachment retry clears failure marker after publication"
}

test_attached_identity_zero_exact_matches_refused() {
  local dir fakebin identity out status
  dir="$TMP_ROOT/attach-zero-match"
  fakebin=$(make_fake_browser_tools "$dir")
  identity="$dir/wrapper/identity.json"
  write_identity_json "$identity" 5 "https://teachers.example.test/login" "Login | Teacher Portal"
  write_page "$dir/browser" 1 "https://teachers.example.test/dashboard" "Dashboard"

  set +e
  out=$(run_qa "$fakebin" "$dir/browser" --select-identity "$identity" --axi-session followup-zero --out "$dir/evidence")
  status=$?
  set -e

  expect_code 1 "$status" "attached resolver should exit 1 when no exact URL matches"
  assert_contains "$out" "blocked: no browser tabs match attached browser QA identity URL: https://teachers.example.test/login" \
    "attached resolver should report the missing exact URL"
  assert_absent "$dir/evidence/attached-identity.json" \
    "attached resolver should not write success evidence when no page matches"
  pass "fm-browser-qa.sh: attached identity refuses zero exact URL matches"
}

test_attached_identity_indistinguishable_matches_refused() {
  local dir fakebin identity out status
  dir="$TMP_ROOT/attach-ambiguous"
  fakebin=$(make_fake_browser_tools "$dir")
  identity="$dir/wrapper/identity.json"
  write_identity_json "$identity" 5 "https://teachers.example.test/classes" "Classes | Teacher Portal"
  write_page "$dir/browser" 3 "https://teachers.example.test/classes" "Classes | Teacher Portal"
  write_page "$dir/browser" 8 "https://teachers.example.test/classes" "Classes | Teacher Portal"

  set +e
  out=$(run_qa "$fakebin" "$dir/browser" --select-identity "$identity" --axi-session followup-ambiguous --out "$dir/evidence")
  status=$?
  set -e

  expect_code 1 "$status" "attached resolver should exit 1 on indistinguishable matches"
  assert_contains "$out" "blocked: multiple tabs match attached browser QA identity URL and title; cannot choose a unique page" \
    "attached resolver should refuse indistinguishable URL/title matches"
  assert_absent "$dir/evidence/attached-identity.json" \
    "attached resolver should not write success evidence for ambiguous matches"
  pass "fm-browser-qa.sh: attached identity refuses indistinguishable exact matches"
}

test_attached_identity_post_selection_drift_refused() {
  local dir fakebin identity out status
  dir="$TMP_ROOT/attach-drift"
  fakebin=$(make_fake_browser_tools "$dir")
  identity="$dir/wrapper/identity.json"
  write_identity_json "$identity" 5 "https://teachers.example.test/login" "Login | Teacher Portal"
  write_page "$dir/browser" 2 "https://teachers.example.test/login" "Login | Teacher Portal"
  : > "$dir/browser/mismatch_on_final"

  set +e
  out=$(run_qa "$fakebin" "$dir/browser" --select-identity "$identity" --axi-session followup-drift --out "$dir/evidence")
  status=$?
  set -e

  expect_code 1 "$status" "attached resolver should exit 1 when the page drifts after candidate resolution"
  assert_contains "$out" "blocked: attached browser page drifted after selection: expected https://teachers.example.test/login got https://example.test/wrong" \
    "attached resolver should report post-selection page drift"
  assert_absent "$dir/evidence/attached-identity.json" \
    "attached resolver should not write success evidence after post-selection drift"
  pass "fm-browser-qa.sh: attached identity refuses post-selection page drift"
}

test_successful_evidence_cleans_up_axi_session() {
  local dir fakebin evidence tmp_root
  dir="$TMP_ROOT/cleanup-success"
  fakebin=$(make_fake_browser_tools "$dir")
  write_page "$dir/browser" 1 "https://example.test/qa" "QA Page"
  evidence="$dir/evidence"
  tmp_root="$dir/tmp"
  mkdir -p "$tmp_root"

  TMPDIR="$tmp_root" run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$evidence" --session cleanup >/dev/null

  assert_axi_cleanup "$dir/browser" "$evidence/identity.json" \
    "successful evidence should stop its own AXI session without closing QA Chrome"
  assert_present "$dir/browser/axi_stopped" "successful evidence should stop the AXI bridge"
  assert_tmp_root_empty "$tmp_root" "successful evidence should remove its temporary files"
  pass "fm-browser-qa.sh: successful evidence cleans up its AXI bridge"
}

test_cleanup_error_preserves_original_status() {
  local dir fakebin evidence out status failure_dir failure_fakebin
  dir="$TMP_ROOT/cleanup-stop-fail-success"
  fakebin=$(make_fake_browser_tools "$dir")
  write_page "$dir/browser" 1 "https://example.test/qa" "QA Page"
  : > "$dir/browser/stop_fail"
  evidence="$dir/evidence"

  set +e
  run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$evidence" >/dev/null
  status=$?
  set -e

  expect_code 0 "$status" "cleanup failure should preserve a successful evidence status"
  assert_present "$evidence/report.md" "cleanup failure should not mask successful evidence"
  assert_present "$dir/browser/axi_stopped" "cleanup should still attempt to stop the AXI bridge"

  failure_dir="$TMP_ROOT/cleanup-stop-fail-evidence"
  failure_fakebin=$(make_fake_browser_tools "$failure_dir")
  write_page "$failure_dir/browser" 1 "https://example.test/qa" "QA Page"
  : > "$failure_dir/browser/snapshot_fail"
  : > "$failure_dir/browser/stop_fail"

  set +e
  out=$(run_qa "$failure_fakebin" "$failure_dir/browser" --url "https://example.test/qa" --out "$failure_dir/evidence")
  status=$?
  set -e

  expect_code 1 "$status" "cleanup failure should preserve a failed evidence status"
  assert_contains "$out" "blocked: snapshot evidence failed" \
    "cleanup failure should not replace the evidence failure"
  assert_present "$failure_dir/browser/axi_stopped" \
    "failed evidence cleanup should still attempt to stop the AXI bridge"
  pass "fm-browser-qa.sh: cleanup errors preserve the original run status"
}

test_snapshot_failure_blocks() {
  local dir fakebin out status
  dir="$TMP_ROOT/snapshot-fail"
  fakebin=$(make_fake_browser_tools "$dir")
  write_page "$dir/browser" 1 "https://example.test/qa" "QA Page"
  : > "$dir/browser/snapshot_fail"

  set +e
  out=$(run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$dir/evidence")
  status=$?
  set -e
  expect_code 1 "$status" "snapshot failure should exit 1"
  assert_contains "$out" "blocked: snapshot evidence failed" \
    "snapshot failure should be blocked"
  assert_axi_cleanup "$dir/browser" "$dir/evidence/identity.json" \
    "snapshot failure should clean up its own AXI session"
  pass "fm-browser-qa.sh: snapshot failure blocks and cleans up"
}

test_screenshot_failure_blocks() {
  local dir fakebin out status
  dir="$TMP_ROOT/screenshot-fail"
  fakebin=$(make_fake_browser_tools "$dir")
  write_page "$dir/browser" 1 "https://example.test/qa" "QA Page"
  : > "$dir/browser/screenshot_fail"

  set +e
  out=$(run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$dir/evidence")
  status=$?
  set -e
  expect_code 1 "$status" "screenshot failure should exit 1"
  assert_contains "$out" "blocked: screenshot evidence failed" \
    "screenshot failure should be blocked"
  pass "fm-browser-qa.sh: screenshot failure blocks"
}

test_screenshot_uses_mcp_writable_temp_then_publishes_evidence() {
  local dir fakebin evidence screenshot_tmp tmp_root
  dir="$TMP_ROOT/screenshot-temp-only"
  fakebin=$(make_fake_browser_tools "$dir")
  write_page "$dir/browser" 1 "https://example.test/qa" "QA Page"
  : > "$dir/browser/screenshot_temp_only"
  evidence="$dir/evidence"
  tmp_root="$dir/tmp"
  mkdir -p "$tmp_root"

  TMPDIR="$tmp_root" run_qa "$fakebin" "$dir/browser" \
    --url "https://example.test/qa" --out "$evidence" >/dev/null

  assert_grep "fake png" "$evidence/screenshot.png" \
    "screenshot captured through MCP's writable temp root was not published as evidence"
  assert_present "$evidence/report.md" \
    "temp-root screenshot capture should complete the evidence report"
  screenshot_tmp=$(tail -1 "$dir/browser/screenshot-path.log")
  assert_absent "$screenshot_tmp" \
    "MCP-writable screenshot staging directory should be removed after the run"
  assert_tmp_root_empty "$tmp_root" \
    "temp-root screenshot capture should clean up its staging file"
  pass "fm-browser-qa.sh: MCP temp-root screenshot is published as evidence"
}

test_console_and_network_failures_warn_only() {
  local dir fakebin evidence
  dir="$TMP_ROOT/warnings"
  fakebin=$(make_fake_browser_tools "$dir")
  write_page "$dir/browser" 1 "https://example.test/qa" "QA Page"
  : > "$dir/browser/console_fail"
  : > "$dir/browser/network_fail"
  evidence="$dir/evidence"

  run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$evidence" >/dev/null

  assert_grep "warning: console capture failed" "$evidence/console.txt" \
    "console failure warning was not written"
  assert_grep "warning: network capture failed" "$evidence/network.txt" \
    "network failure warning was not written"
  assert_grep "console capture failed; see console.txt" "$evidence/report.md" \
    "report missing console warning"
  assert_grep "network capture failed; see network.txt" "$evidence/report.md" \
    "report missing network warning"
  assert_present "$evidence/screenshot.png" "required screenshot missing despite warning-only failures"
  pass "fm-browser-qa.sh: console/network failures warn only"
}

test_signal_cleans_up_axi_session() {
  local dir fakebin pid status tries tmp_root
  dir="$TMP_ROOT/cleanup-signal"
  fakebin=$(make_fake_browser_tools "$dir")
  tmp_root="$dir/tmp"
  mkdir -p "$tmp_root"

  env \
    "PATH=$fakebin:/usr/bin:/bin" \
    "CHROME_DEVTOOLS_AXI_MCP_PATH=/operator/chrome-devtools-mcp.js" \
    "FM_FAKE_BROWSER_DIR=$dir/browser" \
    "FM_BROWSER_QA_OPEN_SETTLE=1" \
    "TMPDIR=$tmp_root" \
    bash "$ROOT/bin/fm-browser-qa.sh" --url "https://example.test/qa" --out "$dir/evidence" > "$dir/output.txt" 2>&1 &
  pid=$!
  tries=200
  while [ ! -e "$dir/browser/newpage_started" ] && [ "$tries" -gt 0 ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
    tries=$((tries - 1))
  done
  if [ ! -e "$dir/browser/newpage_started" ]; then
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    cat "$dir/output.txt" >&2
    fail "signal cleanup test did not reach target-page settling"
  fi
  kill -TERM "$pid"
  set +e
  wait "$pid"
  status=$?
  set -e

  expect_code 143 "$status" "TERM should preserve its signal exit status"
  node - "$dir/browser/axi.log" <<'NODE' || fail "TERM should clean up its own AXI session"
const fs = require('fs');
const rows = fs.readFileSync(process.argv[2], 'utf8').trim().split('\n').filter(Boolean).map((line) => line.split('\t'));
const sessions = new Set(rows.map(([, session]) => session));
const stops = rows.filter(([command]) => command === 'stop');
if (sessions.size !== 1 || stops.length !== 1) process.exit(1);
if (![...sessions].every((session) => /^[A-Za-z0-9._-]{1,64}$/.test(session))) process.exit(1);
if (rows.some(([, , browserUrl]) => browserUrl !== 'http://127.0.0.1:9222')) process.exit(1);
NODE
  assert_tmp_root_empty "$tmp_root" "TERM should remove its temporary files"
  pass "fm-browser-qa.sh: TERM cleans up its AXI bridge"
}

test_signal_during_temp_allocation_removes_temp_dir() {
  local dir fakebin out status tmp_root
  dir="$TMP_ROOT/cleanup-allocation-signal"
  fakebin=$(make_fake_browser_tools "$dir")
  tmp_root="$dir/tmp"
  mkdir -p "$tmp_root"

  cat > "$fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
set -eu
tmp_dir=$(/usr/bin/mktemp "$@")
printf '%s\n' "$tmp_dir"
kill -TERM "$PPID"
SH
  chmod +x "$fakebin/mktemp"

  set +e
  out=$(TMPDIR="$tmp_root" run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$dir/evidence")
  status=$?
  set -e

  expect_code 143 "$status" "TERM during temporary allocation should preserve its signal status"
  assert_tmp_root_empty "$tmp_root" "TERM during temporary allocation should remove its temporary directory"
  assert_absent "$dir/browser/axi.log" "TERM before AXI allocation should not stop an unowned session"
  pass "fm-browser-qa.sh: TERM during temporary allocation cleans up"
}

test_concurrent_logical_session_labels_use_distinct_axi_sessions() {
  local dir fakebin pid_one pid_two status_one status_two tmp_root
  dir="$TMP_ROOT/concurrent-session"
  fakebin=$(make_fake_browser_tools "$dir")
  write_page "$dir/browser" 1 "https://example.test/qa" "QA Page"
  tmp_root="$dir/tmp"
  mkdir -p "$tmp_root"

  TMPDIR="$tmp_root" FM_FAKE_SNAPSHOT_DELAY=0.2 \
    run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$dir/evidence-one" --session collision > "$dir/one.out" &
  pid_one=$!
  TMPDIR="$tmp_root" FM_FAKE_SNAPSHOT_DELAY=0.2 \
    run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$dir/evidence-two" --session collision > "$dir/two.out" &
  pid_two=$!
  set +e
  wait "$pid_one"
  status_one=$?
  wait "$pid_two"
  status_two=$?
  set -e

  expect_code 0 "$status_one" "first concurrent evidence run should succeed"
  expect_code 0 "$status_two" "second concurrent evidence run should succeed"
  node - "$dir/browser/axi.log" "$dir/evidence-one/identity.json" "$dir/evidence-two/identity.json" <<'NODE' || fail "concurrent runs should use distinct valid AXI sessions and clean up both"
const fs = require('fs');
const [logFile, firstIdentityFile, secondIdentityFile] = process.argv.slice(2);
const first = JSON.parse(fs.readFileSync(firstIdentityFile, 'utf8'));
const second = JSON.parse(fs.readFileSync(secondIdentityFile, 'utf8'));
const sessions = new Set([first.axi_session, second.axi_session]);
const rows = fs.readFileSync(logFile, 'utf8').trim().split('\n').filter(Boolean).map((line) => line.split('\t'));
const stopSessions = new Set(rows.filter(([command]) => command === 'stop').map(([, session]) => session));
if (first.session !== 'fmqa-collision' || second.session !== 'fmqa-collision') process.exit(1);
if (sessions.size !== 2 || [...sessions].some((session) => !/^[A-Za-z0-9._-]{1,64}$/.test(session))) process.exit(1);
if (stopSessions.size !== 2 || [...stopSessions].some((session) => !sessions.has(session))) process.exit(1);
if (rows.some(([, session, browserUrl]) => !sessions.has(session) || browserUrl !== first.browser_url)) process.exit(1);
NODE
  assert_tmp_root_empty "$tmp_root" "concurrent runs should remove their temporary files"
  pass "fm-browser-qa.sh: concurrent logical sessions use distinct AXI bridges"
}

if [ "$#" -gt 0 ]; then
  for test_case in "$@"; do
    case "$test_case" in
      test_*) declare -F "$test_case" >/dev/null || fail "unknown browser-QA test: $test_case" ;;
      *) fail "expected a browser-QA test function name" ;;
    esac
    "$test_case"
  done
  exit 0
fi

test_requires_url_and_out
test_missing_chrome_devtools_axi_blocks
test_missing_node_blocks_and_records_ledger
test_pinned_mcp_compatibility_cache_is_installed_once
test_partial_mcp_compatibility_cache_is_repaired
test_concurrent_mcp_cache_install_waits_for_atomic_publish
test_failed_mcp_install_is_not_published
test_invalid_custom_mcp_cache_is_preserved
test_compatibility_lock_refuses_symlink_sidecar
test_explicit_mcp_path_bypasses_compatibility_cache
test_explicit_mcp_path_works_without_home
test_unreachable_target_blocks_before_opening_browser_tab
test_http_error_target_blocks_before_opening_browser_tab
test_curl_timeout_override_preserves_finite_values
test_browser_unreachable_without_start_blocks
test_start_if_needed_uses_persistent_visible_profile
test_start_if_needed_refuses_existing_temporary_profile
test_start_if_needed_allows_existing_operator_profile
test_exact_tab_selected_and_evidence_written
test_no_exact_tab_opens_new_page_then_verifies
test_multiple_exact_tabs_refused
test_selected_url_mismatch_refused
test_auth_blocked_reported
test_delayed_auth_redirect_is_reprobed_authoritatively
test_later_reused_tab_auth_observation_is_reconciled
test_late_new_landing_auth_is_reconciled
test_late_unidentified_landing_auth_is_reconciled
test_authoritative_exact_target_is_accepted
test_authoritative_auth_precedes_unprobeable_fallback
test_unprobeable_fallback_preserves_navigation_failure
test_duplicate_non_target_landing_preserves_exact_url_blocker
test_unprobeable_unrelated_tab_is_skipped
test_unrelated_sign_in_tab_does_not_report_auth_expired
test_sign_in_substring_title_is_not_auth
test_trailing_slash_url_is_normalized
test_attached_identity_rediscovers_page_when_fresh_session_ids_differ
test_attached_identity_uses_title_to_select_unique_duplicate_url
test_page_inventory_preserves_titled_urls_and_selection
test_opaque_url_tabs_preserve_target_selection
test_real_mcp_to_axi_inventory_conversion
test_attached_identity_rejects_existing_session_endpoint_mismatch
test_attached_identity_rejects_unverifiable_session_binding
test_attached_identity_reads_live_bridge_connection_settings
test_attached_identity_explicit_endpoint_overrides_ambient_auto_connect
test_attached_identity_rejects_bridge_replacement_during_selection
test_attached_identity_preserves_final_selection_without_restart
test_page_probes_reject_mcp_reconnection_with_unchanged_bridge
test_page_probes_reject_selection_changes_after_evaluation
test_attached_identity_successful_retry_clears_failure_marker
test_attached_identity_zero_exact_matches_refused
test_attached_identity_indistinguishable_matches_refused
test_attached_identity_post_selection_drift_refused
test_successful_evidence_cleans_up_axi_session
test_cleanup_error_preserves_original_status
test_snapshot_failure_blocks
test_screenshot_failure_blocks
test_screenshot_uses_mcp_writable_temp_then_publishes_evidence
test_console_and_network_failures_warn_only
test_signal_cleans_up_axi_session
test_signal_during_temp_allocation_removes_temp_dir
test_concurrent_logical_session_labels_use_distinct_axi_sessions
