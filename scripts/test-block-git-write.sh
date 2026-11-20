#!/usr/bin/env bash
# Tests for .claude/hooks/block-git-write.sh. Table-driven: each case pipes a Bash hook payload into the hook
# and expects exit 2 (blocked) or 0 (allowed). Subagent cases carry agent_id and agent_type; the main-session
# case carries neither. Needs jq and bash (bash 3.2 compatible).
# Usage: bash scripts/test-block-git-write.sh   (or: npm run test:git-guard)
set -u

repo="$(cd "$(dirname "$0")/.." && pwd)"
hook="$repo/.claude/hooks/block-git-write.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required to run these tests"
  exit 1
fi
if [ ! -f "$hook" ]; then
  echo "FAIL: hook not found: $hook"
  exit 1
fi

pass=0
fail=0

# run_case MODE EXPECT NAME CMD: MODE is sub (subagent payload) or main (no agent_id, no agent_type).
# EXPECT is block (exit 2) or allow (exit 0).
run_case() {
  local mode="$1" expect="$2" name="$3" cmd="$4" rc want
  if [ "$mode" = main ]; then
    printf '%s' "$cmd" | jq -Rs '{tool_name:"Bash",tool_input:{command:.}}' | bash "$hook" >/dev/null 2>&1
  else
    printf '%s' "$cmd" | jq -Rs '{tool_name:"Bash",agent_id:"a1",agent_type:"implementer",tool_input:{command:.}}' | bash "$hook" >/dev/null 2>&1
  fi
  rc=$?
  if [ "$expect" = block ]; then want=2; else want=0; fi
  if [ "$rc" -eq "$want" ]; then
    pass=$((pass + 1)); echo "PASS: $name"
  else
    fail=$((fail + 1)); echo "FAIL: $name -- expected $expect (exit $want), got exit $rc: $cmd"
  fi
}

# expect_block NAME CMD / expect_allow NAME CMD: subagent payload.
expect_block() { run_case sub block "$1" "$2"; }
expect_allow() { run_case sub allow "$1" "$2"; }

# --- 1. Main session is never blocked.
run_case main allow "main session: git commit -m x is allowed" 'git commit -m x'

# --- 2. Write forms blocked for subagents: continuations, wrappers, literal backslash.
expect_block "backslash-newline continuation: git commit" $'git \\\n  commit -m x'
expect_block "wrapper timeout: timeout 30 git push" 'timeout 30 git push'
expect_block "wrapper timeout with option: timeout -s KILL 30 git push" 'timeout -s KILL 30 git push'
expect_block "wrapper nice: nice -n 5 git commit" 'nice -n 5 git commit -m x'
expect_block "wrapper nice without option: nice git commit" 'nice git commit -m x'
expect_block "wrapper env: env -i git commit" 'env -i git commit -m x'
expect_block "wrapper env with assignment: env FOO=1 git push" 'env FOO=1 git push'
expect_block "wrapper sudo: sudo -u root git push" 'sudo -u root git push'
expect_block "wrapper command: command -p git commit" 'command -p git commit -m x'
expect_block "wrapper stdbuf: stdbuf -o0 git commit" 'stdbuf -o0 git commit -m x'
expect_block "wrapper stdbuf separate arg: stdbuf -o L git push" 'stdbuf -o L git push'
expect_block "wrapper ionice: ionice -c3 git commit" 'ionice -c3 git commit -m x'
expect_block "wrapper ionice separate arg: ionice -c 3 git push" 'ionice -c 3 git push'
expect_block "wrapper nohup: nohup git push" 'nohup git push'
expect_block "wrapper time: time git push" 'time git push'
expect_block "wrapper exec: exec git push" 'exec git push'
expect_block "wrapper with assignment prefix: FOO=1 git commit" 'FOO=1 git commit -m x'
expect_block "literal leading backslash: \\git commit -m x" '\git commit -m x'
expect_block "absolute path to git: /usr/bin/git push" '/usr/bin/git push'

# --- 3. Missed git write subcommands.
expect_block "git stage x" 'git stage x'
expect_block "git symbolic-ref HEAD refs/heads/x" 'git symbolic-ref HEAD refs/heads/x'
expect_block "git symbolic-ref --delete x" 'git symbolic-ref --delete refs/heads/x'
expect_block "git update-index --add f" 'git update-index --add f'
expect_block "git bisect start" 'git bisect start'
expect_block "git sparse-checkout set x" 'git sparse-checkout set x'
expect_block "git hash-object -w f" 'git hash-object -w f'
expect_block "git maintenance run" 'git maintenance run'
expect_block "git pack-refs --all" 'git pack-refs --all'

# --- 4. Existing blocked forms stay blocked.
expect_block "git commit -m x" 'git commit -m x'
expect_block "git -C . push" 'git -C . push'
expect_block "git -c a=b commit" 'git -c a=b commit -m x'
expect_block "bash -c 'git push'" "bash -c 'git push'"
expect_block "echo hi && git add ." 'echo hi && git add .'
expect_block "git branch newb" 'git branch newb'
expect_block "git stash" 'git stash'

# --- 5. Write forms of remote, worktree, submodule, config, apply, notes stay blocked.
expect_block "git remote add x y" 'git remote add x y'
expect_block "git worktree add p" 'git worktree add p'
expect_block "git submodule update" 'git submodule update'
expect_block "git config user.name x" 'git config user.name x'
expect_block "git config set user.name x" 'git config set user.name x'
expect_block "git config unset user.name" 'git config unset user.name'
expect_block "git apply p.diff" 'git apply p.diff'
expect_block "git apply --apply --stat p.diff" 'git apply --apply --stat p.diff'
expect_block "git notes add -m x" 'git notes add -m x'

# --- 6. Read-only forms allowed (false positives before this change).
expect_allow "git remote get-url origin" 'git remote get-url origin'
expect_allow "git remote show origin" 'git remote show origin'
expect_allow "git worktree list" 'git worktree list'
expect_allow "git submodule status" 'git submodule status'
expect_allow "git config get user.name" 'git config get user.name'
expect_allow "git apply --stat p.diff" 'git apply --stat p.diff'
expect_allow "git notes list" 'git notes list'

# --- 7. Other read-only forms allowed.
expect_allow "git status" 'git status'
expect_allow "git log --oneline" 'git log --oneline'
expect_allow "git diff HEAD -- a" 'git diff HEAD -- a'
expect_allow "git branch -vv" 'git branch -vv'
expect_allow "git stash list" 'git stash list'
expect_allow "git remote -v" 'git remote -v'
expect_allow "git config --get user.name" 'git config --get user.name'
expect_allow "git submodule summary" 'git submodule summary'
expect_allow "git notes show HEAD" 'git notes show HEAD'
expect_allow "git symbolic-ref HEAD" 'git symbolic-ref HEAD'
expect_allow "git hash-object f" 'git hash-object f'
expect_allow "git bisect log" 'git bisect log'
expect_allow "git sparse-checkout list" 'git sparse-checkout list'
expect_allow "git maintenance status" 'git maintenance status'
expect_allow "git apply --check p.diff" 'git apply --check p.diff'
expect_allow "wrapper timeout with read-only git: timeout 30 git status" 'timeout 30 git status'
expect_allow "wrapper env with read-only git: env FOO=1 git log --oneline" 'env FOO=1 git log --oneline'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
