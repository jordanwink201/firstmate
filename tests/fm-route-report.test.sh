#!/usr/bin/env bash
# Behavior tests for bin/fm-route-report.sh.
#
# The report is read-only: it summarizes routing-ledger JSONL, dedupes repeated
# task rows by latest timestamp, and exits cleanly when no ledger exists.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPORT="$ROOT/bin/fm-route-report.sh"
TMP_ROOT=$(fm_test_tmproot fm-route-report)

write_sample_ledger() {
  local ledger=$1
  cat > "$ledger" <<'JSONL'
{"id":"task-a","ts":"2026-07-01T00:00:00Z","kind":"ship","project":"firstmate","rule":1,"harness":"codex","model":"gpt-5.5","effort":"high","out":1,"in":10,"cached":9,"cache_creation":0,"reasoning_out":0,"total_tokens":11,"tokens":"available","token_reason":null,"wall_s":null,"escalations":0,"outcome":"pushed","redo_of":null}
{"id":"task-a","ts":"2026-07-02T00:00:00Z","kind":"ship","project":"firstmate","rule":1,"harness":"codex","model":"gpt-5.5","effort":"high","out":120,"in":200,"cached":190,"cache_creation":0,"reasoning_out":0,"total_tokens":320,"tokens":"available","token_reason":null,"wall_s":null,"escalations":1,"outcome":"pushed","redo_of":null}
{"id":"task-b","ts":"2026-07-03T00:00:00Z","kind":"ship","project":"firstmate","rule":"override_missing","harness":"claude","model":"opus","effort":"high","out":50,"in":10,"cached":100,"cache_creation":0,"reasoning_out":0,"total_tokens":160,"tokens":"available","token_reason":null,"wall_s":null,"escalations":2,"outcome":"pushed","redo_of":null}
{"id":"task-c","ts":"2026-07-04T00:00:00Z","kind":"scout","project":"firstmate","rule":null,"harness":"codex","model":"gpt-5.5","effort":"medium","out":null,"in":null,"cached":null,"cache_creation":null,"reasoning_out":null,"total_tokens":null,"tokens":"unavailable","token_reason":"codex_jsonl_missing_or_unreadable","wall_s":null,"escalations":0,"outcome":"report","redo_of":null}
JSONL
}

test_help() {
  local output
  output=$("$REPORT" --help)
  assert_contains "$output" "Usage: bin/fm-route-report.sh [ledger-path]" \
    "route report help omitted usage"
  assert_contains "$output" "read-only summary of routing economics" \
    "route report help omitted summary"
  pass "fm-route-report.sh: --help prints real usage"
}

test_missing_ledger_exits_zero() {
  local dir output rc
  dir="$TMP_ROOT/missing"
  mkdir -p "$dir"
  set +e
  output=$("$REPORT" "$dir/no-ledger.jsonl" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "missing ledger should be a zero-exit no-op"
  assert_contains "$output" "no ledger yet at $dir/no-ledger.jsonl" \
    "missing ledger message did not include path"
  pass "fm-route-report.sh: missing ledger exits cleanly"
}

test_summary_is_read_only_and_deduped() {
  local dir ledger before after output
  dir="$TMP_ROOT/summary"
  mkdir -p "$dir"
  ledger="$dir/routing-ledger.jsonl"
  write_sample_ledger "$ledger"
  before=$(cksum "$ledger")
  output=$("$REPORT" "$ledger")
  after=$(cksum "$ledger")

  [ "$before" = "$after" ] || fail "route report modified the ledger"
  assert_contains "$output" "tasks logged: 3   measured: 2   unmeasured: 1" \
    "summary did not dedupe repeated task ids"
  assert_contains "$output" "codex" \
    "summary omitted codex harness split"
  assert_contains "$output" "claude" \
    "summary omitted claude harness split"
  assert_contains "$output" "aggregate cache rate: 93%" \
    "summary did not use harness-normalized cache rate"
  assert_contains "$output" "coverage gaps (tokens=unavailable): 1  [task-c]" \
    "summary omitted unavailable-token coverage gap"
  assert_contains "$output" "task-a: codex/gpt-5.5/high" \
    "summary omitted over-tier candidate"
  assert_contains "$output" "task-b: opus/high  rule=override_missing" \
    "summary omitted ship-on-claude review line"
  pass "fm-route-report.sh: summarizes, dedupes, and leaves ledger unchanged"
}

test_help
test_missing_ledger_exits_zero
test_summary_is_read_only_and_deduped
