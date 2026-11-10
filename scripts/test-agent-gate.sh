#!/usr/bin/env bash
# Tests for .claude/hooks/agent-gate.sh. Self-contained: every case runs in its own mktemp project and
# state directory, under one temp root that is removed on exit. The repo's .claude/settings.json is
# checksummed before and after the run and must not change.
# Usage: bash scripts/test-agent-gate.sh   (needs jq, git, bash)
set -u

repo="$(cd "$(dirname "$0")/.." && pwd)"
hook="$repo/.claude/hooks/agent-gate.sh"
repo_settings="$repo/.claude/settings.json"

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required to run these tests"
  exit 1
fi
if [ ! -f "$hook" ]; then
  echo "FAIL: hook not found: $hook"
  exit 1
fi

tmp_root="$(mktemp -d)"
cleanup() { rm -rf "$tmp_root"; }
trap cleanup EXIT

pass=0
fail=0
PROJ=""
STATE=""
OUT=""
RC=0
today="$(date -u +%Y-%m-%d)"

ok() { pass=$((pass + 1)); echo "PASS: $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1 -- $2"; }

# Checksum of a file, or "absent".
sum_of() {
  if [ -f "$1" ]; then cksum < "$1"; else echo "absent"; fi
}
repo_before="$(sum_of "$repo_settings")"

# The multiAgent block from the design spec.
SPEC_JSON='{"multiAgent":{"roles":{"orchestrator":{"model":"opus"},"supervisor":{"agent":"supervisor","model":"sonnet"},"implementer":{"agent":"implementer","model":"haiku"},"architect":{"agent":"architect","model":"fable"}},"architect":{"enabled":true,"requireManualEnable":false,"maxRunsPerBranch":3,"maxRunsPerDay":3,"outputDir":"dev"}}}'

# new_case: fresh project dir and state dir for one case.
new_case() {
  PROJ="$(mktemp -d "$tmp_root/proj.XXXXXX")"
  STATE="$(mktemp -d "$tmp_root/state.XXXXXX")"
  mkdir -p "$PROJ/.claude"
}

# write_settings [jq-filter]: writes $PROJ/.claude/settings.json with the spec block, optionally transformed by a jq filter.
write_settings() {
  printf '%s\n' "$SPEC_JSON" | jq "${1:-.}" > "$PROJ/.claude/settings.json"
}

# mk_agent SUBAGENT_TYPE MODEL AGENT_ID CALLER_AGENT_TYPE: builds an Agent hook input. Empty means absent.
mk_agent() {
  jq -n --arg st "$1" --arg m "$2" --arg aid "$3" --arg at "$4" --arg cwd "$PROJ" --arg tid "toolu_$RANDOM$RANDOM" '
    {hook_event_name:"PreToolUse", tool_name:"Agent", tool_use_id:$tid, cwd:$cwd,
     tool_input:({prompt:"do the task"} + (if $st == "" then {} else {subagent_type:$st} end) + (if $m == "" then {} else {model:$m} end))}
    + (if $aid == "" then {} else {agent_id:$aid} end)
    + (if $at == "" then {} else {agent_type:$at} end)'
}

# mk_write TOOL_NAME CALLER_AGENT_TYPE PATH: builds a Write/Edit/NotebookEdit hook input. Empty agent type means absent.
mk_write() {
  jq -n --arg tn "$1" --arg at "$2" --arg p "$3" --arg cwd "$PROJ" --arg tid "toolu_$RANDOM$RANDOM" '
    {hook_event_name:"PreToolUse", tool_name:$tn, tool_use_id:$tid, cwd:$cwd,
     tool_input:(if $tn == "NotebookEdit" then {notebook_path:$p, new_source:"x"} else {file_path:$p, content:"x"} end)}
    + (if $at == "" then {} else {agent_type:$at} end)'
}

# run_hook INPUT [VAR=value ...]: runs the hook for the current case. Sets OUT and RC.
run_hook() {
  local input="$1"
  shift
  local -a envs=(CLAUDE_PROJECT_DIR="$PROJ")
  if [ -n "$STATE" ]; then envs+=(MULTI_AGENT_STATE_DIR="$STATE"); fi
  OUT="$(printf '%s' "$input" | env -u MULTI_AGENT_STATE_DIR -u MULTI_AGENT_ENABLE_ARCHITECT "${envs[@]}" "$@" bash "$hook" 2>/dev/null)"
  RC=$?
}

# expect_allow NAME: exit 0 and no output.
expect_allow() {
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "$1"; else bad "$1" "expected allow, got rc=$RC out=$OUT"; fi
}

# expect_deny NAME SUBSTRING: exit 0 and exactly one deny JSON object whose reason contains SUBSTRING.
expect_deny() {
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -s -e --arg s "$2" '
      length == 1 and .[0].hookSpecificOutput.hookEventName == "PreToolUse"
      and .[0].hookSpecificOutput.permissionDecision == "deny"
      and (.[0].hookSpecificOutput.permissionDecisionReason | contains($s))' >/dev/null 2>&1; then
    ok "$1"
  else
    bad "$1" "expected deny containing [$2], got rc=$RC out=$OUT"
  fi
}

