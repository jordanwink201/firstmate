#!/usr/bin/env bash
# fm-send readiness preflight.
#
# Direct text sends must prove the target is safe before typing. This suite
# keeps that gate hermetic with fake backends and asserts that only `ready`
# permits a literal send; busy/pending/unknown/missing fail before mutating the
# composer. The --key path intentionally bypasses readiness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$ROOT/bin/fm-marker-lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-readiness)

make_tmux_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
mode=${FM_TMUX_MODE:-ready}
{
  printf 'tmux'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "${FM_TMUX_LOG:?}"

has_arg() {
  local want=$1 a
  shift
  for a in "$@"; do [ "$a" = "$want" ] && return 0; done
  return 1
}

case "${1:-}" in
  display-message)
    [ "$mode" = missing ] && exit 1
    for a in "$@"; do
      case "$a" in
        *pane_id*) printf '%%1\n'; exit 0 ;;
        *cursor_y*) printf '0\n'; exit 0 ;;
        *pane_current_path*) printf '/tmp\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'
    exit 0
    ;;
  capture-pane)
    [ "$mode" = missing ] && exit 1
    [ "$mode" = unknown ] && exit 1
    if [ "$mode" = busy ]; then
      printf 'esc to interrupt\n'
      exit 0
    fi
    if [ "$mode" = pending ] && has_arg -e "$@"; then
      printf '\xe2\x94\x82 > typed already \xe2\x94\x82\n'
      exit 0
    fi
    printf '\xe2\x94\x82 > \xe2\x94\x82\n'
    exit 0
    ;;
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "${FM_SEND_LOG:?}"
    fi
    exit 0
    ;;
  list-windows)
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_home() {  # <name> -> echoes home
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

run_send_with_mode() {  # <mode> <home> <send-log> <tmux-log> -- <fm-send args...>
  local mode=$1 home=$2 send_log=$3 tmux_log=$4 fb; shift 4
  fb=$(make_tmux_fakebin "$TMP_ROOT/fake-$mode-$RANDOM")
  : > "$send_log"
  : > "$tmux_log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_TMUX_MODE="$mode" FM_SEND_LOG="$send_log" FM_TMUX_LOG="$tmux_log" \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    "$SEND" "$@"
}

readiness_for_tmux_mode() {  # <mode>
  local mode=$1 dir fb log
  dir="$TMP_ROOT/readiness-tmux-$mode"; mkdir -p "$dir"
  fb=$(make_tmux_fakebin "$dir")
  log="$dir/tmux.log"; : > "$log"
  PATH="$fb:$PATH" FM_TMUX_MODE="$mode" FM_SEND_LOG="$dir/send.log" FM_TMUX_LOG="$log" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_send_readiness tmux sess:win' "$ROOT"
}

test_ready_text_send_types_and_submits() {
  local home send_log tmux_log out rc
  home=$(setup_home ready-send)
  send_log="$home/send.log"; tmux_log="$home/tmux.log"
  out=$(run_send_with_mode ready "$home" "$send_log" "$tmux_log" "sess:win" "hello captain" 2>&1)
  rc=$?
  expect_code 0 "$rc" "ready target should allow text send"$'\n'"$out"
  [ "$(cat "$send_log")" = "hello captain" ] || fail "ready send should type the literal text once"
  assert_contains "$(cat "$tmux_log")" $'\x1f''Enter' "ready send should submit with Enter"
  pass "fm-send readiness: ready target allows literal text and normal submit"
}

assert_text_send_blocks_before_literal() {  # <mode> <expected-state>
  local mode=$1 expected=$2 home send_log tmux_log out rc target=sess:win
  home=$(setup_home "block-$mode")
  send_log="$home/send.log"; tmux_log="$home/tmux.log"
  if [ "$mode" = missing ]; then
    fm_write_meta "$home/state/missing.meta" "window=sess:win"
    target=fm-missing
  fi
  out=$(run_send_with_mode "$mode" "$home" "$send_log" "$tmux_log" "$target" "do not type" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "$mode target should fail before typing"
  assert_contains "$out" "error: target not ready for text send: $expected" \
    "$mode target did not report the expected readiness state"
  [ ! -s "$send_log" ] || fail "$mode target typed literal text before refusing"$'\n'"$(cat "$send_log")"
  pass "fm-send readiness: $expected target exits before literal typing"
}

test_busy_blocks_before_typing() {
  assert_text_send_blocks_before_literal busy busy
}

test_pending_blocks_before_typing() {
  assert_text_send_blocks_before_literal pending pending
}

test_unknown_blocks_before_typing() {
  assert_text_send_blocks_before_literal unknown unknown
}

test_missing_blocks_before_typing() {
  assert_text_send_blocks_before_literal missing missing
}

test_key_path_bypasses_readiness() {
  local home send_log tmux_log out rc
  home=$(setup_home key-bypass)
  send_log="$home/send.log"; tmux_log="$home/tmux.log"
  out=$(run_send_with_mode ready "$home" "$send_log" "$tmux_log" "sess:win" --key Enter 2>&1)
  rc=$?
  expect_code 0 "$rc" "--key path should bypass readiness"$'\n'"$out"
  [ ! -s "$send_log" ] || fail "--key path should not type literal text"
  assert_not_contains "$(cat "$tmux_log")" "capture-pane" "--key path should not inspect composer readiness"
  assert_contains "$(cat "$tmux_log")" $'\x1f''Enter' "--key path should still send the requested key"
  pass "fm-send readiness: --key Enter bypasses readiness"
}

test_secondmate_marker_still_prepended_when_ready() {
  local home send_log tmux_log out rc got
  home=$(setup_home secondmate-ready)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  send_log="$home/send.log"; tmux_log="$home/tmux.log"
  out=$(run_send_with_mode ready "$home" "$send_log" "$tmux_log" "fm-domain" "audit readiness" 2>&1)
  rc=$?
  expect_code 0 "$rc" "ready secondmate send should succeed"$'\n'"$out"
  got=$(cat "$send_log")
  case "$got" in
    "$FM_FROMFIRST_MARK"audit\ readiness) : ;;
    *) fail "secondmate ready send should type marker+text"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)" ;;
  esac
  pass "fm-send readiness: successful secondmate sends still prepend the from-firstmate marker"
}

