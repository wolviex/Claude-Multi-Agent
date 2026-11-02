#!/usr/bin/env bash
# Tests install.sh against temporary targets. Prints PASS/FAIL per check and
# exits non-zero if any check fails.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/install.sh"
FILES=".claude/multi-agent.md .claude/agents/implementer.md .claude/agents/reviewer.md .claude/hooks/block-git-write.sh"
HOOK=".claude/hooks/block-git-write.sh"
IMPORT_LINE="@.claude/multi-agent.md"

PASSED=0
FAILED=0

pass() {
  PASSED=$((PASSED + 1))
  printf 'PASS  %s\n' "$1"
}

fail() {
  FAILED=$((FAILED + 1))
  printf 'FAIL  %s\n' "$1"
  if [ -n "${2:-}" ]; then
    printf '      %s\n' "$2"
  fi
}

# check <description> <command...>: passes when the command exits 0.
check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$desc"
  else
    fail "$desc"
  fi
}

# expect_eq <description> <expected> <actual>
expect_eq() {
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1" "expected [$2], got [$3]"
  fi
}

if ! command -v jq >/dev/null 2>&1; then
  fail "jq is required to run these tests; install jq and re-run"
  printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Source for installs: the repo itself when it has the framework files, otherwise a
# temporary copy with a placeholder .claude/multi-agent.md (the repo is never modified).
SRC="$ROOT"
if [ ! -f "$ROOT/.claude/multi-agent.md" ]; then
  SRC="$WORK/source"
  mkdir -p "$SRC"
  cp -R "$ROOT/." "$SRC/"
  rm -rf "$SRC/.git" "$SRC/node_modules"
  printf '%s\n' '<!-- placeholder created by scripts/test-install.sh -->' > "$SRC/.claude/multi-agent.md"
  echo "Note: .claude/multi-agent.md is missing in the repo; using placeholder copy at $SRC"
fi

LAST_OUT="$WORK/last-output.txt"
RC=0

# run_install [args...]: runs install.sh from the test source; sets RC and LAST_OUT.
run_install() {
  MULTI_AGENT_SRC="$SRC" bash "$INSTALL" "$@" >"$LAST_OUT" 2>&1
  RC=$?
}

new_target() {
  mktemp -d "$WORK/target.XXXXXX"
}

HOOK_COUNT_FILTER='[.hooks.PreToolUse[].hooks[].command | select(contains("block-git-write.sh"))] | length'

echo "== (a) fresh empty directory"
T_A="$(new_target)"
run_install --dir "$T_A"
expect_eq "(a) install exits 0" 0 "$RC"
for f in $FILES; do
  check "(a) $f installed and identical to source" cmp -s "$SRC/$f" "$T_A/$f"
done
check "(a) hook is executable" test -x "$T_A/$HOOK"
check "(a) settings.json is valid JSON" jq -e . "$T_A/.claude/settings.json"
check "(a) settings.json has exactly one PreToolUse entry" jq -e '.hooks.PreToolUse | length == 1' "$T_A/.claude/settings.json"
check "(a) PreToolUse entry command references block-git-write.sh" jq -e '.hooks.PreToolUse[0].hooks[0].command | contains("block-git-write.sh")' "$T_A/.claude/settings.json"
check "(a) PreToolUse entry has onFailure block" jq -e '.hooks.PreToolUse[0].hooks[0].onFailure == "block"' "$T_A/.claude/settings.json"
check "(a) CLAUDE.md contains the import line" grep -qxF "$IMPORT_LINE" "$T_A/CLAUDE.md"

echo "== (b) second run on the same directory"
run_install --dir "$T_A"
expect_eq "(b) second run exits 0" 0 "$RC"
expect_eq "(b) exactly one block-git-write hook entry" 1 "$(jq "$HOOK_COUNT_FILTER" "$T_A/.claude/settings.json")"
expect_eq "(b) exactly one import line" 1 "$(grep -cxF "$IMPORT_LINE" "$T_A/CLAUDE.md")"
for f in $FILES; do
  check "(b) $f reported as unchanged" grep -qxF "  $f: unchanged" "$LAST_OUT"
done

