#!/usr/bin/env bash
# fm-route-report.sh - read-only summary of routing economics from data/routing-ledger.jsonl.
# Answers: claude:codex ratio (tasks + output tokens), spend by role/model/effort/rule,
# cache rates, coverage gaps, and over-tier candidates. No writes, no side effects.
#
# Usage: bin/fm-route-report.sh [ledger-path]
#   default ledger: $FM_ROOT/data/routing-ledger.jsonl (or ./data/routing-ledger.jsonl)
# shellcheck disable=SC2016  # jq programs below are intentionally single-quoted.
set -euo pipefail

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT=${FM_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
LEDGER=${1:-$FM_ROOT/data/routing-ledger.jsonl}

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq required" >&2; exit 1
fi
if [ ! -f "$LEDGER" ]; then
  echo "no ledger yet at $LEDGER — run some tasks through teardown first." >&2; exit 0
fi
if [ ! -s "$LEDGER" ]; then
  echo "ledger is empty: $LEDGER" >&2; exit 0
fi

# Slurp the JSONL once; dedupe by id (teardown may double-log — keep latest ts).
# every section is a jq query over $rows.
rows=$(jq -s 'group_by(.id) | map(max_by(.ts))' "$LEDGER")

emit() { jq -rn --argjson r "$rows" "$1"; }

echo "═══ ROUTING ECONOMICS — $(basename "$LEDGER") ═══"
emit '
  ($r | length) as $n
  | ($r | map(select(.tokens=="available")) ) as $ok
  | "tasks logged: \($n)   measured: \($ok|length)   unmeasured: \($n - ($ok|length))"
  + (if ($r|length)>0 then "   span: \($r|min_by(.ts).ts[0:10]) → \($r|max_by(.ts).ts[0:10])" else "" end)
'

echo
echo "── Harness split (measured output tokens) ──"
emit '
  ($r | map(select(.tokens=="available"))) as $ok
  | ($ok | map(.out // 0) | add // 0) as $tot
  | ($ok | group_by(.harness)[]
      | { harness: .[0].harness,
          tasks: length,
          out: (map(.out // 0)|add // 0) })
  | . as $g
  | "\($g.harness | (. + "        ")[0:8])  tasks=\($g.tasks|tostring|(. + "   ")[0:3])  out=\($g.out)  (\( if $tot>0 then (($g.out*100/$tot)|floor) else 0 end)%)"
'
emit '
  ($r) as $all
  | ($all | group_by(.harness)[] | {h:.[0].harness, t:length}) as $g
  | ($all|length) as $n
  | "  by task-count: \($g.h)=\($g.t) (\(if $n>0 then (($g.t*100/$n)|floor) else 0 end)%)"
'

echo
echo "── By role (kind) ──"
emit '
  ($r | map(select(.tokens=="available"))) as $ok
  | $ok | group_by(.kind)[]
  | "\(.[0].kind | (. + "          ")[0:10])  tasks=\(length)  out=\(map(.out // 0)|add // 0)"
'

echo
echo "── By model ──"
emit '
  ($r | map(select(.tokens=="available"))) as $ok
  | $ok | group_by(.model)[]
  | "\(.[0].model | (. + "            ")[0:12])  tasks=\(length)  out=\(map(.out // 0)|add // 0)"
'

echo
echo "── By effort (codex) ──"
emit '
  ($r | map(select(.tokens=="available" and (.harness|test("codex"))))) as $ok
  | if ($ok|length)==0 then "  (none measured)" else
      ($ok | group_by(.effort)[]
        | "\(.[0].effort | (. + "        ")[0:8])  tasks=\(length)  out=\(map(.out // 0)|add // 0)")
    end
'

echo
echo "── By dispatch rule (the feedback-loop view) ──"
emit '
  ($r | map(select(.rule != null))) as $ruled
  | if ($ruled|length)==0 then "  (no rule attribution yet — spawns predate --rule, or rule= unset)" else
      ($ruled | group_by(.rule)[]
        | { rule: .[0].rule, tasks: length,
            out: (map(.out // 0)|add // 0),
            esc: (map(.escalations // 0)|add // 0),
            redo: (map(select(.outcome=="reverted" or .redo_of != null))|length) }
        | "  rule \(.rule):  tasks=\(.tasks)  out=\(.out)  escalations=\(.esc)  redo/revert=\(.redo)")
    end
'

echo
echo "── Cache (rows with input data) ──"
# NOTE: .in has different semantics per harness — codex .in already includes cached;
# claude .in is uncached-only (cache_read + cache_creation are separate). Normalize
# total_input per harness so the rate is meaningful (cached / total_input).
emit '
  def total_input: if (.harness|test("codex")) then (.in // 0)
                   else ((.in // 0) + (.cached // 0) + (.cache_creation // 0)) end;
  ($r | map(select(.tokens=="available" and .in != null and .in > 0))) as $c
  | if ($c|length)==0 then "  (no input/cache data yet)" else
      ($c | (map(.cached // 0)|add) as $ca | (map(total_input)|add) as $ti
        | "  aggregate cache rate: \(if $ti>0 then (($ca*100/$ti)|floor) else 0 end)%  over \($c|length) rows  (harness-normalized)")
    end
'

echo
echo "── ⚠ Flags ──"
emit '
  ($r | map(select(.tokens=="unavailable"))) as $miss
  | "  coverage gaps (tokens=unavailable): \($miss|length)"
    + (if ($miss|length)>0 then "  [" + ($miss|map(.id)|join(", ")) + "]" else "" end)
'
emit '
  # over-tier candidates: high effort/opus but tiny output + high cache.
  # cache rate must use harness-normalized total_input (codex .in incl cached;
  # claude .in uncached-only) — raw .cached/.in is wrong for claude rows.
  def total_input: if (.harness|test("codex")) then (.in // 0)
                   else ((.in // 0) + (.cached // 0) + (.cache_creation // 0)) end;
  ($r | map(select(.tokens=="available" and .in != null and .in>0
        and ((.out // 0) < 20000)
        and (total_input > 0)
        and (((.cached // 0)*100 / total_input) > 92)
        and ((.effort=="high" or .effort=="xhigh") or (.model=="opus"))))) as $ot
  | if ($ot|length)==0 then "  over-tier candidates: none" else
      "  over-tier candidates (>92% cache, <20k out, high/xhigh/opus):",
      ($ot[] | "    \(.id): \(.harness)/\(.model)/\(.effort // "-")  out=\(.out)  cache=\((((.cached // 0)*100/total_input))|floor)%")
    end
'
emit '
  # Ship-on-claude is NOT a blanket leak: crew-dispatch rule 1 legitimately routes
  # security/arch/hard-to-reverse implementation to claude/opus/high. Without rule
  # provenance in the ledger (override collapses missing/mismatch/invalid), we can
  # only surface these for review, not assert a leak. The opus/high shape MAY be a
  # valid rule-1 route.
  ($r | map(select(.kind=="ship" and (.harness|test("claude"))))) as $ships
  | if ($ships|length)==0 then "  ship-on-claude: none" else
      "  ship-on-claude (confirm intended — rule 1 allows opus/high ships; provenance not yet in ledger):",
      ($ships[] | "    \(.id): \(.model)/\(.effort // "-")  rule=\(.rule)  out=\(.out)")
    end
'
echo
echo "ledger: $LEDGER"
