#!/usr/bin/env bash
# PreToolUse hook: blocks git write subcommands from subagents, allows read-only git and all main-session calls.
# Registered in .claude/settings.json (fires for every Bash call) and in each agent's frontmatter; the agent_id/agent_type gate keeps the orchestrator unaffected.
# Guardrail against accidents, not a security boundary: indirect invocations (e.g. `$g commit`, `xargs git commit`) are not caught.
# Reads the hook JSON on stdin. Exit 2 blocks the tool call; exit 0 allows it.
set -u

input="$(cat)"

block() {
  echo "Blocked: subagents may not run git write commands ($1). Report your changes to the orchestrator instead." >&2
  exit 2
}

# Subagent gate: a call is from a subagent when it carries agent_id, or agent_type implementer/reviewer.
# Anything else is a main-session call and is allowed.
agent_id=""
agent_type=""
if command -v jq >/dev/null 2>&1; then
  agent_id="$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null)"
  agent_type="$(printf '%s' "$input" | jq -r '.agent_type // empty' 2>/dev/null)"
else
  case "$input" in
    *'"agent_id"'*) agent_id="unknown" ;;
  esac
fi
if [ -z "$agent_id" ] && [ "$agent_type" != "implementer" ] && [ "$agent_type" != "reviewer" ]; then
  exit 0
fi

# Subagent call without jq: fail closed, since the command cannot be parsed.
if ! command -v jq >/dev/null 2>&1; then
  block "jq not installed; hook cannot parse the command"
fi

cmd="$input"
if command -v jq >/dev/null 2>&1; then
  if parsed="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"; then
    cmd="$parsed"
  fi
fi

block() {
  echo "Blocked: subagents may not run git write commands ($1). Report your changes to the orchestrator instead." >&2
  exit 2
}

# Returns 0 when branch/tag args are read-only (listing), 1 when they would create, delete, or modify.
branch_tag_readonly() {
  local has_list=0 a
  for a in "$@"; do
    case "$a" in
      --list|-l) has_list=1 ;;
    esac
  done
  local -a argv=("$@")
  local n=$# i=0
  while [ "$i" -lt "$n" ]; do
    a="${argv[$i]}"
    case "$a" in
      # Filter flags that take a value: the next argument is the value, not a branch/tag name.
      --contains|--no-contains|--merged|--no-merged|--points-at) i=$((i + 2)); continue ;;
    esac
    case "$a" in
      -d|-D|-m|-M|-c|-C|-f|-u|--delete|--move|--copy|--force|--set-upstream|--set-upstream-to|--set-upstream-to=*|--unset-upstream|--edit-description) return 1 ;;
      -*) ;;
      *) [ "$has_list" -eq 1 ] || return 1 ;;
    esac
    i=$((i + 1))
  done
  return 0
}

# Checks one simple command (a segment). Blocks via exit 2 if it runs git write.
# depth > 0 means this is the body of bash -c / sh -c / zsh -c / eval.
check_cmd() {
  local line="$1" depth="$2"
  local -a words
  read -ra words <<< "$line"
  local n=${#words[@]} i=0 w

  # Skip leading VAR=value, wrapper commands, and shell keywords.
  while [ "$i" -lt "$n" ]; do
    w="${words[$i]//\"/}"; w="${w//\'/}"
    case "$w" in
      [A-Za-z_]*=*|command|env|exec|time|nohup|sudo|then|do|else|elif|while|until|if|!) i=$((i + 1)) ;;
      -*)
        if [ "$depth" -gt 0 ]; then i=$((i + 1)); else break; fi ;;
      *) break ;;
    esac
  done
  if [ "$i" -ge "$n" ]; then return 0; fi

  local cw="${words[$i]//\"/}"; cw="${cw//\'/}"; cw="${cw##*/}"

  # Interpreters: re-check the remainder of the segment with quotes stripped.
  case "$cw" in
    bash|sh|zsh|eval)
      if [ "$depth" -lt 5 ]; then
        local rest="${words[*]:$((i + 1))}"
        rest="${rest//\"/}"; rest="${rest//\'/}"
        check_cmd "$rest" $((depth + 1))
      fi
      return 0 ;;
  esac

  [ "$cw" = "git" ] || return 0

  # Skip git global options to find the subcommand.
  local j=$((i + 1)) a k
  while [ "$j" -lt "$n" ]; do
    a="${words[$j]//\"/}"; a="${a//\'/}"
    case "$a" in
      -C|-c|--git-dir|--work-tree|--namespace) j=$((j + 2)) ;;
      -*) j=$((j + 1)) ;;
      *) break ;;
    esac
  done
  if [ "$j" -ge "$n" ]; then return 0; fi

  local sub="${words[$j]//\"/}"; sub="${sub//\'/}"

  # Arguments after the subcommand, quotes stripped.
  local -a args=()
  for ((k = j + 1; k < n; k++)); do
    a="${words[$k]//\"/}"; args+=("${a//\'/}")
  done
  local first="${args[0]:-}"
  local joined=" ${args[*]:-} "

  case "$sub" in
    commit|push|add|merge|rebase|reset|cherry-pick|revert|checkout|switch|restore|clean|worktree|update-ref|filter-branch|am|pull|rm|mv|commit-tree|submodule|replace|notes|gc|prune|init|clone|fetch)
      block "$sub" ;;
    remote)
      # Read-only: no args, or -v / --verbose only.
      if [ "${#args[@]}" -eq 0 ]; then return 0; fi
      if [ "${#args[@]}" -eq 1 ] && { [ "$first" = "-v" ] || [ "$first" = "--verbose" ]; }; then return 0; fi
      block remote ;;
    config)
      case "$joined" in
        *" --add "*|*" --unset "*|*" --unset-all "*|*" --replace-all "*|*" --rename-section "*|*" --remove-section "*|*" -e "*|*" --edit "*) block config ;;
      esac
      case "$first" in
        --get|--get-all|--get-regexp|--list|-l) return 0 ;;
      esac
      # Single dotted key (section.key) with no flags is a read.
      if [ "${#args[@]}" -eq 1 ]; then
        case "$first" in
          -*|"") ;;
          *.*) return 0 ;;
        esac
      fi
      block config ;;
    reflog)
      # Only expire and delete write; bare reflog and show (or other options) are read-only.
      case "$first" in
        expire|delete) block reflog ;;
      esac
      return 0 ;;
    branch|tag)
      branch_tag_readonly ${args[@]+"${args[@]}"} || block "$sub"
      return 0 ;;
    stash)
      case "$first" in
        list|show) return 0 ;;
      esac
      block stash ;;
    apply)
      case "$joined" in
        *" --check "*) return 0 ;;
      esac
      block apply ;;
  esac
  return 0
}

# Break the command into simple commands: split on &&, ||, ;, |, &, (, ), {, }, backtick, newlines.
# Quote characters are deliberately not separators.
segments="$(printf '%s' "$cmd" | sed -E \
  -e 's/&&/\n/g' \
  -e 's/\|\|/\n/g' \
  -e 's/[;|&(){}`]/\n/g')"

while IFS= read -r line; do
  check_cmd "$line" 0
done <<< "$segments"

exit 0