test_tmux_readiness_maps_states() {
  [ "$(readiness_for_tmux_mode ready)" = ready ] || fail "tmux ready mode should map to ready"
  [ "$(readiness_for_tmux_mode busy)" = busy ] || fail "tmux busy mode should map to busy"
  [ "$(readiness_for_tmux_mode pending)" = pending ] || fail "tmux pending composer should map to pending"
  [ "$(readiness_for_tmux_mode unknown)" = unknown ] || fail "tmux unreadable composer should map to unknown"
  [ "$(readiness_for_tmux_mode missing)" = missing ] || fail "tmux missing target should map to missing"
  pass "fm_backend_send_readiness: tmux maps busy/composer states"
}

make_herdr_readiness_fakebin() {  # <dir> -> echoes fakebin
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
mode=${FM_HERDR_READINESS_MODE:-ready}
{
  printf 'herdr'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "${FM_HERDR_LOG:?}"
cmd=${1:-}; sub=${2:-}; third=${3:-}
case "$cmd $sub" in
  "status --json")
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
    exit 0
    ;;
  "pane get")
    [ "$mode" = missing ] && exit 1
    printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$third"
    exit 0
    ;;
  "agent get")
    case "$mode" in
      busy) printf '{"result":{"agent":{"agent_status":"working"}}}\n' ;;
      native-unknown) printf '{"result":{"agent":{}}}\n' ;;
      *) printf '{"result":{"agent":{"agent_status":"idle"}}}\n' ;;
    esac
    exit 0
    ;;
  "pane read")
    case "$mode" in
      composer-unknown) exit 1 ;;
      pending) printf '  \xe2\x94\x82 \xe2\x9d\xaf typed already \xe2\x94\x82\n' ;;
      *) printf '  \xe2\x94\x82 \xe2\x9d\xaf \xe2\x94\x82\n' ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

readiness_for_herdr_mode() {  # <mode>
  local mode=$1 dir fb log
  dir="$TMP_ROOT/readiness-herdr-$mode"; mkdir -p "$dir"
  fb=$(make_herdr_readiness_fakebin "$dir")
  log="$dir/herdr.log"; : > "$log"
  PATH="$fb:$PATH" FM_HERDR_READINESS_MODE="$mode" FM_HERDR_LOG="$log" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_send_readiness herdr default:w1:p2' "$ROOT"
}

test_herdr_readiness_maps_native_and_composer_states() {
  [ "$(readiness_for_herdr_mode ready)" = ready ] || fail "herdr ready mode should map to ready"
  [ "$(readiness_for_herdr_mode busy)" = busy ] || fail "herdr native working should map to busy"
  [ "$(readiness_for_herdr_mode native-unknown)" = unknown ] || fail "herdr unknown native state should map to unknown"
  [ "$(readiness_for_herdr_mode pending)" = pending ] || fail "herdr pending composer should map to pending"
  [ "$(readiness_for_herdr_mode composer-unknown)" = unknown ] || fail "herdr unreadable composer should map to unknown"
  [ "$(readiness_for_herdr_mode missing)" = missing ] || fail "herdr missing target should map to missing"
  pass "fm_backend_send_readiness: herdr maps native busy and structural composer states"
}

make_cmux_readiness_fakebin() {  # <dir> -> echoes fakebin
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/cmux" <<'SH'
#!/usr/bin/env bash
set -u
mode=${FM_CMUX_READINESS_MODE:-ready}
case "${1:-}" in
  list-panes)
    if [ "$mode" = missing ]; then
      printf '{"panes":[]}\n'
    else
      printf '{"panes":[{"surface_ids":["sf-1"]}]}\n'
    fi
    exit 0
    ;;
  read-screen)
    case "$mode" in
      capture-unknown) exit 1 ;;
      busy) printf '{"text":"tool output\\nesc to interrupt"}\n' ;;
      pending) printf '{"text":"\xe2\x94\x82 > typed already \xe2\x94\x82"}\n' ;;
      composer-unknown) printf '{"text":"no composer row here"}\n' ;;
      *) printf '{"text":"\xe2\x94\x82 > \xe2\x94\x82"}\n' ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fb/cmux"
  printf '%s\n' "$fb"
}

