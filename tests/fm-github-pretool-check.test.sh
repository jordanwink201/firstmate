#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavior tests for the GitHub fork-maintenance PreToolUse seatbelt.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-github-pretool-check)

install_github_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-github-pretool-check.sh" "$dir/bin/fm-github-pretool-check.sh"
  cp "$ROOT/bin/fm-github-command-policy.mjs" "$dir/bin/fm-github-command-policy.mjs"
  cp "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/fm-arm-command-policy.mjs"
  chmod +x "$dir/bin/fm-github-pretool-check.sh" "$dir/bin/fm-github-command-policy.mjs"
}

make_primary_fixture() {
  local dir=$1
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" remote add origin https://github.com/jordanwink201/firstmate.git
  git -C "$dir" remote add upstream https://github.com/kunchenguid/firstmate.git
  : > "$dir/AGENTS.md"
  install_github_scripts "$dir"
  printf '%s\n' "$dir"
}

make_fake_gh() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = repo ] && [ "${2:-}" = set-default ] && [ "${3:-}" = --view ]; then
  printf '%s\n' "${FM_TEST_DEFAULT_REPO:-}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$fakebin"
}

PRIMARY=$(make_primary_fixture "$TMP_ROOT/primary")
CHECK="$PRIMARY/bin/fm-github-pretool-check.sh"
POLICY="$PRIMARY/bin/fm-github-command-policy.mjs"
FAKEBIN=$(make_fake_gh "$TMP_ROOT/fake")

policy_field() {
  local cmd=$1 default=${2:-kunchenguid/firstmate}
  node "$POLICY" \
    --command "$cmd" \
    --origin-repo jordanwink201/firstmate \
    --upstream-repo kunchenguid/firstmate \
    --default-repo "$default" | cut -f1
}

assert_policy() {
  local expected=$1 cmd=$2 default=${3:-kunchenguid/firstmate} actual
  actual=$(policy_field "$cmd" "$default")
  [ "$actual" = "$expected" ] || fail "policy expected $expected for [$cmd] with default [$default], got $actual"
}

test_policy_matrix() {
  assert_policy deny 'npx -y gh-axi pr create --title x'
  assert_policy allow 'npx -y gh-axi pr create --title x' jordanwink201/firstmate
  assert_policy deny 'npx -y gh-axi pr create --repo=kunchenguid/firstmate --title x' jordanwink201/firstmate
  assert_policy allow 'npx -y gh-axi pr create --repo=jordanwink201/firstmate --title x'
  assert_policy allow 'npx -y gh-axi pr view 680 --repo=kunchenguid/firstmate'
  assert_policy deny 'gh pr create -R kunchenguid/firstmate --title x'
  assert_policy deny 'gh issue create --repo kunchenguid/firstmate --title bug'
  assert_policy deny 'gh api -X PATCH repos/kunchenguid/firstmate/pulls/680 -f title=x' jordanwink201/firstmate
  assert_policy allow 'gh api repos/kunchenguid/firstmate/pulls/680' jordanwink201/firstmate
  assert_policy deny 'gh repo set-default upstream' jordanwink201/firstmate
  assert_policy deny 'gh repo set-default kunchenguid/firstmate' jordanwink201/firstmate
  assert_policy allow 'gh repo set-default origin' jordanwink201/firstmate
  assert_policy deny "bash -lc 'npx -y gh-axi pr create --title x'"
  assert_policy deny 'git push upstream main'
  assert_policy deny 'git push https://github.com/kunchenguid/firstmate.git main'
  assert_policy allow 'git push origin upstream'
  assert_policy allow 'git fetch upstream'
  pass "github fork policy denies upstream mutations while allowing fork and read-only operations"
}

run_transport() {
  local default_repo=$1 command=$2 mode=${3:-codex} out_file err_file rc payload
  out_file="$TMP_ROOT/transport.out"
  err_file="$TMP_ROOT/transport.err"
  : > "$out_file"
  : > "$err_file"
  case "$mode" in
    claude)
      payload=$(jq -cn --arg command "$command" '{tool_name:"Bash",tool_input:{command:$command}}')
      FM_TEST_DEFAULT_REPO="$default_repo" PATH="$FAKEBIN:$PATH" \
        printf '%s' "$payload" | FM_TEST_DEFAULT_REPO="$default_repo" PATH="$FAKEBIN:$PATH" "$CHECK" --claude >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    *)
      payload=$(jq -cn --arg command "$command" '{tool_name:"Bash",tool_input:{command:$command}}')
      FM_TEST_DEFAULT_REPO="$default_repo" PATH="$FAKEBIN:$PATH" \
        printf '%s' "$payload" | FM_TEST_DEFAULT_REPO="$default_repo" PATH="$FAKEBIN:$PATH" "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
  esac
  printf '%s\n' "$rc"
}

