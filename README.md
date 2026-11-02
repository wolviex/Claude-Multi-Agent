# Claude-Multi-Agent

A drop-in multi-agent workflow for Claude Code. Opus plans the work, briefs the workers, and gives final sign-off. Haiku makes the edits and runs the checks, and Sonnet reviews every change and returns an explicit verdict before anything is committed. A PreToolUse hook stops subagents from running git write commands, so only the main session commits.

## Install into an existing project

Run this from anywhere inside the project's git repository:

```bash
curl -fsSL https://raw.githubusercontent.com/wolviex/Claude-Multi-Agent/main/install.sh | bash
```

The installer targets the repository's top-level directory. Outside a git repository, it uses the current directory.

What it does:

- Copies four framework files:
  - `.claude/multi-agent.md`: the workflow, with roles, the review gate, brief and report formats, and git rules.
  - `.claude/agents/implementer.md`: the Haiku `implementer` subagent that edits files and runs checks.
  - `.claude/agents/reviewer.md`: the Sonnet `reviewer` subagent that checks each diff and returns a verdict.
  - `.claude/hooks/block-git-write.sh`: the hook that blocks git write commands from subagents.
- Registers the hook in `.claude/settings.json`. It creates the file if it is missing. If the file exists, it adds the entry with jq and keeps your other settings. It never adds a duplicate entry.
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
2. List the project's required checks in `CLAUDE.md` under `## Required checks`. Examples: `npm test`, or `node --check <file>` for each changed `.js` file. The implementer runs these checks and the reviewer reruns them.
3. Start Claude Code and select Opus with `/model`. The workflow tells the orchestrator to stop and tell you if Opus is not available.
4. Describe a request as usual. The orchestrator plans the work, briefs `implementer`, sends each diff to `reviewer`, and commits only after `VERDICT: APPROVED`.

### Updating

Re-run the installer with `--force`:

```bash
curl -fsSL https://raw.githubusercontent.com/wolviex/Claude-Multi-Agent/main/install.sh | bash -s -- --force
```

Without `--force`, a framework file you have edited locally is reported as skipped and left unchanged. Put project-specific rules in `CLAUDE.md` or `AGENTS.md`, not in the framework files, so updates do not overwrite them.

### Uninstalling

Uninstalling is manual:

1. Delete `.claude/multi-agent.md`, `.claude/agents/implementer.md`, `.claude/agents/reviewer.md`, and `.claude/hooks/block-git-write.sh`.
2. Remove the entry whose command contains `block-git-write.sh` from the `PreToolUse` array in `.claude/settings.json`.
3. Remove the `@.claude/multi-agent.md` line from `CLAUDE.md`.

## Requirements

- Claude Code 2.1.295 or later. The hook uses the `onFailure` setting, which older versions do not support.
- bash, and curl or wget.
- jq, strongly recommended. Without it, the installer cannot merge into an existing `settings.json` (it leaves the file unchanged and prints the entry to add by hand). The hook then blocks subagent Bash calls, because it fails closed when it cannot parse the command.
- git.

## How it works

### Roles

| Role | Who | Does | Never does |
|---|---|---|---|
| Planner and senior manager (orchestrator) | Main session, Opus | Plans, writes briefs, reviews progress, gives final sign-off, commits and pushes | Edits project files directly |
| Worker (implementer) | `implementer` subagent, Haiku | Edits files, runs checks, reports what changed | Commits, pushes, spawns agents, declares work complete |
| Advisor and supervisor (reviewer) | `reviewer` subagent, Sonnet | Reruns checks, reviews every diff, returns a verdict | Edits files |

### The review gate

Each task moves through these steps:

1. **Plan.** Split the request into tasks that each change one file, or one tightly coupled set of files.
2. **Brief.** Start one `implementer` per task, using a fixed brief template.
3. **Implement.** The implementer edits files, runs the checks, and returns a structured report.
4. **Review.** The orchestrator marks the task's files with intent-to-add, then sends the brief, the full diff, and the check output to `reviewer`.
5. **Iterate.** On `VERDICT: CHANGES_REQUESTED`, the numbered findings go back to the implementer. A task gets at most three review rounds.
6. **Accept.** The orchestrator commits only after `VERDICT: APPROVED`, once every required check passes and it has checked the diff itself.
7. **Oversee.** After each commit, the orchestrator checks progress against the plan.
8. **Sign off.** When every task is committed, the orchestrator reviews the whole branch diff against the request.

### The git guard

- `.claude/hooks/block-git-write.sh` runs before every Bash call. For calls from a subagent (identified by `agent_id`, or by `agent_type` of `implementer` or `reviewer`), it blocks git write subcommands such as `commit`, `push`, `add`, `merge`, `rebase`, and `reset`. Other git commands, such as `status` and `diff`, are allowed. Calls from the main session are never blocked.
- The hook is registered in each agent's frontmatter and in `.claude/settings.json`. Frontmatter hooks only run in trusted workspaces, so the settings entry also covers untrusted ones, such as cloud sessions.
- It is a guardrail against accidents, not a security boundary. Indirect calls such as `$g commit` or `xargs git commit` are not caught.
- Known limitation: the hook scans each line on its own, so a line inside a heredoc or multi-line string that starts with a git write verb is blocked. To write such text, use the Write tool instead of Bash.

## This repository

This repository also uses the framework on browser bookmarklets. Each bookmarklet is documented in `bookmarklets/<name>.md` in the format defined in `AGENTS.md`, and `scripts/check-parity.mjs` verifies that the copyable URL and the readable code are the same program. Run `npm install` first. Then run `npm test` for the parity checker's self-test, and `npm run test:install` for the installer tests.
