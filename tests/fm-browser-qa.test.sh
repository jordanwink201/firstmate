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
rm -f "$FM_FAKE_BROWSER_DIR/browser_down"
exit 0
SH
  chmod +x "$fakebin/open"

  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
set -eu

dir=${FM_FAKE_BROWSER_DIR:?}
cmd=${1:-}
shift || true
mkdir -p "$dir"

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
    node - "$href" "$title" <<'NODE'
const [href, title] = process.argv.slice(2);
process.stdout.write(`result: ${JSON.stringify(JSON.stringify({ href, title }))}\n`);
NODE
    ;;
  newpage)
    url=${1:?}
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
  shift 2
  PATH="$fakebin:/usr/bin:/bin" FM_FAKE_BROWSER_DIR="$browser_dir" \
    FM_BROWSER_QA_OPEN_SETTLE=0 bash "$ROOT/bin/fm-browser-qa.sh" "$@" 2>&1
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

test_exact_tab_selected_and_evidence_written() {
  local dir fakebin evidence identity
  dir="$TMP_ROOT/exact"
  fakebin=$(make_fake_browser_tools "$dir")
  write_page "$dir/browser" 1 "https://example.test/qa" "QA Page"
  evidence="$dir/evidence"

  run_qa "$fakebin" "$dir/browser" --url "https://example.test/qa" --out "$evidence" --session exact >/dev/null

  identity="$evidence/identity.json"
  assert_present "$identity" "identity evidence missing"
  node -e 'const fs=require("fs"); const j=JSON.parse(fs.readFileSync(process.argv[1])); if (j.requested_url !== "https://example.test/qa" || j.title !== "QA Page" || j.session !== "fmqa-exact") process.exit(1)' "$identity" \
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
  pass "fm-browser-qa.sh: auth/sign-in pages block clearly"
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
  pass "fm-browser-qa.sh: snapshot failure blocks"
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

test_requires_url_and_out
test_missing_chrome_devtools_axi_blocks
test_browser_unreachable_without_start_blocks
test_exact_tab_selected_and_evidence_written
test_no_exact_tab_opens_new_page_then_verifies
test_multiple_exact_tabs_refused
test_selected_url_mismatch_refused
test_auth_blocked_reported
test_snapshot_failure_blocks
test_screenshot_failure_blocks
test_console_and_network_failures_warn_only
