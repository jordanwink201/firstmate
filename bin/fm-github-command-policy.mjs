#!/usr/bin/env node
// Semantic policy for fork/upstream GitHub mutation commands.
//
// Firstmate maintains Jordan's fork as the writable line. Upstream remotes are
// pull-only. This policy blocks GitHub write commands that target the upstream
// owner/repo, plus `git push upstream ...`, before a harness shell runs them.
//
// The shell tokenizer and command-position analysis are imported from
// bin/fm-arm-command-policy.mjs so this guard reuses the existing shell parser
// instead of evaluating, expanding, sourcing, or executing any submitted bytes.

import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";

const REASONS = {
  "upstream-github-mutation":
    "this repository is maintained through Jordan's fork; upstream is pull-only. Use origin/Jordan's fork for pushes, PRs, issues, releases, workflow runs, and other GitHub mutations unless the captain explicitly asks for an upstream contribution.",
};

const MUTATING_SUBCOMMANDS = {
  pr: new Set(["create", "edit", "close", "reopen", "ready", "merge", "comment", "review", "lock", "unlock"]),
  issue: new Set(["create", "edit", "close", "reopen", "comment", "delete", "lock", "unlock", "transfer", "pin", "unpin"]),
  release: new Set(["create", "edit", "delete", "upload", "delete-asset", "verify-asset"]),
  workflow: new Set(["enable", "disable", "run"]),
  run: new Set(["cancel", "delete", "rerun"]),
  repo: new Set(["create", "delete", "edit", "rename", "archive", "unarchive", "fork", "sync", "transfer"]),
  label: new Set(["create", "edit", "delete", "clone"]),
  secret: new Set(["set", "delete", "remove"]),
  variable: new Set(["set", "delete", "remove"]),
  "actions-cache": new Set(["delete"]),
  gist: new Set(["create", "edit", "delete"]),
};

const GH_OPTION_TAKES_VALUE = new Set([
  "-R",
  "--repo",
  "--hostname",
  "--jq",
  "--template",
]);

const NPX_OPTION_TAKES_VALUE = new Set([
  "-p",
  "--package",
  "--cache",
  "--userconfig",
  "--call",
  "-c",
]);

const GIT_PUSH_OPTION_TAKES_VALUE = new Set([
  "--exec",
  "--receive-pack",
  "--push-option",
  "--recurse-submodules",
  "--signed",
  "--force-with-lease",
  "-o",
]);

const API_ENDPOINT_OPTION_TAKES_VALUE = new Set([
  "-X",
  "--method",
  "-H",
  "--header",
  "--hostname",
  "--jq",
  "--template",
  "-f",
  "-F",
  "--field",
  "--raw-field",
  "--input",
]);

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

function parseArguments(argv) {
  const result = {
    command: "",
    originRepo: "",
    upstreamRepo: "",
    defaultRepo: "",
  };
  const names = new Set(["--command", "--origin-repo", "--upstream-repo", "--default-repo"]);
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    const equals = name.indexOf("=");
    const key = equals === -1 ? name : name.slice(0, equals);
    if (!names.has(key)) throw new Error(`unknown argument: ${name}`);
    const prop = key.slice(2).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
    if (equals !== -1) {
      result[prop] = name.slice(equals + 1);
      continue;
    }
    if (i + 1 >= argv.length) throw new Error(`${key} requires a value`);
    result[prop] = argv[i + 1];
    i += 1;
  }
  return result;
}

