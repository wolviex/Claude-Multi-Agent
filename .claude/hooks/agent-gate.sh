#!/usr/bin/env bash
# PreToolUse hook: model routing and architect gating for the multi-agent workflow.
#
# Purpose: enforces the multiAgent block of .claude/settings.json, deep-merged with .claude/settings.local.json.
#   - Agent/Task calls: only the orchestrator may start agents. The requested role must be started with the
#     model configured for it (an alias). The architect is gated: enabled flag, optional manual enable,
#     per-branch and per-day run caps (counted from the run log).
#   - Write/Edit/NotebookEdit calls: the architect may only write under architect.outputDir.
# Registration: .claude/settings.json, hooks.PreToolUse, two entries with command
#   bash "$CLAUDE_PROJECT_DIR/.claude/hooks/agent-gate.sh" and no onFailure key, matchers "Agent|Task" and "Write|Edit|NotebookEdit".
# Output: a deny prints one JSON object on stdout (hookSpecificOutput, permissionDecision deny) and exits 0.
#   An allow prints nothing and exits 0.
# Project dir: $CLAUDE_PROJECT_DIR, else the git top level of the hook input's cwd, else the cwd.
# Config: if neither settings file has a multiAgent object, everything is allowed.
#   If either settings file is not valid JSON, or jq is missing, Agent/Task calls that contain "fable" or
#   "architect" are denied (fail closed for the architect only) and everything else is allowed, so the
#   broken file can still be fixed.
# Run log: one line per allowed architect run: <YYYY-MM-DD UTC> TAB <branch or (none)> TAB <tool_use_id>.
#   Default location: <outputDir>/.architect-runs.log (dev/.architect-runs.log with the default outputDir).
#   It is meant to be committed with the architect output, because cloud sessions start from a fresh clone
#   on a fresh VM every time; a log kept under .git would be lost, and maxRunsPerBranch/maxRunsPerDay would reset.
#   multiAgent.architect.runLog selects another location:
#     absent or ""  the default above.
#     "git"         <git common dir>/multi-agent/architect-runs.log (never committed); outside a repo it falls back
#                   to <project>/.claude/.multi-agent-state/architect-runs.log.
#     any other     a repo-relative file path. Absolute paths and paths that resolve outside the project are denied.
#   MULTI_AGENT_STATE_DIR, when set, overrides all of the above: the log is $MULTI_AGENT_STATE_DIR/architect-runs.log.
#   The default log sits inside the architect's writable outputDir, so the architect could edit it with Write;
#   this is part of the guardrail limits below, not a security boundary.
# Env vars:
#   MULTI_AGENT_ENABLE_ARCHITECT  must be 1 when multiAgent.architect.requireManualEnable is true.
#   MULTI_AGENT_STATE_DIR         overrides the run log location (used by the tests).
# Guardrail, not a security boundary: it does not resolve symlinks and does not see writes made through Bash.
set -u

input="$(cat)"