# expect_deny_nojq NAME: exit 0 and the fixed deny JSON printed without jq.
expect_deny_nojq() {
  case "$OUT" in
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"multi-agent gate: jq is not installed'*)
      if [ "$RC" -eq 0 ]; then ok "$1"; else bad "$1" "deny printed but rc=$RC"; fi ;;
    *) bad "$1" "expected fixed no-jq deny, got rc=$RC out=$OUT" ;;
  esac
}

# --- a. No multiAgent configured: everything is allowed.
new_case
run_hook "$(mk_agent implementer "" "" "")"
expect_allow "a1 no settings files: Agent implementer without model is allowed"

new_case
printf '%s\n' '{"hooks":{}}' > "$PROJ/.claude/settings.json"
run_hook "$(mk_agent implementer "" "" "")"
expect_allow "a2 settings without multiAgent: Agent implementer without model is allowed"

# --- b. Main session model routing for the implementer (haiku).
new_case
write_settings
run_hook "$(mk_agent implementer haiku "" "")"
expect_allow "b1 main session: Agent implementer model haiku is allowed"
run_hook "$(mk_agent implementer sonnet "" "")"
expect_deny "b2 main session: Agent implementer model sonnet is denied" 'Pass model: "haiku"'
run_hook "$(mk_agent implementer "" "" "")"
expect_deny "b3 main session: Agent implementer with no model is denied" 'Pass model: "haiku"'

# --- c. Other roles, general-purpose and the reserved model.
new_case
write_settings
run_hook "$(mk_agent supervisor sonnet "" "")"
expect_allow "c1 main session: Agent supervisor model sonnet is allowed"
run_hook "$(mk_agent Explore "" "" "")"
expect_allow "c2 main session: Agent Explore without model is allowed"
run_hook "$(mk_agent "" fable "" "")"
expect_deny "c3 general-purpose (subagent_type absent) with model fable is denied" 'reserved for the architect'

# --- d. Subagents may not start agents.
new_case
write_settings
run_hook "$(mk_agent implementer haiku agent-7 implementer)"
expect_deny "d1 Agent with agent_id present (implementer, haiku) is denied" 'Only the orchestrator'
run_hook "$(mk_agent Explore "" agent-7 implementer)"
expect_deny "d2 Agent with agent_id present (Explore) is denied" 'Only the orchestrator'

# --- e. Architect run caps, run log.
new_case
write_settings
git -C "$PROJ" init -q -b feat-x
for i in 1 2 3; do
  run_hook "$(mk_agent architect fable "" "")"
  expect_allow "e1.$i architect fable run $i on branch feat-x is allowed"
done
log="$STATE/architect-runs.log"
if [ "$(grep -c -F "$today"$'\t'"feat-x" "$log" 2>/dev/null)" = "3" ] && [ "$(wc -l < "$log" | tr -d ' ')" = "3" ]; then
  ok "e2 run log has 3 lines in the form <date>TAB<branch>TAB<tool_use_id>"
else
  bad "e2 run log has 3 lines in the form <date>TAB<branch>TAB<tool_use_id>" "log=$(cat "$log" 2>/dev/null)"
fi
run_hook "$(mk_agent architect fable "" "")"
expect_deny "e3 architect 4th run on branch feat-x is denied" 'limit reached for branch'

new_case
write_settings '.multiAgent.architect.maxRunsPerBranch = 0 | .multiAgent.architect.maxRunsPerDay = 2'
run_hook "$(mk_agent architect fable "" "")"
expect_allow "e4 per-day cap 2 (no branch cap): run 1 is allowed"
run_hook "$(mk_agent architect fable "" "")"
expect_allow "e5 per-day cap 2 (no branch cap): run 2 is allowed"
run_hook "$(mk_agent architect fable "" "")"
expect_deny "e6 per-day cap 2 (no branch cap): run 3 is denied" 'per day'

new_case
write_settings
git -C "$PROJ" init -q -b feat-y
STATE=""
run_hook "$(mk_agent architect fable "" "")"
expect_allow "e7 no MULTI_AGENT_STATE_DIR: architect run is allowed"
if [ -f "$PROJ/.git/multi-agent/architect-runs.log" ]; then
  ok "e8 no MULTI_AGENT_STATE_DIR: run log is in the git common dir (.git/multi-agent)"
else
  bad "e8 no MULTI_AGENT_STATE_DIR: run log is in the git common dir (.git/multi-agent)" "log not found"
fi

# --- f. Architect enable switches.
new_case
write_settings '.multiAgent.architect.enabled = false'
run_hook "$(mk_agent architect fable "" "")"
expect_deny "f1 architect.enabled false: architect is denied" 'disabled'

new_case
write_settings '.multiAgent.architect.requireManualEnable = true'
run_hook "$(mk_agent architect fable "" "")"
expect_deny "f2 requireManualEnable true without env: architect is denied" 'MULTI_AGENT_ENABLE_ARCHITECT'
run_hook "$(mk_agent architect fable "" "")" MULTI_AGENT_ENABLE_ARCHITECT=1
expect_allow "f3 requireManualEnable true with MULTI_AGENT_ENABLE_ARCHITECT=1: architect is allowed"

