#!/usr/bin/env bash
# PreToolUse hook: blocks git write subcommands from subagents, allows read-only git and all main-session calls.
# Registered in .claude/settings.json (fires for every Bash call) and in each agent's frontmatter; the agent_id/agent_type gate keeps the orchestrator unaffected.
# Guardrail against accidents, not a security boundary.
# Handled: backslash-newline continuations, a leading backslash on the command word, and the wrappers timeout, nice, env,
# sudo, command, stdbuf, ionice, nohup, time and exec (their own options and option arguments are skipped, best effort).
# Not handled (documented limitations, not bugs): indirect invocations such as `$g commit` or `xargs git commit`.
# Known limitation (not a bug): the command is split into lines and segments and each is scanned alone, so heredoc bodies and multi-line
# quoted strings are scanned line by line too. A line in them starting with a git write (e.g. a commit message or file content beginning
# `git push`) is blocked. Workaround: write such text to a file with the Write tool instead of inline in Bash.
# Tests: scripts/test-block-git-write.sh (npm run test:git-guard).
# Reads the hook JSON on stdin. Exit 2 blocks the tool call; exit 0 allows it.
set -u

input="$(cat)"

block() {
  echo "Blocked: subagents may not run git write commands ($1). Report your changes to the orchestrator instead." >&2
  exit 2
}

# Subagent gate: a call is from a subagent when it carries agent_id, or agent_type implementer/supervisor/architect/reviewer (legacy).
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
if [ -z "$agent_id" ] && [ "$agent_type" != "implementer" ] && [ "$agent_type" != "supervisor" ] && [ "$agent_type" != "architect" ] && [ "$agent_type" != "reviewer" ]; then
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

# Join backslash-newline continuations so `git \<newline>  commit` is seen as one command.
cmd="${cmd//\\$'\n'/}"

# norm WORD: sets N to WORD with quotes removed and one leading backslash removed.
norm() {
  N="$1"
  N="${N//\"/}"; N="${N//\'/}"
  N="${N#\\}"
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

# Sets POS to the number of non-option arguments in args (uses the caller's args array).
count_positional() {
  POS=0
  local a2
  for a2 in ${args[@]+"${args[@]}"}; do
    case "$a2" in
      -*) ;;
      *) POS=$((POS + 1)) ;;
    esac
  done
}

# skip_wrapper NAME: advances i (the caller's index into words) past NAME's own options and option arguments,
# and past timeout's duration. Uses the caller's words, n and i. Best effort.
skip_wrapper() {
  local name="$1" takes="" w
  case "$name" in
    timeout) takes="-s -k --signal --kill-after" ;;
    nice) takes="-n --adjustment" ;;
    env) takes="-u --unset -C --chdir -S --split-string" ;;
    sudo) takes="-u --user -g --group -C --close-from -p --prompt -r --role -t --type -D --chdir" ;;
    stdbuf) takes="-i -o -e --input --output --error" ;;
    ionice) takes="-c --class -n --classdata -p --pid -P --pgid -u --uid" ;;
    time) takes="-f --format -o --output" ;;
    exec) takes="-a" ;;
  esac
  while [ "$i" -lt "$n" ]; do
    norm "${words[$i]}"; w="$N"
    case " $takes " in
      *" $w "*) i=$((i + 2)); continue ;;
    esac
    case "$w" in
      -*) i=$((i + 1)) ;;
      [A-Za-z_]*=*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  if [ "$name" = "timeout" ] && [ "$i" -lt "$n" ]; then
    i=$((i + 1))
  fi
}

# Checks one simple command (a segment). Blocks via exit 2 if it runs git write.
# depth > 0 means this is the body of bash -c / sh -c / zsh -c / eval.
check_cmd() {
  local line="$1" depth="$2"
  local -a words
  read -ra words <<< "$line"
  local n=${#words[@]} i=0 w cw

  # Skip leading VAR=value, shell keywords, and wrapper commands (with their own options).
  while [ "$i" -lt "$n" ]; do
    norm "${words[$i]}"; w="$N"
    case "$w" in
      [A-Za-z_]*=*|then|do|else|elif|while|until|if|!) i=$((i + 1)) ;;
      timeout|nice|env|sudo|command|stdbuf|ionice|nohup|time|exec)
        i=$((i + 1)); skip_wrapper "$w" ;;
      -*)
        if [ "$depth" -gt 0 ]; then i=$((i + 1)); else break; fi ;;
      *) break ;;
    esac
  done
  if [ "$i" -ge "$n" ]; then return 0; fi

  norm "${words[$i]}"; cw="${N##*/}"

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
  local POS=0

  case "$sub" in
    commit|push|add|merge|rebase|reset|cherry-pick|revert|checkout|switch|restore|clean|update-ref|filter-branch|am|pull|rm|mv|commit-tree|replace|gc|prune|init|clone|fetch|stage|update-index|pack-refs)
      block "$sub" ;;
    remote)
      # Read-only: no args, get-url, show, or -v / --verbose only.
      if [ "${#args[@]}" -eq 0 ]; then return 0; fi
      case "$first" in get-url|show) return 0 ;; esac
      if [ "${#args[@]}" -eq 1 ]; then
        case "$first" in -v|--verbose) return 0 ;; esac
      fi
      block remote ;;
    worktree)
      # Read-only: list only.
      if [ "$first" = "list" ]; then return 0; fi
      block worktree ;;
    submodule)
      # Read-only: no args, status, or summary.
      if [ "${#args[@]}" -eq 0 ]; then return 0; fi
      case "$first" in status|summary) return 0 ;; esac
      block submodule ;;
    notes)
      # Read-only: no args, list, or show.
      if [ "${#args[@]}" -eq 0 ]; then return 0; fi
      case "$first" in list|show) return 0 ;; esac
      block notes ;;
    config)
      case "$joined" in
        *" --add "*|*" --unset "*|*" --unset-all "*|*" --replace-all "*|*" --rename-section "*|*" --remove-section "*|*" -e "*|*" --edit "*) block config ;;
      esac
      case "$first" in
        get|list|--get|--get-all|--get-regexp|--list|-l) return 0 ;;
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
        *" --apply "*) block apply ;;
        *" --check "*|*" --stat "*|*" --numstat "*|*" --summary "*) return 0 ;;
      esac
      block apply ;;
    symbolic-ref)
      # Read: one ref name (HEAD). Write: delete, reason, or two or more positional arguments.
      case "$joined" in
        *" -d "*|*" --delete "*|*" -m "*) block symbolic-ref ;;
      esac
      count_positional
      if [ "$POS" -ge 2 ]; then block symbolic-ref; fi
      return 0 ;;
    bisect)
      # Read-only: log, visualize, view, help, or no args. Everything else changes bisect state.
      case "$first" in
        ""|log|visualize|view|help) return 0 ;;
      esac
      block bisect ;;
    sparse-checkout)
      # Read-only: list only.
      case "$first" in
        list) return 0 ;;
      esac
      block sparse-checkout ;;
    hash-object)
      case "$joined" in
        *" -w "*) block hash-object ;;
      esac
      return 0 ;;
    maintenance)
      # Read-only: status or no args. run, start, stop, register, unregister write.
      case "$first" in
        ""|status) return 0 ;;
      esac
      block maintenance ;;
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
