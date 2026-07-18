# GitHub fork guard PreToolUse seatbelt

This document is the human-readable contract for the fork/upstream GitHub mutation guard.
`bin/fm-github-command-policy.mjs` is the single decision owner.
`bin/fm-github-pretool-check.sh` is the stable harness transport, local git/GitHub context lookup, and output renderer.
The tracked harness adapters forward command text without classifying it.

## Purpose

Firstmate maintains Jordan's fork as the writable line.
For a forked repo, `origin` is Jordan's fork and `upstream` is pull-only.
Agents may fetch, inspect, and merge from upstream, but must not push to upstream or open/update upstream PRs, issues, releases, workflow runs, repo settings, labels, secrets, variables, or other GitHub mutations unless the captain explicitly asks for an upstream contribution for that exact change.

This guard denies the common mistake class before the shell command runs:

- `gh` or `gh-axi` mutation subcommands whose explicit `--repo`/`-R` target is upstream.
- `gh` or `gh-axi` mutation subcommands with no explicit repo when `gh repo set-default --view` currently points at upstream.
- `gh api` calls that use a mutating method against `/repos/<upstream-owner>/<upstream-repo>/...`.
- `gh repo set-default upstream` or `gh repo set-default <upstream-owner>/<upstream-repo>`, because that recreates the dangerous default-targeting state.
- `git push upstream ...` and direct `git push <github-upstream-url> ...`.

Read-only upstream operations are allowed, including `git fetch upstream`, `gh pr view --repo <upstream>`, and `gh api` GETs.
Fork-targeted mutations are allowed.

## Boundary

The policy classifies shell command positions only.
It never evaluates, expands, sources, or executes any submitted command.
It reuses the tokenizer and command-position analysis exported by `bin/fm-arm-command-policy.mjs`.

Literal nested `sh`/`bash`/`zsh -c` and literal `eval` payloads are recursively classified.
Opaque dynamic payloads remain out of scope and fall through to the existing operational discipline plus review gates.

## Transport

`bin/fm-github-pretool-check.sh` supports the same harness entry shapes as the watcher-arm and cd guards:

- Claude and Codex stdin JSON at `.tool_input.command`.
- Grok stdin JSON at `.toolInput.command`.
- OpenCode and Pi exact command string via `--command <cmd>`.
- `--claude` suppresses stdout for Claude's PreToolUse behavior.

The wrapper discovers:

- `remote.origin.url`
- `remote.upstream.url`
- `gh repo set-default --view` when `gh` is available

It fails open with exit 0 and no output when the command is unrelated, transport is malformed, `jq` is missing on the stdin path, `git`/`node`/the policy file is unavailable, no upstream remote exists, or the policy response is invalid.
A broken hook must not deny every shell tool call.

## Output contract

- Allow returns exit 0 with both streams empty.
- Deny returns exit 2 and writes `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[upstream-github-mutation] reason"}` to stderr.
- Default deny mode also writes `{"decision":"deny","reason":"[upstream-github-mutation] reason"}` to stdout for Grok.
- `--claude` leaves stdout empty.

## Harness wiring

| Harness | Adapter |
| --- | --- |
| Codex | `.codex/hooks.json` PreToolUse hook |
| Claude | `.claude/settings.json` PreToolUse hook with `--claude` |
| Grok | `.grok/hooks/fm-primary-github-check.json` |
| OpenCode | `.opencode/plugins/fm-primary-github-check.js` |
| Pi | `.pi/extensions/fm-primary-turnend-guard.ts` `tool_call` handler |

Run:

```sh
node --check bin/fm-github-command-policy.mjs
bash -n bin/fm-github-pretool-check.sh
shellcheck bin/fm-github-pretool-check.sh tests/fm-github-pretool-check.test.sh
tests/fm-github-pretool-check.test.sh
```
