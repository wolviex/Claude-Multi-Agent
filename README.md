# Claude-Multi-Agent

A drop-in multi-agent workflow for Claude Code with four roles. The orchestrator (the main session, Opus by default) plans the routing, commits, and gives final sign-off. The supervisor (Sonnet) plans atomic tasks and reviews every change. The implementer (Haiku) writes the code and runs the checks. The architect (Fable) is called only when a gate triggers. Models are configurable in `.claude/settings.json`. A PreToolUse hook stops subagents from running git write commands, so only the main session commits.

## Install into an existing project

Run this from anywhere inside the project's git repository:

```bash
curl -fsSL https://raw.githubusercontent.com/wolviex/Claude-Multi-Agent/main/install.sh | bash
```

The installer targets the repository's top-level directory. Outside a git repository, it uses the current directory.

What it does:

- Copies six framework files:
  - `.claude/multi-agent.md`: the workflow, with roles, the review gate, the architect gates, brief and report formats, and git rules.
  - `.claude/agents/implementer.md`: the Haiku `implementer` subagent that edits files and runs checks.
  - `.claude/agents/supervisor.md`: the Sonnet `supervisor` subagent that plans tasks in Plan mode and reviews each diff in Review mode.
  - `.claude/agents/architect.md`: the on-demand `architect` subagent that writes design documents under the output directory.
  - `.claude/hooks/block-git-write.sh`: the hook that blocks git write commands from subagents.
  - `.claude/hooks/agent-gate.sh`: the hook that checks each agent call's model against its role and enforces the architect's gates and output directory.
