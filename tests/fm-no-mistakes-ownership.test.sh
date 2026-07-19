#!/usr/bin/env bash
# Static contract tests for crew-owned no-mistakes validation runs.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

validate_contract() {
  awk '
    /^### Validate$/ { found = 1; next }
    found && /^### / { exit }
    found { print }
  ' "$ROOT/AGENTS.md"
}

test_worker_owns_synchronous_driver() {
  local contract
  contract=$(validate_contract)

  assert_contains "$contract" 'The task worker that starts a no-mistakes run drives the pipeline' \
    "Validate contract does not assign the run to its initiating task worker"
  assert_contains "$contract" "owns every \`no-mistakes axi run\` and \`no-mistakes axi respond\` call through the next gate or outcome" \
    "Validate contract does not assign every synchronous driver call to the task worker"
  assert_contains "$contract" 'process every synchronous return until completion or a genuinely new escalation' \
    "Validate contract does not require the task worker to process every synchronous return"
  pass "Validate contract assigns the complete synchronous driver loop to the initiating task worker"
}

test_worker_captures_registration_failure_preflight() {
  local contract
  contract=$(validate_contract)

  assert_contains "$contract" "Before reporting a no-mistakes registration or run failure" \
    "Validate contract does not require a preflight before reporting no-mistakes failure"
  assert_contains "$contract" "\`git rev-parse --short HEAD\`" \
    "Validate contract does not capture the intended HEAD"
  assert_contains "$contract" "confirm the no-mistakes \`current_branch\` and run \`head\` match the final branch and commit" \
    "Validate contract does not require branch/head alignment before escalation"
  pass "Validate contract requires branch/head preflight before no-mistakes failure escalation"
}

test_firstmate_never_responds_for_crew_run() {
  local contract
  contract=$(validate_contract)

  assert_contains "$contract" "Firstmate never invokes \`no-mistakes axi respond\` for a crew-owned run." \
    "Validate contract permits Firstmate to respond directly for a crew-owned run"
  pass "Validate contract forbids Firstmate from responding directly for a crew-owned run"
}

test_worker_owns_synchronous_driver
test_worker_captures_registration_failure_preflight
test_firstmate_never_responds_for_crew_run