# --- g. settings.local.json overrides the implementer model.
new_case
write_settings
printf '%s\n' '{"multiAgent":{"roles":{"implementer":{"model":"sonnet"}}}}' > "$PROJ/.claude/settings.local.json"
run_hook "$(mk_agent implementer haiku "" "")"
expect_deny "g1 local override implementer=sonnet: haiku is denied" 'Pass model: "sonnet"'
run_hook "$(mk_agent implementer sonnet "" "")"
expect_allow "g2 local override implementer=sonnet: sonnet is allowed"

# --- h. Role model must be an alias.
new_case
write_settings '.multiAgent.roles.implementer.model = "claude-haiku-5-5"'
run_hook "$(mk_agent implementer claude-haiku-5-5 "" "")"
expect_deny "h1 role model is not an alias: Agent is denied" 'alias'

# --- i. Architect write scope.
new_case
write_settings
run_hook "$(mk_write Write architect "$PROJ/dev/adr/0001-x.md")"
expect_allow "i1 architect Write to <proj>/dev/adr/0001-x.md is allowed"
run_hook "$(mk_write Write architect "$PROJ/src/a.ts")"
expect_deny "i2 architect Write to <proj>/src/a.ts is denied" 'may only write under dev/'
run_hook "$(mk_write Write architect "dev/spec.md")"
expect_allow "i3 architect Write to relative dev/spec.md is allowed"
run_hook "$(mk_write Edit architect "$PROJ/dev/../src/a.ts")"
expect_deny "i4 architect Edit to <proj>/dev/../src/a.ts is denied" 'may only write under dev/'
run_hook "$(mk_write Write implementer "src/a.ts")"
expect_allow "i5 implementer Write to src/a.ts is allowed"
run_hook "$(mk_write NotebookEdit architect "$PROJ/src/n.ipynb")"
expect_deny "i6 architect NotebookEdit outside dev is denied" 'may only write under dev/'

# --- j. jq missing.
new_case
write_settings
nojq_bin="$tmp_root/nojq-bin"
mkdir -p "$nojq_bin"
for t in bash cat git date mkdir dirname sed tr printf; do
  p="$(type -P "$t" || true)"
  if [ -n "$p" ]; then ln -s "$p" "$nojq_bin/$t"; fi
done
bash_bin="$(type -P bash)"
if PATH="$nojq_bin" "$bash_bin" -c 'command -v jq' >/dev/null 2>&1; then
  bad "j0 jq is hidden from the restricted PATH" "jq is still visible"
else
  ok "j0 jq is hidden from the restricted PATH"
fi

# run_nojq INPUT: runs the hook with no jq on PATH. Sets OUT and RC.
run_nojq() {
  OUT="$(printf '%s' "$1" | env -i CLAUDE_PROJECT_DIR="$PROJ" PATH="$nojq_bin" "$bash_bin" "$hook" 2>/dev/null)"
  RC=$?
}
run_nojq "$(mk_agent general-purpose fable "" "")"
expect_deny_nojq "j1 no jq: Agent with fable is denied with the fixed JSON"
run_nojq "$(mk_agent architect "" "" "")"
expect_deny_nojq "j2 no jq: Agent with subagent_type architect is denied with the fixed JSON"
run_nojq "$(mk_agent implementer haiku "" "")"
expect_allow "j3 no jq: Agent implementer haiku is allowed"

# --- m. Invalid settings: fail closed for the architect only.
new_case
printf '%s\n' '{"multiAgent": ' > "$PROJ/.claude/settings.json"
run_hook "$(mk_agent architect fable "" "")"
expect_deny "m1 invalid settings.json: Agent architect fable is denied naming settings.json" '.claude/settings.json is not valid JSON'

new_case
write_settings
printf '%s\n' '{"multiAgent": ' > "$PROJ/.claude/settings.local.json"
run_hook "$(mk_agent architect fable "" "")"
expect_deny "m2 invalid settings.local.json: Agent architect fable is denied naming settings.local.json" '.claude/settings.local.json is not valid JSON'

new_case
printf '%s\n' '{"multiAgent": ' > "$PROJ/.claude/settings.json"
run_hook "$(mk_agent implementer haiku "" "")"
expect_allow "m3 invalid settings.json: Agent implementer haiku is allowed"
run_hook "$(mk_write Write "" "$PROJ/.claude/settings.json")"
expect_allow "m4 invalid settings.json: main-session Write is allowed"
run_hook "$(mk_write Write implementer "src/a.ts")"
expect_allow "m5 invalid settings.json: implementer Write is allowed"

# --- k. The repo's settings.json is never touched.
repo_after="$(sum_of "$repo_settings")"
if [ "$repo_before" = "$repo_after" ]; then
  ok "k1 repo .claude/settings.json is unchanged by the tests"
else
  bad "k1 repo .claude/settings.json is unchanged by the tests" "checksum changed: before=$repo_before after=$repo_after"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