# Emits a deny decision and exits. Only called when jq is available.
deny() {
  jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# Lexical path normalisation: resolves "." and ".." without touching the filesystem.
normalise_path() {
  local p="$1" acc="" seg i
  local IFS='/'
  local -a parts=()
  read -r -a parts <<< "$p"
  for ((i = 0; i < ${#parts[@]}; i++)); do
    seg="${parts[$i]}"
    case "$seg" in
      ""|.) ;;
      ..) acc="${acc%/*}" ;;
      *) acc="$acc/$seg" ;;
    esac
  done
  [ -n "$acc" ] || acc="/"
  printf '%s' "$acc"
}

# Sets out_dir (multiAgent.architect.outputDir) and out_abs (its normalised path under the project).
# Denies, naming outputDir, when it is absolute or resolves outside the project. Needs proj and cfg_get.
resolve_out_dir() {
  out_dir="$(cfg_get '.multiAgent.architect.outputDir // "dev"')"
  case "$out_dir" in
    /*) deny "multiAgent.architect.outputDir must be a path relative to the project; absolute path \"$out_dir\" is not allowed." ;;
  esac
  local proj_base
  proj_base="$(normalise_path "$proj")"
  proj_base="${proj_base%/}"
  out_abs="$(normalise_path "$proj/$out_dir")"
  case "$out_abs" in
    "$proj_base"/*) ;;
    *) deny "multiAgent.architect.outputDir \"$out_dir\" resolves outside the project directory; use a path inside it." ;;
  esac
}

# Without jq the config cannot be read. Fail closed only for architect-related Agent/Task calls.
if ! command -v jq >/dev/null 2>&1; then
  re='"tool_name"[[:space:]]*:[[:space:]]*"(Agent|Task)"'
  if [[ $input =~ $re ]]; then
    case "$input" in
      *'"fable"'*|*'"architect"'*)
        printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"multi-agent gate: jq is not installed, so this Agent call cannot be checked for the architect. Install jq and retry."}}'
        exit 0 ;;
    esac
  fi
  exit 0
fi

in_get() { printf '%s' "$input" | jq -r "$@" 2>/dev/null; }

tool_name="$(in_get '.tool_name // empty')"
case "$tool_name" in
  Agent|Task|Write|Edit|NotebookEdit) ;;
  *) exit 0 ;;
esac

# Project directory.
proj="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$proj" ]; then
  cwd="$(in_get '.cwd // empty')"
  if [ -n "$cwd" ]; then
    proj="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || proj=""
  fi
  [ -n "$proj" ] || proj="${cwd:-$PWD}"
fi
proj="${proj%/}"

# Effective config: settings.json deep-merged with settings.local.json (local wins).
settings_file="$proj/.claude/settings.json"
local_file="$proj/.claude/settings.local.json"
base_json='{}'
local_json='{}'
if [ -s "$settings_file" ]; then base_json="$(cat "$settings_file")"; fi
if [ -s "$local_file" ]; then local_json="$(cat "$local_file")"; fi
cfg="$(printf '%s\n%s\n' "$base_json" "$local_json" | jq -s '.[0] * .[1]' 2>/dev/null)" || cfg=""
if [ -z "$cfg" ]; then
  # Config unreadable: like the no-jq rule, fail closed only for architect-related Agent/Task calls.
  case "$tool_name" in
    Agent|Task)
      case "$input" in
        *'"fable"'*|*'"architect"'*)
          broken=""
          for f in "$settings_file" "$local_file"; do
            if [ -s "$f" ] && ! jq -e . "$f" >/dev/null 2>&1; then
              broken="${broken:+$broken and }.claude/${f##*/}"
            fi
          done
          [ -n "$broken" ] || broken=".claude/settings.json or .claude/settings.local.json"
          deny "multi-agent gate: $broken is not valid JSON, so the architect cannot be checked. Fix it and retry." ;;
      esac ;;
  esac
  exit 0
fi
if ! printf '%s' "$cfg" | jq -e '(.multiAgent | type) == "object"' >/dev/null 2>&1; then
  exit 0
fi

cfg_get() { printf '%s' "$cfg" | jq -r "$@" 2>/dev/null; }

arch_agent="$(cfg_get '.multiAgent.roles.architect.agent // "architect"')"
arch_model="$(cfg_get '.multiAgent.roles.architect.model // empty')"

case "$tool_name" in
  Agent|Task)
    # Rule 1: a subagent may not start agents.
    if [ -n "$(in_get '.agent_id // empty')" ]; then
      deny "Only the orchestrator may start agents (zero pipeline autonomy)."
    fi

    st="$(in_get '.tool_input.subagent_type // empty')"
    [ -n "$st" ] || st="general-purpose"
    model="$(in_get '.tool_input.model // empty')"

    # Rule 2: find the role whose agent is the requested subagent_type.
    role="$(cfg_get --arg st "$st" '(.multiAgent.roles // {}) | to_entries[] | select(.value.agent == $st) | .key' | head -n 1)"

    # Rule 3: no matching role.
    if [ -z "$role" ]; then
      if [ -n "$arch_model" ] && [ "$model" = "$arch_model" ]; then
        deny "The $model model is reserved for the architect role; start it as subagent_type \"$arch_agent\"."
      fi
      exit 0
    fi

    # Rule 4: the role's model must be an alias, and the call must pass it.
    role_model="$(cfg_get --arg r "$role" '.multiAgent.roles[$r].model // empty')"
    case "$role_model" in
      opus|sonnet|haiku|fable) ;;
      *) deny "multiAgent.roles.$role.model must be an alias (opus, sonnet, haiku, or fable); found \"$role_model\"." ;;
    esac
    if [ "$model" != "$role_model" ]; then
      deny "Pass model: \"$role_model\" when starting $st (multiAgent.roles.$role.model)."
    fi

    # Rule 5: architect gates.
    if [ "$role" = "architect" ]; then
      if [ "$(cfg_get '.multiAgent.architect.enabled')" = "false" ]; then
        deny "architect is disabled in multiAgent.architect.enabled."
      fi
      if [ "$(cfg_get '.multiAgent.architect.requireManualEnable')" = "true" ] && [ "${MULTI_AGENT_ENABLE_ARCHITECT:-}" != "1" ]; then
        deny "architect needs the manual switch (multiAgent.architect.requireManualEnable). Start Claude Code with it, for example: MULTI_AGENT_ENABLE_ARCHITECT=1 claude"
      fi

      max_branch="$(cfg_get '.multiAgent.architect.maxRunsPerBranch // 0')"
      max_day="$(cfg_get '.multiAgent.architect.maxRunsPerDay // 0')"
      case "$max_branch" in ''|*[!0-9]*) deny "multiAgent.architect.maxRunsPerBranch must be a non-negative integer." ;; esac
      case "$max_day" in ''|*[!0-9]*) deny "multiAgent.architect.maxRunsPerDay must be a non-negative integer." ;; esac

      log_file=""
      if [ -n "${MULTI_AGENT_STATE_DIR:-}" ]; then
        log_file="$MULTI_AGENT_STATE_DIR/architect-runs.log"
      else
        run_log_type="$(cfg_get '.multiAgent.architect.runLog | type')"
        case "$run_log_type" in
          null|string) ;;
          *) deny "multiAgent.architect.runLog must be a string (a path, \"git\", or absent); found a JSON $run_log_type." ;;
        esac
        # Trim surrounding whitespace; a blank value means the default.
        run_log="$(cfg_get '(.multiAgent.architect.runLog // "") | gsub("^\\s+|\\s+$"; "")')"
        if [ "$run_log" = "git" ]; then
          common="$(git -C "$proj" rev-parse --git-common-dir 2>/dev/null)" || common=""
          if [ -n "$common" ]; then
            case "$common" in /*) ;; *) common="$proj/$common" ;; esac
            log_file="$common/multi-agent/architect-runs.log"
          else
            log_file="$proj/.claude/.multi-agent-state/architect-runs.log"
          fi
        else
          if [ -z "$run_log" ]; then
            resolve_out_dir
            log_file="$out_abs/.architect-runs.log"
          else
            case "$run_log" in
              /*) deny "multiAgent.architect.runLog must be a path relative to the project; absolute path \"$run_log\" is not allowed. Use \"git\" for the git directory." ;;
            esac
            proj_base="$(normalise_path "$proj")"
            proj_base="${proj_base%/}"
            log_file="$(normalise_path "$proj/$run_log")"
            case "$log_file" in
              "$proj_base"/*) ;;
              *) deny "multiAgent.architect.runLog \"$run_log\" resolves outside the project directory; use a path inside it." ;;
            esac
          fi
        fi
      fi
      log_dir="${log_file%/*}"

      branch="$(git -C "$proj" branch --show-current 2>/dev/null)" || branch=""
      [ -n "$branch" ] || branch="(none)"
      today="$(date -u +%Y-%m-%d)"

      n_branch=0
      n_day=0
      if [ -f "$log_file" ]; then
        while IFS=$'\t' read -r log_day log_branch _; do
          if [ "$log_branch" = "$branch" ]; then n_branch=$((n_branch + 1)); fi
          if [ "$log_day" = "$today" ]; then n_day=$((n_day + 1)); fi
        done < "$log_file"
      fi
      if [ "$max_branch" -gt 0 ] && [ "$n_branch" -ge "$max_branch" ]; then
        deny "architect run limit reached for branch $branch ($n_branch/$max_branch)."
      fi
      if [ "$max_day" -gt 0 ] && [ "$n_day" -ge "$max_day" ]; then
        deny "architect run limit reached per day for $today ($n_day/$max_day)."
      fi

      tool_use_id="$(in_get '.tool_use_id // empty')"
      if ! mkdir -p "$log_dir" 2>/dev/null || ! printf '%s\t%s\t%s\n' "$today" "$branch" "$tool_use_id" >> "$log_file" 2>/dev/null; then
        deny "architect run log could not be written to $log_file, so this run was not allowed."
      fi
    fi
    exit 0 ;;

  Write|Edit|NotebookEdit)
    agent_type="$(in_get '.agent_type // empty')"
    if [ -z "$agent_type" ] || [ "$agent_type" != "$arch_agent" ]; then
      exit 0
    fi
    if [ "$tool_name" = "NotebookEdit" ]; then
      path="$(in_get '.tool_input.notebook_path // empty')"
    else
      path="$(in_get '.tool_input.file_path // empty')"
    fi
    case "$path" in
      /*) abs="$path" ;;
      *) abs="$proj/$path" ;;
    esac
    abs="$(normalise_path "$abs")"
    resolve_out_dir
    case "$abs" in
      "$out_abs"/*) exit 0 ;;
      *) deny "The architect may only write under $out_dir/." ;;
    esac ;;
esac

exit 0