readiness_for_cmux_mode() {  # <mode>
  local mode=$1 dir fb
  dir="$TMP_ROOT/readiness-cmux-$mode"; mkdir -p "$dir"
  fb=$(make_cmux_readiness_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_READINESS_MODE="$mode" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_send_readiness cmux ws-1:sf-1' "$ROOT"
}

test_cmux_readiness_maps_busy_footer_and_composer_states() {
  [ "$(readiness_for_cmux_mode ready)" = ready ] || fail "cmux empty composer should map to ready"
  [ "$(readiness_for_cmux_mode busy)" = busy ] || fail "cmux busy footer should map to busy"
  [ "$(readiness_for_cmux_mode pending)" = pending ] || fail "cmux pending composer should map to pending"
  [ "$(readiness_for_cmux_mode capture-unknown)" = unknown ] || fail "cmux unreadable surface should map to unknown"
  [ "$(readiness_for_cmux_mode composer-unknown)" = unknown ] || fail "cmux borderless capture should map to unknown"
  [ "$(readiness_for_cmux_mode missing)" = missing ] || fail "cmux missing target should map to missing"
  pass "fm_backend_send_readiness: cmux maps busy-footer and structural composer states"
}

make_zellij_readiness_fakebin() {  # <dir> -> echoes fakebin
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/zellij" <<'SH'
#!/usr/bin/env bash
set -u
mode=${FM_ZELLIJ_READINESS_MODE:-present}
if [ "${1:-}" = list-sessions ]; then
  [ "$mode" = missing ] || printf 'firstmate\n'
  exit 0
fi
if [ "${1:-}" = --session ] && [ "${4:-}" = list-panes ]; then
  [ "$mode" = missing ] && exit 0
  printf '[{"id":7,"tab_id":3,"is_plugin":false}]\n'
  exit 0
fi
exit 0
SH
  chmod +x "$fb/zellij"
  printf '%s\n' "$fb"
}

make_orca_readiness_fakebin() {  # <dir> -> echoes fakebin
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
mode=${FM_ORCA_READINESS_MODE:-present}
if [ "$mode" = missing ]; then
  printf '{"ok":false,"error":{"message":"terminal missing"}}\n'
  exit 0
fi
printf '{"ok":true,"result":{"terminal":{"tail":["present"]}}}\n'
exit 0
SH
  chmod +x "$fb/orca"
  printf '%s\n' "$fb"
}

test_orca_and_zellij_readiness_are_conservative() {
  local dir fb
  dir="$TMP_ROOT/readiness-zellij-present"; mkdir -p "$dir"
  fb=$(make_zellij_readiness_fakebin "$dir")
  [ "$(PATH="$fb:$PATH" FM_ZELLIJ_READINESS_MODE=present bash -c '. "$0/bin/fm-backend.sh"; fm_backend_send_readiness zellij firstmate:7' "$ROOT")" = unknown ] \
    || fail "zellij present target should map to unknown for patch 1"

  dir="$TMP_ROOT/readiness-zellij-missing"; mkdir -p "$dir"
  fb=$(make_zellij_readiness_fakebin "$dir")
  [ "$(PATH="$fb:$PATH" FM_ZELLIJ_READINESS_MODE=missing bash -c '. "$0/bin/fm-backend.sh"; fm_backend_send_readiness zellij firstmate:7' "$ROOT")" = missing ] \
    || fail "zellij missing target should map to missing"

  dir="$TMP_ROOT/readiness-orca-present"; mkdir -p "$dir"
  fb=$(make_orca_readiness_fakebin "$dir")
  [ "$(PATH="$fb:$PATH" FM_ORCA_READINESS_MODE=present bash -c '. "$0/bin/fm-backend.sh"; fm_backend_send_readiness orca term-7' "$ROOT")" = unknown ] \
    || fail "orca present target should map to unknown for patch 1"

  dir="$TMP_ROOT/readiness-orca-missing"; mkdir -p "$dir"
  fb=$(make_orca_readiness_fakebin "$dir")
  [ "$(PATH="$fb:$PATH" FM_ORCA_READINESS_MODE=missing bash -c '. "$0/bin/fm-backend.sh"; fm_backend_send_readiness orca term-7' "$ROOT" 2>/dev/null)" = missing ] \
    || fail "orca missing target should map to missing"

  pass "fm_backend_send_readiness: orca/zellij return unknown when present and missing when absent"
}

test_ready_text_send_types_and_submits
test_busy_blocks_before_typing
test_pending_blocks_before_typing
test_unknown_blocks_before_typing
test_missing_blocks_before_typing
test_key_path_bypasses_readiness
test_secondmate_marker_still_prepended_when_ready
test_tmux_readiness_maps_states
test_herdr_readiness_maps_native_and_composer_states
test_cmux_readiness_maps_busy_footer_and_composer_states
test_orca_and_zellij_readiness_are_conservative