echo "== (c) existing CLAUDE.md and settings.json"
T_C="$(new_target)"
mkdir -p "$T_C/.claude"
printf '%s\n' '# My project' '' 'Existing notes that must survive.' > "$T_C/CLAUDE.md"
cat > "$T_C/.claude/settings.json" <<'EOF'
{"permissions":{"allow":["Bash(ls:*)"]},"hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"echo hi"}]}]}}
EOF
run_install --dir "$T_C"
expect_eq "(c) install exits 0" 0 "$RC"
S_C="$T_C/.claude/settings.json"
check "(c) permissions preserved" jq -e '.permissions.allow == ["Bash(ls:*)"]' "$S_C"
check "(c) Edit hook preserved" jq -e '[.hooks.PreToolUse[] | select(.matcher == "Edit" and .hooks[0].command == "echo hi")] | length == 1' "$S_C"
expect_eq "(c) two PreToolUse entries total" 2 "$(jq '.hooks.PreToolUse | length' "$S_C")"
expect_eq "(c) one block-git-write hook entry added" 1 "$(jq "$HOOK_COUNT_FILTER" "$S_C")"
check "(c) original CLAUDE.md text preserved" grep -qxF "Existing notes that must survive." "$T_C/CLAUDE.md"
expect_eq "(c) import line appended exactly once" 1 "$(grep -cxF "$IMPORT_LINE" "$T_C/CLAUDE.md")"

echo "== (d) locally modified implementer.md"
T_D="$(new_target)"
run_install --dir "$T_D"
printf '%s\n' '' '# local edit' >> "$T_D/.claude/agents/implementer.md"
cp "$T_D/.claude/agents/implementer.md" "$WORK/implementer-local.md"
run_install --dir "$T_D"
expect_eq "(d) run without --force exits 0" 0 "$RC"
check "(d) local edit preserved without --force" cmp -s "$WORK/implementer-local.md" "$T_D/.claude/agents/implementer.md"
check "(d) output reports implementer.md skipped" grep -qF "  .claude/agents/implementer.md: skipped (local changes; re-run with --force to overwrite)" "$LAST_OUT"
run_install --dir "$T_D" --force
expect_eq "(d) run with --force exits 0" 0 "$RC"
check "(d) implementer.md overwritten with source with --force" cmp -s "$SRC/.claude/agents/implementer.md" "$T_D/.claude/agents/implementer.md"
check "(d) output reports implementer.md updated" grep -qxF "  .claude/agents/implementer.md: updated" "$LAST_OUT"

echo "== (e) invalid settings.json"
T_E="$(new_target)"
mkdir -p "$T_E/.claude"
printf '%s\n' '{"hooks": {' > "$T_E/.claude/settings.json"
cp "$T_E/.claude/settings.json" "$WORK/settings-invalid.json"
run_install --dir "$T_E"
check "(e) install exits non-zero" test "$RC" -ne 0
check "(e) settings.json unchanged" cmp -s "$WORK/settings-invalid.json" "$T_E/.claude/settings.json"
for f in $FILES; do
  check "(e) $f not written" test ! -e "$T_E/$f"
done
check "(e) CLAUDE.md not created" test ! -e "$T_E/CLAUDE.md"

echo "== (f) hook behaviour on the installed copy"
HOOK_PATH="$T_A/$HOOK"
printf '%s' '{"agent_id":"a1","agent_type":"implementer","tool_input":{"command":"git commit -m x"}}' | bash "$HOOK_PATH" >/dev/null 2>&1
rc=$?
expect_eq "(f) subagent git commit is blocked (exit 2)" 2 "$rc"
printf '%s' '{"tool_input":{"command":"git commit -m x"}}' | bash "$HOOK_PATH" >/dev/null 2>&1
rc=$?
expect_eq "(f) same command without agent fields is allowed (exit 0)" 0 "$rc"

echo "== (g) --help and unknown option"
run_install --help
expect_eq "(g) --help exits 0" 0 "$RC"
check "(g) --help prints usage" grep -qF "Usage: install.sh" "$LAST_OUT"
bash "$INSTALL" --bogus >"$WORK/stdout.txt" 2>"$WORK/stderr.txt"
rc=$?
expect_eq "(g) unknown option exits 2" 2 "$rc"
check "(g) unknown option prints usage on stderr" grep -qF "Usage: install.sh" "$WORK/stderr.txt"

echo "== (h) run from inside a git repository, no --dir"
REPO_H="$WORK/repo-h"
mkdir -p "$REPO_H/sub"
git -C "$REPO_H" init -q
(cd "$REPO_H/sub" && MULTI_AGENT_SRC="$SRC" bash "$INSTALL" >"$LAST_OUT" 2>&1)
RC=$?
expect_eq "(h) run from a subdirectory exits 0" 0 "$RC"
for f in $FILES; do
  check "(h) $f installed at repo top level" test -f "$REPO_H/$f"
done
check "(h) CLAUDE.md created at repo top level" test -f "$REPO_H/CLAUDE.md"
check "(h) nothing installed in the subdirectory" test ! -e "$REPO_H/sub/.claude"

echo "== (i) CRLF CLAUDE.md that already imports the framework"
T_I="$(new_target)"
printf 'Project notes\r\n%s\r\n' "$IMPORT_LINE" > "$T_I/CLAUDE.md"
run_install --dir "$T_I"
expect_eq "(i) first run exits 0" 0 "$RC"
check "(i) CLAUDE.md reported as unchanged on first run" grep -qxF "  CLAUDE.md: unchanged" "$LAST_OUT"
run_install --dir "$T_I"
expect_eq "(i) second run exits 0" 0 "$RC"
check "(i) CLAUDE.md reported as unchanged on second run" grep -qxF "  CLAUDE.md: unchanged" "$LAST_OUT"
expect_eq "(i) import line (CR stripped) appears exactly once" 1 "$(tr -d '\r' < "$T_I/CLAUDE.md" | grep -cxF "$IMPORT_LINE")"

echo "== (j) settings.json is a symlink"
T_J="$(new_target)"
mkdir -p "$T_J/.claude"
printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' > "$WORK/real-settings.json"
ln -s "$WORK/real-settings.json" "$T_J/.claude/settings.json"
run_install --dir "$T_J"
expect_eq "(j) install exits 0" 0 "$RC"
check "(j) settings.json is still a symlink" test -L "$T_J/.claude/settings.json"
check "(j) symlink target contains the block-git-write.sh entry" jq -e '[.hooks.PreToolUse[].hooks[].command | select(contains("block-git-write.sh"))] | length == 1' "$WORK/real-settings.json"
check "(j) symlink target keeps its original permissions key" jq -e '.permissions.allow == ["Bash(ls:*)"]' "$WORK/real-settings.json"

echo "== (k) truncated install.sh runs nothing"
TRUNC="$WORK/install-truncated.sh"
TRUNC_LINES=$(( $(wc -l < "$INSTALL") / 2 ))
head -n "$TRUNC_LINES" "$INSTALL" > "$TRUNC"
T_K="$(new_target)"
MULTI_AGENT_SRC="$SRC" bash "$TRUNC" --dir "$T_K" >"$LAST_OUT" 2>&1
check "(k) target directory is still empty" test -z "$(ls -A "$T_K")"

echo
printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
exit 0
