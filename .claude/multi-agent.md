# Multi-agent workflow

This file defines how work is split between models and when a change is accepted. It is installed by [Claude-Multi-Agent](https://github.com/wolviex/Claude-Multi-Agent); re-run the installer with `--force` to update it. Put project-specific rules, including the project's required checks, in CLAUDE.md or AGENTS.md, not here.

## Roles

| Role | Who | Does | Never does |
|---|---|---|---|
| Planner and senior manager (orchestrator) | Main session (Opus) | Plans, writes task briefs, sends every worker diff to the supervisor, reviews progress periodically and redirects or confirms, gives final sign-off, commits and pushes | Edit project files directly |
| Worker (implementer) | `implementer` subagent (Haiku) | Edits files, runs checks, reports what changed | Commit, push, spawn agents, declare work complete |
| Advisor and supervisor (reviewer) | `reviewer` subagent (Sonnet) | Reruns checks, reviews every worker diff, returns a verdict | Edit files |

**Model check.** Before starting work, the orchestrator confirms it is running on Opus (for example with the session's model info or `/model`). If Opus is not available, it tells the user before beginning and waits for direction.

The definitions are in `.claude/agents/`, and each file's frontmatter pins its model and tools. Always delegate by agent name (`implementer` or `reviewer`). A general-purpose agent with a model override does not carry these rules or the git hook.

Claude Code has no `advisor` tool. The Claude API's advisor tool is not available to subagents here. The `reviewer` subagent plays the advisor role, and the orchestrator handles the handoff because the implementer cannot spawn agents.

**If you are a subagent reading this file:** you do not run the review gate. The orchestrator does. An implementer's `Status: DONE` means only that its edits and checks are finished. It does not mean the work is accepted or complete, and acceptance still needs `VERDICT: APPROVED`. Use `BLOCKED` only when you could not make the edits or run the checks, including when a tool call was denied. A check that ran and failed is reported as `DONE` with the `FAIL` output, unless it failed because of your change and you can fix it within the brief. In that case, fix it, rerun, and report the result. Never use `BLOCKED` because review hasn't happened yet. A reviewer returns its verdict and nothing else.

## Workflow

1. **Plan.** Break the request into tasks that each change one file, or one tightly coupled set of files that must change together. If there are more than three tasks, list them for the user before starting.
2. **Brief.** Start one `implementer` per task, using the brief template below. Independent tasks can run in parallel. Tasks that touch the same file run one after another.
3. **Implement.** The implementer edits, runs the checks, and returns the report template.
4. **Review.** The orchestrator runs `git add -N <task files>` and then `git diff -- <task files>` itself, rather than relying on a pasted diff. The intent-to-add step makes new, untracked files show up in the diff, and naming the task's files keeps parallel tasks out of each other's reviews. It then starts `reviewer` and sends the task brief, the full diff, and the implementer's check output, beginning with this prompt: *"Review this code implementation against project standards and verify it passes structural checks."*
5. **Iterate.** On `VERDICT: CHANGES_REQUESTED`, send the reviewer's numbered findings word for word to the same implementer (continue it with SendMessage, or start a new `implementer` with the original brief plus the findings if it can't be resumed), then go back to step 4 with a new review. Each task gets at most 3 review rounds. If the third round is also rejected, stop and report the unresolved findings to the user.
6. **Accept.** The orchestrator commits only after `VERDICT: APPROVED`, once every required check passes, and after its own senior check of the diff. Make one commit per approved task, with a message that describes the change.
7. **Oversee.** After each commit, the orchestrator reviews progress against the plan and either confirms the next task or redirects with revised briefs.
8. **Sign off.** When every task is committed, the orchestrator reviews the whole branch diff (`git diff origin/main...HEAD`) against the request. The work is finished only after this final sign-off, which goes in the summary to the user.

If the implementer reports `BLOCKED`, the orchestrator fixes the brief or asks the user. It does not make the edit itself. If the permission system denied one of the implementer's tool calls, nobody retries it in another form: the orchestrator revises the brief to avoid that action or reports the denial to the user.

## Task brief (orchestrator → implementer)

```
Task: <one sentence>
Files: <exact paths; touch nothing else>
Requirements: <numbered, each one checkable>
Checks to run: <exact commands>
Out of scope: <things not to change>
```

## Implementer report (implementer → orchestrator)

```
Status: DONE | BLOCKED (<reason>)
Files changed: <paths>
Checks: <each command, PASS or FAIL, relevant output>
Findings addressed: <finding numbers, or "n/a">
Notes: <assumptions, disagreements, anything unverified>
```

## Reviewer verdict (reviewer → orchestrator)

The first line is exactly `VERDICT: APPROVED` or `VERDICT: CHANGES_REQUESTED`. Numbered findings follow, each in this form: `<n>. [blocking|non-blocking] <file>:<line> — <problem> — <exact fix>`. An approval can include only non-blocking findings. If there are no findings, write `No findings.` If the verdict line is missing or unclear, treat it as `CHANGES_REQUESTED`.

## Required checks

- The project lists its required checks in CLAUDE.md or AGENTS.md (for example tests, linters, or format checks for particular file types). If it lists none, ask the user before the first task.
- The orchestrator copies the checks that apply to a task into the brief's `Checks to run`. The implementer runs them, and the reviewer reruns them.
- A check that could not run counts as a failure. Report it as `BLOCKED` and never as a pass.

## Git

- Only the orchestrator commits or pushes, and only after approval. A PreToolUse hook (`.claude/hooks/block-git-write.sh`) blocks git write commands from subagents and allows main-session calls. It is registered in `.claude/settings.json` and in each agent's frontmatter; frontmatter hooks only run in a trusted workspace, so the settings registration is what covers untrusted ones such as cloud sessions.
- Work on the session's feature branch. Never commit or push to `main` or `master`; merging is the user's decision. Open a pull request only when the user asks.
- Environment reminders to commit (such as a Stop hook) do not override the review gate. Commit only approved work.
