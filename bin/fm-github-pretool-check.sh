#!/usr/bin/env bash
# Stable PreToolUse transport for the fork/upstream GitHub command policy.
#
# Firstmate keeps Jordan's fork writable and treats upstream as pull-only.
# bin/fm-github-command-policy.mjs owns the block/allow decision; this wrapper
# only acquires harness payloads, discovers local git/GitHub targeting context,
# invokes that policy, and renders the established harness responses. It never
# executes, sources, evaluates, or expands the submitted command.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-github-pretool-check.sh
#   bin/fm-github-pretool-check.sh --command '<cmd>'
#
# Exit/output contract:
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   FAIL OPEN - malformed transport, missing jq for stdin transport, missing
#               git/node/policy owner, no upstream remote, or an invalid policy
#               response.
set -u

CMD=""
CMD_SET=0
CLAUDE_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-github-pretool-check.sh [--command <cmd>] [--claude]

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok
toolInput.command, or Claude/Codex tool_input.command).
Exits 0 to allow and 2 to deny a GitHub mutation targeting upstream.
Malformed transport and unavailable policy/runtime context fail open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
fi

[ -n "$CMD" ] || exit 0

# Strict-superset prefilter only. It owns no classification semantics; it just
# avoids git/node work for commands that cannot name gh, GitHub, or git push
# even after the shared classifier's cheap byte normalization.
PREFILTER=$CMD
PREFILTER=${PREFILTER//\\/}
PREFILTER=${PREFILTER//\"/}
PREFILTER=${PREFILTER//\'/}
PREFILTER=${PREFILTER//$'\n'/}
PREFILTER=${PREFILTER//$'\r'/}
case "$CMD" in
  *"\$'"*|*'$"'*) ;;
  *)
    case "$PREFILTER" in
      *gh*|*github*|*"git push"*|*gitpush*) ;;
      *) exit 0 ;;
    esac
    ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
POLICY="$ROOT/bin/fm-github-command-policy.mjs"

[ -f "$ROOT/AGENTS.md" ] || exit 0
command -v git >/dev/null 2>&1 || exit 0
command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

GIT_ROOT=$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null) || exit 0
ORIGIN_URL=$(git -C "$GIT_ROOT" config --get remote.origin.url 2>/dev/null || true)
UPSTREAM_URL=$(git -C "$GIT_ROOT" config --get remote.upstream.url 2>/dev/null || true)
[ -n "$UPSTREAM_URL" ] || exit 0

DEFAULT_REPO=""
if command -v gh >/dev/null 2>&1; then
  DEFAULT_REPO=$(gh repo set-default --view 2>/dev/null | tr -d '\r' | head -n 1 || true)
fi

POLICY_OUTPUT=$(node "$POLICY" \
  --command "$CMD" \
  --origin-repo "$ORIGIN_URL" \
  --upstream-repo "$UPSTREAM_URL" \
  --default-repo "$DEFAULT_REPO" 2>/dev/null) || exit 0
[ -n "$POLICY_OUTPUT" ] || exit 0

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = "deny" ] || exit 0
REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || exit 0
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || exit 0

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

DETAIL="[$CODE] $REASON"
ESCAPED=$(json_escape "$DETAIL")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
