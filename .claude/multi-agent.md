# Multi-agent workflow

This file defines how work is split between models and when a change is accepted. It is installed by [Claude-Multi-Agent](https://github.com/wolviex/Claude-Multi-Agent); re-run the installer with `--force` to update it. Put project-specific rules, including the project's required checks, in CLAUDE.md or AGENTS.md, not here.

## Roles

| Role | Agent | Does | Never does |
|---|---|---|---|
| orchestrator | none (main session) | Top-level orchestrator and controller: owns state, pipeline execution, task routing, commits, and final synthesis and sign-off. Only role that may spawn agents. | Edit project files directly. |
| supervisor | `supervisor` | Task planner and supervisor: breaks objectives into atomic tasks with briefs, defines test-driven validation, runs static analysis and diff review, returns verdicts. | Edit files. Spawn agents. |
| implementer | `implementer` | Code writer: single-file or localized edits per brief, runs checks, reports. Its work goes back to the supervisor for verification (the orchestrator relays it unchanged; the implementer cannot call agents). | Commit. Spawn agents. Declare work complete. |
| architect | `architect` | On-demand systems architect and domain synthesizer. Idle by default. Only the orchestrator invokes it, and only when a gate in the Architect section triggers. Writes design documents only, under the configured output directory (default `dev`). | Edit code. Spawn agents. Use Bash. |

**Models come from settings.** Each role's model is set in `multiAgent.roles` in `.claude/settings.json`. A person can override it in `.claude/settings.local.json`. Defaults: orchestrator `opus`, supervisor `sonnet`, implementer `haiku`, architect `fable`. Values must be one of the aliases `opus`, `sonnet`, `haiku`, or `fable`. When starting a subagent, the orchestrator always passes that role's model as the Agent tool's `model` parameter. The `agent-gate.sh` hook rejects a call whose model does not match.

**Model check.** Before starting work, the orchestrator reads `multiAgent.roles` (the merge of `settings.json` and `settings.local.json`) and confirms it is running on `roles.orchestrator.model` (for example with the session's model info or `/model`). If it is not, it tells the user before beginning and waits for direction.

The definitions are in `.claude/agents/`, and each file's frontmatter pins its tools. The model is not pinned there; it comes from settings. Always delegate by agent name (`implementer`, `supervisor`, or `architect`). A general-purpose agent with a model override does not carry these rules or the git hook.

Claude Code has no `advisor` tool. The Claude API's advisor tool is not available to subagents here. The `supervisor` subagent plays the advisor role, and the orchestrator handles the handoff because the implementer cannot spawn agents.

**If you are a subagent reading this file:** you do not run the review gate. The orchestrator does. An implementer's `Status: DONE` means only that its edits and checks are finished. It does not mean the work is accepted or complete, and acceptance still needs `VERDICT: APPROVED`. Use `BLOCKED` only when you could not make the edits or run the checks, including when a tool call was denied. A check that ran and failed is reported as `DONE` with the `FAIL` output, unless it failed because of your change and you can fix it within the brief. In that case, fix it, rerun, and report the result. Never use `BLOCKED` because review hasn't happened yet. A supervisor returns its verdict and nothing else. Subagents never start agents, and the architect is invoked only by the orchestrator.

## Workflow

1. **Plan.** The orchestrator sends the objective and relevant files to `supervisor` in Plan mode. The supervisor returns a numbered list of atomic tasks, each a filled task brief, with dependencies and parallelism. Each task changes one file, or one tightly coupled set of files that must change together. The list ends with an `Architect gate:` line, `Architect gate: <1 | 3 | none>`. Gate 2 is never planned; the orchestrator evaluates it only in step 6. The orchestrator reviews the task list and that line. If there are more than three tasks, it lists them for the user before starting.
2. **Gate check.** The orchestrator decides whether an architect gate applies (see the Architect section). If the supervisor said `none`, the orchestrator still considers gates 1 and 3 on its own judgement. If gate 1 applies, it runs the architect before any implementation starts.
3. **Brief.** Start one `implementer` per task, using the supervisor's task brief. The orchestrator may adjust the brief. Independent tasks can run in parallel. Tasks that touch the same file run one after another.
4. **Implement.** The implementer edits, runs the checks, and returns the implementer report.
5. **Review.** The orchestrator runs `git add -N <task files>` and then `git diff -- <task files>` itself, rather than relying on a pasted diff. The intent-to-add step makes new, untracked files show up in the diff, and naming the task's files keeps parallel tasks out of each other's reviews. It then starts `supervisor` in Review mode and sends the task brief, the full diff, and the implementer's check output, beginning with this prompt: *"Review this code implementation against project standards and verify it passes structural checks."*
6. **Iterate.** On `VERDICT: CHANGES_REQUESTED`, send the supervisor's numbered findings word for word to the same implementer (continue it with SendMessage, or start a new `implementer` with the original brief plus the findings if it can't be resumed), then go back to step 5 with a new review. Each task gets at most 3 review rounds. If the third round is also rejected, or the verdict carries an `Escalation:` line, the orchestrator evaluates architect gate 2. If gate 2 applies, the orchestrator runs the architect and then has the supervisor plan the follow-up work. Follow-up tasks planned from an architect run are new tasks and get a fresh 3 review rounds. A task that triggered gate 2 is closed and replaced by those follow-ups. If it does not apply, the orchestrator stops and reports the unresolved findings to the user.
7. **Accept.** The orchestrator commits only after `VERDICT: APPROVED`, once every required check passes, and after its own senior check of the diff. Make one commit per approved task, with a message that describes the change.
8. **Oversee.** After each commit, the orchestrator reviews progress against the plan and either confirms the next task or redirects with revised briefs.
9. **Synthesize and sign off.** When every task is committed, the orchestrator reviews the whole branch diff (`git diff origin/main...HEAD`) against the request and writes the final summary for the user. The work is finished only after this sign-off.

If the implementer reports `BLOCKED`, the orchestrator fixes the brief or asks the user. It does not make the edit itself. If the permission system denied one of the implementer's tool calls, nobody retries it in another form: the orchestrator revises the brief to avoid that action or reports the denial to the user.

## Architect (on demand)

The architect is idle unless one of these gates applies. Only the orchestrator decides whether a gate applies.

1. **Greenfield architecture and interface contracts.** Once, before code generation begins on a new system or subsystem: cross-boundary interface specs, API schemas, and high-level design (for example `dev/project_spec.md`).
2. **Ambiguity and complex decision gate.** When an edge case or platform constraint stalls the supervisor and implementer loop (for example, a task hits its third rejected review round, or the supervisor's verdict carries an `Escalation:` line), the architect evaluates the non-standard pattern and writes an architecture decision record (ADR) at `dev/adr/NNNN-<kebab-title>.md`.
3. **Cross-subsystem refactoring.** Macro-level refactors that span three or more interdependent modules. Single-module work and pull-request linting stay with the supervisor.

**Threshold rule.** Before invoking the architect, the orchestrator states which gate applies and why the problem exceeds both the supervisor's and its own architectural threshold. If no gate applies, it does not invoke the architect.

**Zero pipeline autonomy.** Only the orchestrator invokes the architect. The supervisor and implementer cannot start agents. The `agent-gate.sh` hook rejects any agent call from a subagent, and any call that passes the architect's model to an agent with no configured role (for example `general-purpose`).

**Context budget.** The architect gets an architect brief with curated inputs: interface files, specs, constraints, and the specific failing state. Never the conversation history, and never large code dumps.

**Usage limits.** The limits are set under `multiAgent.architect` in `.claude/settings.json` (or `settings.local.json`). `agent-gate.sh` enforces them and keeps the run log in the git directory, where it is never committed.

- `enabled`: `false` turns the architect off entirely.
- `requireManualEnable`: `true` also requires `MULTI_AGENT_ENABLE_ARCHITECT=1` in the environment Claude Code was started with, for example `MULTI_AGENT_ENABLE_ARCHITECT=1 claude`.
- `maxRunsPerBranch`: cap on architect runs per git branch. `0` means no cap.
- `maxRunsPerDay`: cap on architect runs per UTC calendar day. `0` means no cap.
- `outputDir`: repo-relative directory the architect may write into (default `dev`).

**Output.** The architect writes only under `outputDir`. The orchestrator reviews the architect's output itself, commits it (one commit per architect run), and then has the supervisor plan follow-up tasks from it.

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

## Architect brief (orchestrator → architect)

```
Gate: <1 | 2 | 3> - <why this exceeds supervisor and orchestrator thresholds>
Question: <the decision or design to produce>
Inputs: <exact file paths to read: interfaces, specs, prior ADRs; keep it short>
Constraints: <platform limits, non-goals, compatibility requirements>
Output: <exact path under dev/, e.g. dev/adr/0003-surface-input-routing.md>
```

## Architect report (architect → orchestrator)

```
Status: DONE | BLOCKED (<reason>)
Output: <path written>
Decision: <one paragraph>
Consequences: <what implementers and the supervisor must now do differently>
Open questions: <or "none">
```

## Supervisor verdict (supervisor → orchestrator)

The first line is exactly `VERDICT: APPROVED` or `VERDICT: CHANGES_REQUESTED`. Numbered findings follow, each in this form: `<n>. [blocking|non-blocking] <file>:<line> - <problem> - <exact fix>`. An approval can include only non-blocking findings. If there are no findings, write `No findings.` If the verdict line is missing or unclear, treat it as `CHANGES_REQUESTED`.

After the findings, the verdict may include one `Escalation: <reason>` line. It recommends architect gate 2 to the orchestrator. The supervisor never invokes the architect itself.

## Required checks

- The project lists its required checks in CLAUDE.md or AGENTS.md (for example tests, linters, or format checks for particular file types). If it lists none, ask the user before the first task.
- The orchestrator copies the checks that apply to a task into the brief's `Checks to run`. The implementer runs them, and the supervisor reruns them.
- A check that could not run counts as a failure. Report it as `BLOCKED` and never as a pass.

## Git

- Only the orchestrator commits or pushes, and only after approval. A PreToolUse hook (`.claude/hooks/block-git-write.sh`) blocks git write commands from subagents and allows main-session calls. It is registered in `.claude/settings.json` and in each agent's frontmatter; frontmatter hooks only run in a trusted workspace, so the settings registration is what covers untrusted ones such as cloud sessions.
- A second PreToolUse hook, `.claude/hooks/agent-gate.sh`, routes models and gates the architect. It is registered in `.claude/settings.json` for the Agent tool and for the Write, Edit, and NotebookEdit tools.
- Work on the session's feature branch. Never commit or push to `main` or `master`; merging is the user's decision. Open a pull request only when the user asks.
- Environment reminders to commit (such as a Stop hook) do not override the review gate. Commit only approved work.
