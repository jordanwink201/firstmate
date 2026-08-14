#!/usr/bin/env bash
# Behavior tests for bin/fm-browser-qa.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-browser-qa)
REAL_NODE=$(command -v node || true)

[ -n "$REAL_NODE" ] || fail "node is required for fm-browser-qa tests"

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
if [ -e "$FM_FAKE_BROWSER_DIR/browser_down" ]; then
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

  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
set -eu

dir=${FM_FAKE_BROWSER_DIR:?}
cmd=${1:-}
shift || true
mkdir -p "$dir"
printf '%s\t%s\t%s\n' "$cmd" "${CHROME_DEVTOOLS_AXI_SESSION:-}" "${CHROME_DEVTOOLS_AXI_BROWSER_URL:-}" >> "$dir/axi.log"

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

case "$cmd" in
  pages)
    count=0
    for file in "$dir"/page_*; do
      [ -e "$file" ] && count=$((count + 1))
    done
    printf 'pages[%s]{id,url,selected}:\n' "$count"
    for file in "$dir"/page_*; do
      [ -e "$file" ] || continue
      id=${file##*/page_}
      title=$(cut -f2- "$file")
      printf '  %s,%s,false\n' "$id" "$title"
    done
    printf 'help[2]:\n'
    ;;
  selectpage)
    id=${1:?}
    [ -e "$(page_file "$id")" ] || { echo "no such page: $id" >&2; exit 1; }
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
    id=$(next_id)
    printf '%s\t%s\n' "$href" "$title" > "$(page_file "$id")"
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
    if [ -e "$dir/screenshot_fail" ]; then
      echo "screenshot exploded" >&2
      exit 1
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
SH
  chmod +x "$fakebin/chrome-devtools-axi"

  printf '%s\n' "$fakebin"
}

write_page() {
  local dir=$1 id=$2 href=$3 title=$4
  mkdir -p "$dir"
  printf '%s\t%s\n' "$href" "$title" > "$dir/page_$id"
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
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
printf '{"Browser":"fake"}\n'
SH
  chmod +x "$fakebin/curl"

  set +e
  out=$(PATH="$fakebin:/usr/bin:/bin" bash "$ROOT/bin/fm-browser-qa.sh" --url "https://example.test/qa" --out "$dir/evidence" 2>&1)
  status=$?
  set -e
  expect_code 1 "$status" "missing chrome-devtools-axi should exit 1"
  assert_contains "$out" "blocked: chrome-devtools-axi is not installed" \
    "missing chrome-devtools-axi should be blocked"
  pass "fm-browser-qa.sh: missing chrome-devtools-axi blocks"
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
  printf '%s\t%s\n' "https://example.cloudflareaccess.com/cdn-cgi/access/login" "Cloudflare Access" > "$dir/browser/newpage_redirect"

  set +e
  out=$(run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$dir/evidence")
  status=$?
  set -e
  expect_code 1 "$status" "auth page should exit 1"
  assert_contains "$out" "blocked: authenticated browser session expired" \
    "auth page should be reported as authenticated-session blocked"
  assert_grep "Google Chrome" "$dir/browser/osascript.log" \
    "auth block should foreground the QA Chrome window"
  pass "fm-browser-qa.sh: auth/sign-in pages block clearly"
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
  write_page "$dir/browser" 1 "https://github.com/login" "Sign in to GitHub"
  printf '%s\t%s\n' "https://example.test/elsewhere" "Elsewhere" > "$dir/browser/newpage_redirect"

  set +e
  out=$(run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$dir/evidence")
  status=$?
  set -e
  expect_code 1 "$status" "unresolved navigation should exit 1"
  assert_not_contains "$out" "authenticated browser session expired" \
    "unrelated sign-in tab must not trigger the auth verdict"
  assert_contains "$out" "blocked: exact QA URL is not open after navigation" \
    "unresolved navigation should report the navigation failure"
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
    "FM_FAKE_BROWSER_DIR=$dir/browser" \
    "FM_BROWSER_QA_OPEN_SETTLE=1" \
    "TMPDIR=$tmp_root" \
    bash "$ROOT/bin/fm-browser-qa.sh" --url "https://example.test/qa" --out "$dir/evidence" > "$dir/output.txt" 2>&1 &
  pid=$!
  tries=20
  while [ ! -e "$dir/browser/newpage_started" ] && [ "$tries" -gt 0 ]; do
    sleep 0.05
    tries=$((tries - 1))
  done
  [ -e "$dir/browser/newpage_started" ] || fail "signal cleanup test did not reach target-page settling"
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

test_requires_url_and_out
test_missing_chrome_devtools_axi_blocks
test_browser_unreachable_without_start_blocks
test_start_if_needed_uses_persistent_visible_profile
test_start_if_needed_refuses_existing_temporary_profile
test_start_if_needed_allows_existing_operator_profile
test_exact_tab_selected_and_evidence_written
test_no_exact_tab_opens_new_page_then_verifies
test_multiple_exact_tabs_refused
test_selected_url_mismatch_refused
test_auth_blocked_reported
test_unprobeable_unrelated_tab_is_skipped
test_unrelated_sign_in_tab_does_not_report_auth_expired
test_sign_in_substring_title_is_not_auth
test_trailing_slash_url_is_normalized
test_successful_evidence_cleans_up_axi_session
test_cleanup_error_preserves_original_status
test_snapshot_failure_blocks
test_screenshot_failure_blocks
test_console_and_network_failures_warn_only
test_signal_cleans_up_axi_session
test_signal_during_temp_allocation_removes_temp_dir
test_concurrent_logical_session_labels_use_distinct_axi_sessions
