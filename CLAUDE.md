# CLAUDE.md

@AGENTS.md

AGENTS.md, imported above, defines the bookmarklet document format and the code-parity rules. This file defines how work is split between models and when a change is accepted.

## Roles

| Role | Who | Does | Never does |
|---|---|---|---|
| Orchestrator | Main session (Opus) | Plans, writes task briefs, sends each diff to review, decides whether to iterate, commits and pushes | Edit project files directly |
| Implementer | `implementer` subagent (Haiku) | Edits files, runs checks, reports what changed | Commit, push, spawn agents, declare work complete |
| Reviewer | `reviewer` subagent (Sonnet) | Reruns checks, reviews the diff, returns a verdict | Edit files |

The definitions are in `.claude/agents/`, and each file's frontmatter pins its model and tools. Always delegate by agent name (`implementer` or `reviewer`). A general-purpose agent with a model override does not carry these rules or the git hook.

Claude Code has no `advisor` tool. The Claude API's advisor tool is not available to subagents here. The `reviewer` subagent plays the advisor role, and the orchestrator handles the handoff because the implementer cannot spawn agents.

**If you are a subagent reading this file:** you do not run the review gate. The orchestrator does. An implementer's `Status: DONE` means only that its edits and checks are finished. It does not mean the work is accepted or complete, and acceptance still needs `VERDICT: APPROVED`. Use `BLOCKED` only when you could not make the edits or run the checks. Never use it because review hasn't happened yet. A reviewer returns its verdict and nothing else.

## Workflow

1. **Plan.** Break the request into tasks that each change one file, or one tightly coupled set such as a bookmarklet's copyable URL and readable code. If there are more than three tasks, list them for the user before starting.
2. **Brief.** Start one `implementer` per task, using the brief template below. Independent tasks can run in parallel. Tasks that touch the same file run one after another.
3. **Implement.** The implementer edits, runs the checks, and returns the report template.
4. **Review.** The orchestrator runs `git add -N .` and then `git diff` itself, rather than relying on a pasted diff. The intent-to-add step makes new, untracked files show up in the diff. It then starts `reviewer` and sends the task brief, the full diff, and the implementer's check output, beginning with this prompt: *"Review this code implementation against project standards and verify it passes structural checks."*
5. **Iterate.** On `VERDICT: CHANGES_REQUESTED`, send the reviewer's numbered findings word for word to the same implementer (continue it with SendMessage, or start a new `implementer` with the original brief plus the findings if it can't be resumed), then go back to step 4 with a new review. Each task gets at most 3 review rounds. If the third round is also rejected, stop and report the unresolved findings to the user.
6. **Accept.** The orchestrator commits only after `VERDICT: APPROVED` and once every required check passes. Make one commit per approved task, with a message that describes the change.

If the implementer reports `BLOCKED`, the orchestrator fixes the brief or asks the user. It does not make the edit itself.

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

The first line is exactly `VERDICT: APPROVED` or `VERDICT: CHANGES_REQUESTED`. Numbered findings follow, each in this form: `<n>. [blocking|non-blocking] <file>:<line> — <problem> — <exact fix>`. An approval can include only non-blocking findings. If the verdict line is missing or unclear, treat it as `CHANGES_REQUESTED`.

## Required checks

- For every changed bookmarklet `.md`, run `node scripts/check-parity.mjs <file>`. It checks AST parity, that the URL is a single line, the `javascript:` prefix, and the IIFE wrapper. If `node_modules` is missing, run `npm install` once first.
- For every changed `.js` or `.mjs` file, run `node --check <file>`.
- A check that could not run counts as a failure. Report it as `BLOCKED` and never as a pass.

## Git

- Only the orchestrator commits or pushes, and only after approval. A PreToolUse hook (`.claude/hooks/block-git-write.sh`) blocks git write commands from the `implementer` and `reviewer` subagents.
- Work on the session's feature branch. Never commit directly to `main` or `master`.