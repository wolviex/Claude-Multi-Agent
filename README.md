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
- Registers the hooks in `.claude/settings.json`. It creates the file if it is missing. If the file exists, it keeps your other settings and adds one entry per matcher (`Bash`, `Agent|Task`, and `Write|Edit|NotebookEdit`) only where it is missing. It never adds a duplicate entry.
- Adds the default `multiAgent` block (see [Configure models and the architect](#configure-models-and-the-architect)) only if `settings.json` has no `multiAgent` key. An existing `multiAgent` key is never overwritten, even with `--force`.
- Reports a legacy `.claude/agents/reviewer.md` if it is present, and does not delete it. See [Updating](#updating).
- Adds `@.claude/multi-agent.md` to `CLAUDE.md`. If `CLAUDE.md` is missing, it creates one with a `## Required checks` placeholder.
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

Without `--force`, a framework file you have edited locally is reported as skipped and left unchanged. Put project-specific rules in `CLAUDE.md` or `AGENTS.md`, not in the framework files, so updates do not overwrite them. `--force` does not change an existing `multiAgent` key, so your role models and architect limits are kept.

Upgrading from the earlier reviewer version: the installer reports `.claude/agents/reviewer.md` as legacy and never deletes it. `.claude/agents/supervisor.md` replaces it. Once you have reviewed the new file, delete `.claude/agents/reviewer.md` yourself. If `settings.json` has no `multiAgent` key, the update adds the defaults.

### Uninstalling

Uninstalling is manual:

1. Delete `.claude/multi-agent.md`, `.claude/agents/implementer.md`, `.claude/agents/supervisor.md`, `.claude/agents/architect.md`, `.claude/hooks/block-git-write.sh`, and `.claude/hooks/agent-gate.sh`.
2. In `.claude/settings.json`, remove the entry whose command contains `block-git-write.sh`, and both entries whose command contains `agent-gate.sh`, from the `hooks.PreToolUse` array. Remove the top-level `multiAgent` key.
3. Remove the `@.claude/multi-agent.md` line from `CLAUDE.md`.

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

- `maxRunsPerBranch`: cap on architect runs per git branch. `0` means no cap.
- `maxRunsPerDay`: cap on architect runs per UTC calendar day. `0` means no cap.
- `outputDir`: repo-relative directory the architect may write into. Default `dev`.

**Run log.** Each allowed architect run is appended to `architect-runs.log`, which the caps count. The log is kept in the git directory (`<git common dir>/multi-agent/`), so it is never committed. If the project is not a git repository, it is written to `.claude/.multi-agent-state/` instead.

## Requirements

- Claude Code 2.1.295 or later. The hook uses the `onFailure` setting, which older versions do not support.
- bash, and curl or wget.
- jq, strongly recommended. Without it, the installer cannot merge into an existing `settings.json` (it leaves the file unchanged and prints the entries to add by hand). `agent-gate.sh` also needs jq. Without it, the gate refuses every architect agent call (any call containing `fable` or `architect`), and it cannot enforce the architect's run limits or output directory. The `block-git-write.sh` hook blocks all subagent Bash calls, because it fails closed when it cannot parse the command.
- git.

## How it works

### Roles

| Role | Agent | Does | Never does |
|---|---|---|---|
| Orchestrator | none (main session) | Plans and routes work, starts agents, decides architect gates, commits and pushes, gives final sign-off | Edits project files directly |
| Supervisor | `supervisor` | Plans atomic tasks with briefs in Plan mode, reviews every diff in Review mode, returns a verdict | Edits files, starts agents |
| Implementer | `implementer` | Edits files, runs checks, reports what changed | Commits, pushes, starts agents, declares work complete |
| Architect | `architect` | On demand: writes design documents (specs, interface contracts, ADRs) under the output directory | Edits code, starts agents, uses Bash |

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

- **Gate 1, greenfield architecture:** before code starts on a new system or subsystem, it writes interface contracts, API schemas, and a high-level design.
- **Gate 2, ambiguity and complex decisions:** when the supervisor and implementer loop stalls (a third rejected review round, or an `Escalation:` line), it writes an architecture decision record under `dev/adr/`.
- **Gate 3, cross-subsystem refactoring:** a macro-level refactor that spans three or more interdependent modules.

Zero pipeline autonomy: the supervisor and implementer cannot start agents, and `agent-gate.sh` denies any agent call made from a subagent.

Context budget: the architect gets a brief with curated inputs (interface files, specs, constraints, and the failing state). It never gets the conversation history or large code dumps.

Usage limits: the architect's switches and run caps are set in [Configure models and the architect](#configure-models-and-the-architect).

The architect writes only under `outputDir`. The orchestrator reviews that output, commits it, and then has the supervisor plan follow-up tasks from it.

### The git guard

- Two hooks enforce the guard. `.claude/hooks/block-git-write.sh` runs before every Bash call. For calls from a subagent (identified by `agent_id`, or by `agent_type` of `implementer`, `supervisor`, `architect`, or the legacy `reviewer`), it blocks git write subcommands such as `commit`, `push`, `add`, `merge`, `rebase`, and `reset`. Other git commands, such as `status` and `diff`, are allowed. Calls from the main session are never blocked.
- `.claude/hooks/agent-gate.sh` runs on Agent, Task, Write, Edit, and NotebookEdit calls. It enforces model routing and the architect's gates, and it confines architect writes to `outputDir`. It does not see writes made through Bash.
- `block-git-write.sh` is registered in the agents' frontmatter and in `.claude/settings.json`. `agent-gate.sh` is registered only in `.claude/settings.json`. Frontmatter hooks only run in trusted workspaces, so the settings entries also cover untrusted ones, such as cloud sessions.
- It is a guardrail against accidents, not a security boundary. Indirect calls such as `$g commit` or `xargs git commit` are not caught.
- Known limitation: the hook scans each line on its own, so a line inside a heredoc or multi-line string that starts with a git write verb is blocked. To write such text, use the Write tool instead of Bash.

## This repository

This repository also uses the framework on browser bookmarklets. Each bookmarklet is documented in `bookmarklets/<name>.md` in the format defined in `AGENTS.md`, and `scripts/check-parity.mjs` verifies that the copyable URL and the readable code are the same program. Run `npm install` first:

```bash
npm install
```

Then run `npm test` for the parity checker's self-test:

```bash
npm test
```

Run `npm run test:install` for the installer tests:

```bash
npm run test:install
```

Run `npm run test:agent-gate` for the agent-gate hook tests (these need jq):

```bash
npm run test:agent-gate
```