- Registers the hooks in `.claude/settings.json`. It creates the file if it is missing. If the file exists, it keeps your other settings and adds one entry per matcher (`Bash`, `Agent|Task`, and `Write|Edit|NotebookEdit`) only where it is missing. It recognises an existing entry whatever the order of the matcher names, so it never adds a duplicate.
- Adds the default `multiAgent` block (see [Configure models and the architect](#configure-models-and-the-architect)) only if `settings.json` has no `multiAgent` key. An existing `multiAgent` key is never overwritten, even with `--force`.
- Adds `<run log path> merge=union` to `.gitattributes`, so the architect run log merges cleanly between branches. It skips this when `runLog` is `"git"`, when the path is absolute, when it contains a `..` segment, when it contains spaces or glob characters (`*`, `?`, `[`), and when the path cannot be read from settings. Without jq, it assumes the default `dev/.architect-runs.log`. In a skipped case where the log is inside the repository, add the line yourself.
- Reports a legacy `.claude/agents/reviewer.md` if it is present, and does not delete it. See [Updating](#updating).
- Adds `@.claude/multi-agent.md` to `CLAUDE.md`. It ignores whitespace around an existing import line, so re-runs add no duplicate. If `CLAUDE.md` is missing, it creates one with a `## Required checks` placeholder.
- Fetches every file before writing anything. If a download fails, or if `settings.json` is invalid (checked when jq is installed), nothing in the project changes.
- Never overwrites a framework file you have changed locally unless you pass `--force`. Such files are reported as skipped.

It does not install this repository's bookmarklet tooling (`AGENTS.md`, `scripts/`, `package.json`).

### Options

| Option | Description |
|---|---|
| `--force` | Overwrite framework files that differ from upstream. |
| `--ref <git-ref>` | Branch, tag, or commit to install from. Default: `main`. |
| `--dir <path>` | Target project. Default: the git top level, else the current directory. |
| `-h`, `--help` | Show usage and exit. |

Environment variables:

| Variable | Description |
|---|---|
| `MULTI_AGENT_REPO` | GitHub `owner/repo` to download from. Default: `wolviex/Claude-Multi-Agent`. |
| `MULTI_AGENT_REF` | Ref to install when `--ref` is not given. Default: `main`. |
| `MULTI_AGENT_SRC` | Local checkout to copy from instead of downloading. Useful for tests and offline installs. |

Pass options after `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/wolviex/Claude-Multi-Agent/main/install.sh | bash -s -- --dir path/to/project
```

Use `--ref <branch, tag, or commit>` to install a specific version.

To read the script before running it, download it, read it, and then run it. Run these from inside the project, and delete `install.sh` afterwards because it is not part of the framework:

```bash
curl -fsSL https://raw.githubusercontent.com/wolviex/Claude-Multi-Agent/main/install.sh -o install.sh
```

```bash
cat install.sh
```

```bash
bash install.sh
```

### After installing

1. Review and commit `.claude/` and `CLAUDE.md`.
2. List the project's required checks in `CLAUDE.md` under `## Required checks`. Examples: `npm test`, or `node --check <file>` for each changed `.js` file. The implementer runs these checks and the supervisor reruns them.
3. Check the role models in `.claude/settings.json` under `multiAgent.roles`, and override them for one person in `.claude/settings.local.json` if needed.
4. Start Claude Code and select the orchestrator model (default Opus) with `/model`. The workflow tells the orchestrator to stop and tell you if the session is not on that model.
5. Describe a request as usual. The orchestrator plans the work with `supervisor`, briefs `implementer`, sends each diff to `supervisor` for review, and commits only after `VERDICT: APPROVED`.

### Updating

Re-run the installer with `--force`:

```bash
curl -fsSL https://raw.githubusercontent.com/wolviex/Claude-Multi-Agent/main/install.sh | bash -s -- --force
```

Without `--force`, a framework file you have edited locally is reported as skipped and left unchanged. Put project-specific rules in `CLAUDE.md` or `AGENTS.md`, not in the framework files, so updates do not overwrite them.

`--force` refreshes the framework files. It never updates existing hook entries or `multiAgent` settings in `.claude/settings.json`, so your role models and architect limits are kept. It prints a note saying so. Compare `.claude/settings.json` with the template below by hand. Re-runs without `--force` still add any hook entry or `multiAgent` key that is missing.

The hook template, as the installer writes it into a new `settings.json`. The `multiAgent` block is shown in [Configure models and the architect](#configure-models-and-the-architect):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/block-git-write.sh\"",
            "onFailure": "block"
          }
        ]
      },
      {
        "matcher": "Agent|Task",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/agent-gate.sh\""
          }
        ]
      },
      {
        "matcher": "Write|Edit|NotebookEdit",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/agent-gate.sh\""
          }
        ]
      }
    ]
  }
}
```

Upgrading from the earlier reviewer version: the installer reports `.claude/agents/reviewer.md` as legacy and never deletes it. `.claude/agents/supervisor.md` replaces it. Once you have reviewed the new file, delete `.claude/agents/reviewer.md` yourself. If `settings.json` has no `multiAgent` key, the update adds the defaults.

### Uninstalling

Uninstalling is manual:

1. Delete `.claude/multi-agent.md`, `.claude/agents/implementer.md`, `.claude/agents/supervisor.md`, `.claude/agents/architect.md`, `.claude/hooks/block-git-write.sh`, and `.claude/hooks/agent-gate.sh`.
2. In `.claude/settings.json`, remove the entry whose command contains `block-git-write.sh`, and both entries whose command contains `agent-gate.sh`, from the `hooks.PreToolUse` array. Remove the top-level `multiAgent` key.
3. Remove the `@.claude/multi-agent.md` line from `CLAUDE.md`.
4. Delete the run log if it is present: `<outputDir>/.architect-runs.log` (`dev/.architect-runs.log` with the default `outputDir`), or your configured `runLog` path. If `runLog` is `"git"`, the log is in the git directory and is not part of the working tree. Remove the `merge=union` line for the log from `.gitattributes`.

## Configure models and the architect

The default `multiAgent` block, as installed into `.claude/settings.json`:

```json
{
  "multiAgent": {
    "roles": {
      "orchestrator": { "model": "opus" },
      "supervisor": { "agent": "supervisor", "model": "sonnet" },
      "implementer": { "agent": "implementer", "model": "haiku" },
      "architect": { "agent": "architect", "model": "fable" }
    },
    "architect": {
      "enabled": true,
      "requireManualEnable": false,
      "maxRunsPerBranch": 3,
      "maxRunsPerDay": 3,
      "outputDir": "dev"
    }
  }
}
```

**Roles.** Each role's model is set at `multiAgent.roles.<role>.model`. The value must be an alias: `opus`, `sonnet`, `haiku`, or `fable`. To change a model for one person, put the override in `.claude/settings.local.json`. The effective config is `settings.json` deep-merged with `settings.local.json`, and the local file wins for each key it sets.

**Enforcement.** The orchestrator passes each role's model as the `model` parameter on every agent call. `agent-gate.sh` denies a call whose model does not match the configured model for that role. It also denies a call that passes the architect's model to an agent with no configured role, such as `general-purpose`. If the `multiAgent` key is missing from both files, the gate allows everything, so the framework is off until it is configured. If either settings file is not valid JSON, the gate denies only architect-related agent calls (those containing `fable` or `architect`) and allows everything else, so the broken file can still be fixed.

**Architect settings.** These keys are under `multiAgent.architect`:

- `enabled`: `false` turns the architect off entirely.
- `requireManualEnable`: `true` also requires the environment variable `MULTI_AGENT_ENABLE_ARCHITECT=1` in the environment that Claude Code was started with:

```bash
MULTI_AGENT_ENABLE_ARCHITECT=1 claude
```

- `maxRunsPerBranch`: cap on architect runs per git branch. `0` means no cap. See the fork-point rule below.
- `maxRunsPerDay`: cap on architect runs per UTC calendar day. `0` means no cap.
- `outputDir`: repo-relative directory the architect may write into. Default `dev`. Every architect output path in this README is written as `<outputDir>/...`, so it follows this setting.
- `runLog`: where the run log is kept (see **Run log** below). Absent means `<outputDir>/.architect-runs.log`, which is `dev/.architect-runs.log` by default. `"git"` keeps the log in the git directory, uncommitted. Any other value is a repo-relative path. Absolute paths and paths outside the repository are refused.

**Run log.** Each allowed architect run is appended to the run log, and the caps count its entries. The hook counts a run when it allows the Agent call, even if you decline it afterwards or it fails. To undo a run, remove that run's line from the log. By default the log is `<outputDir>/.architect-runs.log`, committed with the architect's output, so the caps survive across clones (including cloud sessions). Set `runLog` to `"git"` to keep the log in the git directory (`<git common dir>/multi-agent/architect-runs.log`) instead. That log is never committed, and the caps reset when the clone is recreated. If the project is not a git repository, the `"git"` option uses `.claude/.multi-agent-state/` instead.

**Fork-point rule.** `maxRunsPerBranch` counts only entries dated on or after the branch's fork point. The fork point is the UTC committer date (day granularity) of `git merge-base HEAD <base>`, where the base is the first of `origin/HEAD`, `main`, `master`, `origin/main`, or `origin/master` that exists. With no base, or on the base branch itself, every entry for the branch counts. Merging or rebasing the latest default branch into a live feature branch moves the fork point forward, so earlier runs on that branch stop counting toward the per-branch cap. `maxRunsPerDay` is not affected. This is a soft cost guardrail.

**Overriding the log location.** If the environment variable `MULTI_AGENT_STATE_DIR` is set, it overrides `runLog` and `outputDir`: the log is `$MULTI_AGENT_STATE_DIR/architect-runs.log`. It is mainly for tests. Leave it unset normally.

## Requirements

- Claude Code 2.1.295 or later. The hook uses the `onFailure` setting, which older versions do not support.
- bash, and curl or wget.
- jq, strongly recommended. Without it, the installer cannot merge into an existing `settings.json` (it leaves the file unchanged and prints the entries to add by hand). `agent-gate.sh` also needs jq. Without it, the gate denies every architect agent call (any Agent or Task call containing `fable` or `architect`), and it cannot enforce the architect's run limits or output directory. `block-git-write.sh` fails closed without jq, but only for Bash calls that carry `agent_id`, which every real subagent call does. Main-session calls are allowed.
- git.
- Windows: native Windows needs WSL or Git Bash, with bash, jq, and git available inside it.

## Cloud sessions

The framework works in Claude Code cloud sessions that have a single repository. Other cloud setups load less of it, as the table shows.

| Session type | Hooks run | Agents load | Notes |
|---|---|---|---|
| Local | Yes, from `.claude/settings.json` and the agents' frontmatter (frontmatter hooks need a trusted workspace) | Yes | Per-person overrides in `.claude/settings.local.json` apply. |
| Cloud with one repository | Yes, from the repo's `.claude/settings.json` (frontmatter hooks do not run) | Yes | `CLAUDE.md` and its `@` imports load. `settings.local.json` is not read. |
| Cloud with several repositories | No | Not documented; do not rely on it | The session starts above the clones and reads only `enabledPlugins` and `extraKnownMarketplaces` from each repo's settings. |
| Cloud thread in a project | No | No | Threads inside a project apply none of the repo's settings hooks, permissions, or env, and do not load `.claude/agents/`. |

- **Installing from a cloud session.** Ask the session to run the one-line installer, then review and commit the result. The default network setting (Trusted) allows `raw.githubusercontent.com`, so the installer works as is:

```bash
curl -fsSL https://raw.githubusercontent.com/wolviex/Claude-Multi-Agent/main/install.sh | bash
```

  With no network access or a custom network, add `raw.githubusercontent.com` to the allowed hosts, or install locally and push the commit.

- **Architect switch.** There is no command line to prefix, so set `MULTI_AGENT_ENABLE_ARCHITECT=1` in the cloud environment's settings. It reaches the commands the session runs.
- **jq and the setup script.** jq is in the default cloud image. A custom image without jq needs this line in the environment's setup script:

```bash
apt-get install -y jq
```

- **Run log persistence.** Each cloud session is a fresh clone on a fresh VM, so anything under `.git` is lost between sessions. The default run log, `<outputDir>/.architect-runs.log` (`dev/.architect-runs.log` with the default `outputDir`), is committed with the architect's output, so the caps survive from one session to the next. Setting `runLog` to `"git"` keeps the log in the git directory instead. It is never committed, and the caps reset whenever the clone is recreated.
- **Per-person settings.** `.claude/settings.local.json` is not read in cloud sessions, because it is not in the clone. Settings that must apply in cloud sessions belong in `.claude/settings.json` or in the cloud environment's variables.
- **Guard check.** Before starting work, the orchestrator confirms that the hooks are present and tells you if enforcement is off. If the hooks are missing, the git guard and the architect gate are not enforced in that session. This happens in multi-repository sessions and cloud threads.

## How it works

### Roles

| Role | Agent | Does | Never does |
|---|---|---|---|
| Orchestrator | none (main session) | Plans and routes work, starts agents, decides architect gates, commits and pushes, gives final sign-off | Edits project files directly |
| Supervisor | `supervisor` | Plans atomic tasks with briefs in Plan mode, reviews every diff in Review mode, returns a verdict | Edits files, starts agents |
| Implementer | `implementer` | Edits files, runs checks, reports what changed | Commits, pushes, starts agents, declares work complete |
| Architect | `architect` | On demand: writes design documents (specs, interface contracts, ADRs) under the output directory | Edits code, starts agents, uses Bash |

**Enforcement.** These rules are guardrails, not security boundaries. Hook-enforced: subagents cannot start agents; subagent git writes are blocked by `block-git-write.sh`, with the bypasses listed in [The git guard](#the-git-guard); mapped roles must be started with their configured model; unmapped framework agent names (`architect`, `supervisor`, `implementer`) are denied; the architect's enable switches and run caps apply; the architect may write only under `outputDir`. Prompt-only, not enforced by any hook: the orchestrator does not edit project files; the supervisor does not write through Bash; the implementer stays within its brief; `general-purpose` and other unmapped agents carry none of the role rules. The git hook still applies to them, because it keys on `agent_id`.

Models for each role are set in [Configure models and the architect](#configure-models-and-the-architect).

### The review gate

Each task moves through these steps:

1. **Plan.** The orchestrator sends the objective to `supervisor` in Plan mode. It returns atomic tasks, each as a task brief, with dependencies and an `Architect gate:` line.
2. **Gate check.** The orchestrator decides whether an architect gate applies. If gate 1 applies, the architect runs before any implementation starts.
3. **Brief.** Start one `implementer` per task, using the supervisor's task brief.
4. **Implement.** The implementer edits files, runs the checks, and returns a structured report.
5. **Review.** The orchestrator marks the task's files with intent-to-add, then sends the brief, the full diff, and the check output to `supervisor` in Review mode.
6. **Iterate.** On `VERDICT: CHANGES_REQUESTED`, the numbered findings go back to the implementer. A task gets at most three review rounds. If the third round is also rejected, or the verdict carries an `Escalation:` line, the orchestrator evaluates architect gate 2.
7. **Accept.** The orchestrator commits only after `VERDICT: APPROVED`, once every required check passes and it has checked the diff itself.
8. **Oversee.** After each commit, the orchestrator checks progress against the plan.
9. **Synthesize and sign off.** When every task is committed, the orchestrator reviews the whole branch diff against the request.

### The architect

The architect is idle unless a gate applies. Only the orchestrator decides whether a gate applies, and only the orchestrator starts the architect.

- **Gate 1, greenfield architecture:** before code starts on a new system or subsystem, it writes interface contracts, API schemas, and a high-level design under `<outputDir>/`.
- **Gate 2, ambiguity and complex decisions:** when the supervisor and implementer loop stalls (a third rejected review round, or an `Escalation:` line), it writes an architecture decision record under `<outputDir>/adr/`.
- **Gate 3, cross-subsystem refactoring:** a macro-level refactor that spans three or more interdependent modules.

Zero pipeline autonomy: the supervisor and implementer cannot start agents, and `agent-gate.sh` denies any agent call made from a subagent.

Context budget: the architect gets a brief with curated inputs (interface files, specs, constraints, and the failing state). It never gets the conversation history or large code dumps.

Usage limits: the architect's switches and run caps are set in [Configure models and the architect](#configure-models-and-the-architect).

The architect writes only under `outputDir`. The orchestrator reviews that output, commits it, and then has the supervisor plan follow-up tasks from it. The run log is written under `outputDir` by default and is committed with that output. Setting `runLog` to `"git"` keeps it out of the commit (see **Run log** in [Configure models and the architect](#configure-models-and-the-architect)).

### The git guard

- Two hooks enforce the guard. `.claude/hooks/block-git-write.sh` runs before every Bash call. For calls from a subagent (identified by `agent_id`, or by `agent_type` of `implementer`, `supervisor`, `architect`, or the legacy `reviewer`), it blocks git write subcommands. Calls from the main session are never blocked, and read-only git commands such as `status` and `diff` are allowed for subagents too.
- Blocked for subagents: `commit`, `push`, `add` and staging, `merge`, `rebase`, `reset`, `checkout`, `switch`, `restore`, `stash` (except `list` and `show`), `fetch`, `pull`, creating or deleting branches and tags, config writes, `apply` (except `--check`, `--stat`, `--numstat`, and `--summary`), and plumbing writes such as `update-index`, `symbolic-ref` writes, and `hash-object -w`. Other history, worktree, and remote changes (for example `cherry-pick`, `revert`, `clean`, `rm`, `mv`, `remote add`, and `worktree add`) are blocked too.
- The hook sees through wrapper commands such as `timeout`, `nice`, `env`, `sudo`, `command`, `stdbuf`, and `ionice`, and through backslash-newline continuations.
- `.claude/hooks/agent-gate.sh` runs on Agent, Task, Write, Edit, and NotebookEdit calls. It enforces model routing and the architect's gates, and it confines architect writes to `outputDir`. It does not see writes made through Bash.
- `block-git-write.sh` is registered in the agents' frontmatter and in `.claude/settings.json`. `agent-gate.sh` is registered only in `.claude/settings.json`. Frontmatter hooks only run in trusted workspaces, so the settings entries also cover untrusted ones, such as cloud sessions.
- It is a guardrail against accidents, not a security boundary. Documented bypasses: indirect invocations such as `$g commit` (variable indirection) and `xargs git commit` are not caught.
- Known limitation: the hook scans each line on its own, including heredoc bodies and multi-line strings. A line inside them that starts with a git write verb is blocked. To write such text, use the Write tool instead of Bash.

## This repository

This repository also uses the framework on browser bookmarklets. Each bookmarklet is documented in `bookmarklets/<name>.md` in the format defined in `AGENTS.md`, and `scripts/check-parity.mjs` verifies that the copyable URL and the readable code are the same program. Run `npm install` first:

```bash
npm install
```

### Tests

Run these after `npm install`:

```bash
npm test                    # parity checker self-test
npm run test:install        # installer tests
npm run test:agent-gate     # agent-gate hook tests (these need jq)
npm run test:git-guard      # git guard hook tests
```

CI (`.github/workflows/ci.yml`) runs all four on every push and pull request. It also checks the shell syntax of `install.sh`, `.claude/hooks/*.sh`, and `scripts/*.sh`.