test_transport_blocks_upstream_default() {
  local rc out err
  rc=$(run_transport kunchenguid/firstmate 'npx -y gh-axi pr create --title x')
  out=$(cat "$TMP_ROOT/transport.out")
  err=$(cat "$TMP_ROOT/transport.err")
  [ "$rc" -eq 2 ] || fail "transport should deny upstream-default PR creation, got exit $rc"
  assert_contains "$err" "upstream-github-mutation" "deny stderr must name upstream-github-mutation"
  assert_contains "$out" '"decision":"deny"' "non-Claude deny stdout must carry Grok-shaped deny object"

  rc=$(run_transport kunchenguid/firstmate 'npx -y gh-axi pr create --title x' claude)
  [ "$rc" -eq 2 ] || fail "Claude transport should deny upstream-default PR creation, got exit $rc"
  [ ! -s "$TMP_ROOT/transport.out" ] || fail "Claude deny stdout must be empty"
  pass "github transport blocks PR creation when gh default points at upstream"
}

test_transport_allows_fork_default() {
  local rc
  rc=$(run_transport jordanwink201/firstmate 'npx -y gh-axi pr create --title x')
  [ "$rc" -eq 0 ] || fail "transport should allow fork-default PR creation, got exit $rc"
  [ ! -s "$TMP_ROOT/transport.out" ] || fail "allowed transport must leave stdout empty"
  [ ! -s "$TMP_ROOT/transport.err" ] || fail "allowed transport must leave stderr empty"
  pass "github transport allows PR creation when gh default points at the fork"
}

test_hook_wiring() {
  local settings command content
  settings="$ROOT/.codex/hooks.json"
  jq -e '[.hooks.PreToolUse[0].hooks[].command | select(contains("fm-github-pretool-check.sh"))] | length == 1' "$settings" >/dev/null \
    || fail "codex PreToolUse must invoke fm-github-pretool-check.sh exactly once"

  settings="$ROOT/.claude/settings.json"
  jq -e '[.hooks.PreToolUse[0].hooks[].command | select(contains("fm-github-pretool-check.sh") and contains("--claude"))] | length == 1' "$settings" >/dev/null \
    || fail "claude PreToolUse must invoke fm-github-pretool-check.sh with --claude"

  settings="$ROOT/.grok/hooks/fm-primary-github-check.json"
  [ -f "$settings" ] || fail "tracked grok GitHub hook config is missing"
  command=$(jq -r '.hooks.PreToolUse[0].hooks[0].command // empty' "$settings")
  assert_contains "$command" 'GROK_WORKSPACE_ROOT' "grok GitHub hook must anchor from GROK_WORKSPACE_ROOT"
  assert_contains "$command" 'fm-github-pretool-check.sh' "grok GitHub hook must invoke the guard"

  content=$(cat "$ROOT/.opencode/plugins/fm-primary-github-check.js")
  assert_contains "$content" 'tool.execute.before' "OpenCode GitHub plugin must run before tool execution"
  assert_contains "$content" 'fm-github-pretool-check.sh' "OpenCode GitHub plugin must invoke the guard"

  content=$(cat "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts")
  assert_contains "$content" 'runGithubCheck(command)' "Pi extension must run the GitHub check"
  assert_contains "$content" 'fm-github-pretool-check.sh' "Pi extension must invoke the GitHub guard owner"
  pass "github guard is wired into primary harness hook configs"
}

test_scripts_are_clean() {
  shellcheck "$ROOT/bin/fm-github-pretool-check.sh" "$ROOT/tests/fm-github-pretool-check.test.sh" >/dev/null \
    || fail "GitHub guard shell scripts are not shellcheck-clean"
  node "$ROOT/bin/fm-github-command-policy.mjs" --command 'npx -y gh-axi pr view 1' --origin-repo a/b --upstream-repo c/d --default-repo c/d >/dev/null \
    || fail "GitHub command policy CLI did not run"
  pass "github guard scripts pass static smoke checks"
}

test_policy_matrix
test_transport_blocks_upstream_default
test_transport_allows_fork_default
test_hook_wiring
test_scripts_are_clean