function normalizeRepo(input) {
  if (!input) return "";
  let value = String(input).trim();
  if (!value || value === "DISABLED") return "";
  value = value.replace(/^["']|["']$/g, "");
  value = value.replace(/^git\+/, "");
  value = value.replace(/^ssh:\/\/git@github\.com[:/]/i, "");
  value = value.replace(/^git@github\.com:/i, "");
  value = value.replace(/^https?:\/\/github\.com\//i, "");
  value = value.replace(/^github\.com[:/]/i, "");
  value = value.replace(/\.git$/i, "");
  value = value.replace(/^\/+|\/+$/g, "");
  const match = value.match(/^([^/\s]+)\/([^/\s]+)$/);
  return match ? `${match[1].toLowerCase()}/${match[2].toLowerCase()}` : "";
}

function deny() {
  return { decision: "deny", code: "upstream-github-mutation", reason: REASONS["upstream-github-mutation"] };
}

function isUpstreamRepo(candidate, context) {
  const repo = normalizeRepo(candidate);
  return Boolean(repo && context.upstreamRepo && repo === context.upstreamRepo);
}

function explicitRepo(args) {
  for (let i = 0; i < args.length; i += 1) {
    const value = args[i]?.value || "";
    if (value === "--repo" || value === "-R") return args[i + 1]?.value || "";
    if (value.startsWith("--repo=")) return value.slice("--repo=".length);
    if (value.startsWith("-R") && value.length > 2) return value.slice(2);
  }
  return "";
}

function skipOption(words, index, takesValue) {
  const value = words[index]?.value || "";
  if (value === "--") return { next: index + 1, stop: true };
  if (!value.startsWith("-") || value === "-") return { next: index, stop: true };
  const equals = value.indexOf("=");
  if (equals !== -1) return { next: index + 1, stop: false };
  if (takesValue.has(value)) return { next: Math.min(index + 2, words.length), stop: false };
  if (value.length > 2 && takesValue.has(value.slice(0, 2))) return { next: index + 1, stop: false };
  return { next: index + 1, stop: false };
}

function firstPositional(words, start, takesValue = GH_OPTION_TAKES_VALUE) {
  let index = start;
  while (words[index]) {
    const skipped = skipOption(words, index, takesValue);
    if (skipped.stop) return { word: words[index], index };
    index = skipped.next;
  }
  return { word: null, index };
}

function ghRepoTarget(args, context) {
  const repo = explicitRepo(args);
  if (repo) return normalizeRepo(repo);
  return context.defaultRepo || "";
}

function ghGroupAndAction(args) {
  const group = firstPositional(args, 0);
  if (!group.word) return { group: "", action: "", groupIndex: -1, actionIndex: -1 };
  const action = firstPositional(args, group.index + 1);
  return {
    group: group.word.value,
    action: action.word?.value || "",
    groupIndex: group.index,
    actionIndex: action.word ? action.index : -1,
  };
}

function apiMethod(args) {
  let method = "";
  let hasField = false;
  for (let i = 0; i < args.length; i += 1) {
    const value = args[i].value;
    if (value === "-X" || value === "--method") {
      method = (args[i + 1]?.value || "").toUpperCase();
      i += 1;
      continue;
    }
    if (value.startsWith("--method=")) {
      method = value.slice("--method=".length).toUpperCase();
      continue;
    }
    if (value === "-f" || value === "-F" || value === "--field" || value === "--raw-field" || value === "--input") {
      hasField = true;
      i += value === "--input" ? 1 : 0;
      continue;
    }
    if (value.startsWith("--field=") || value.startsWith("--raw-field=") || value.startsWith("-f") || value.startsWith("-F")) hasField = true;
  }
  if (!method && hasField) method = "POST";
  return method || "GET";
}

function apiEndpoint(args, start) {
  for (let i = start; i < args.length; i += 1) {
    const value = args[i].value;
    if (value === "--") return args[i + 1]?.value || "";
    if (API_ENDPOINT_OPTION_TAKES_VALUE.has(value)) {
      i += 1;
      continue;
    }
    if (value.startsWith("-")) continue;
    return value;
  }
  return "";
}

function endpointRepo(endpoint) {
  const match = endpoint.match(/(?:^|\/)repos\/([^/\s]+)\/([^/\s?#]+)/i);
  return match ? normalizeRepo(`${match[1]}/${match[2]}`) : "";
}

function isGhMutation(args) {
  const { group, action } = ghGroupAndAction(args);
  if (!group) return false;
  if (group === "api") return apiMethod(args).toUpperCase() !== "GET";
  if (group === "repo" && action === "set-default") return true;
  return Boolean(MUTATING_SUBCOMMANDS[group]?.has(action));
}

function analyzeGh(args, context) {
  if (!isGhMutation(args)) return null;
  const info = ghGroupAndAction(args);
  if (info.group === "repo" && info.action === "set-default") {
    const target = firstPositional(args, info.actionIndex + 1).word?.value || "";
    if (target === "upstream" || isUpstreamRepo(target, context)) return deny();
    return null;
  }
  const endpointTarget = endpointRepo(apiEndpoint(args, info.group === "api" ? info.groupIndex + 1 : 0));
  const target = endpointTarget || ghRepoTarget(args, context);
  return target && target === context.upstreamRepo ? deny() : null;
}

function npxPayload(args) {
  let index = 0;
  while (args[index]) {
    const skipped = skipOption(args, index, NPX_OPTION_TAKES_VALUE);
    if (skipped.stop) break;
    index = skipped.next;
  }
  const command = args[index];
  if (!command) return null;
  return { command: basename(command.value), args: args.slice(index + 1) };
}

function gitPushRemote(args) {
  const push = firstPositional(args, 0);
  if (push.word?.value !== "push") return "";
  let index = push.index + 1;
  while (args[index]) {
    const skipped = skipOption(args, index, GIT_PUSH_OPTION_TAKES_VALUE);
    if (skipped.stop) break;
    index = skipped.next;
  }
  return args[index]?.value || "";
}

function analyzeGit(args, context) {
  const remote = gitPushRemote(args);
  if (!remote) return null;
  if (remote === "upstream" || isUpstreamRepo(remote, context)) return deny();
  return null;
}

function shellPayload(position) {
  if (!position.command) return null;
  const name = basename(position.command.value);
  if (!["sh", "bash", "zsh"].includes(name)) return null;
  for (let i = position.index + 1; i < position.words.length; i += 1) {
    const option = position.words[i].value;
    if (/^-[A-Za-z]*c[A-Za-z]*$/.test(option)) {
      let payloadIndex = i + 1;
      if (position.words[payloadIndex]?.value === "--") payloadIndex += 1;
      const payload = position.words[payloadIndex];
      return payload?.literal && payload.subs.length === 0 ? payload.value : null;
    }
    if (option === "--") return null;
    if (!option.startsWith("-")) return null;
  }
  return null;
}

function evalPayload(position) {
  if (!position.command || basename(position.command.value) !== "eval") return null;
  const payloads = position.words.slice(position.index + 1);
  if (payloads.length === 0 || payloads.some((payload) => !payload.literal || payload.subs.length > 0)) return null;
  return payloads.map((payload) => payload.value).join(" ");
}

function analyzePosition(position, context) {
  if (!position.command) return null;
  const command = basename(position.command.value);
  if (command === "gh" || command === "gh-axi") return analyzeGh(position.words.slice(position.index + 1), context);
  if (command === "git") return analyzeGit(position.words.slice(position.index + 1), context);
  if (command === "npx") {
    const payload = npxPayload(position.words.slice(position.index + 1));
    if (payload && (payload.command === "gh" || payload.command === "gh-axi")) return analyzeGh(payload.args, context);
  }
  return null;
}

function decision(command, options = {}) {
  const context = {
    originRepo: normalizeRepo(options.originRepo),
    upstreamRepo: normalizeRepo(options.upstreamRepo),
    defaultRepo: normalizeRepo(options.defaultRepo),
  };
  if (!context.upstreamRepo || context.upstreamRepo === context.originRepo) return { decision: "allow" };

  const lexed = new Lexer(command).tokenize();
  if (lexed.error) return { decision: "allow" };

  const { nodes } = splitProgram(lexed.tokens);
  for (const tokens of nodes) {
    const position = commandPosition(tokens);
    const nested = shellPayload(position) || evalPayload(position);
    if (nested) {
      const nestedDecision = decision(nested, context);
      if (nestedDecision.decision === "deny") return nestedDecision;
    }
    const result = analyzePosition(position, context);
    if (result) return result;
  }
  return { decision: "allow" };
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (!args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command, args);
      if (result.decision === "allow") {
        process.stdout.write("allow\n");
      } else {
        process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
      }
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision, normalizeRepo };
