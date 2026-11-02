#!/usr/bin/env bash
# install.sh - add the Claude multi-agent framework to an existing project.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/wolviex/Claude-Multi-Agent/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/wolviex/Claude-Multi-Agent/main/install.sh | bash -s -- --force
#
# Options:
#   --force           overwrite framework files that differ from upstream
#   --ref <git-ref>   branch, tag, or commit to install from (default: main)
#   --dir <path>      target project (default: git top level, else current directory)
#   -h, --help        show this help
#
# Environment:
#   MULTI_AGENT_REPO  GitHub owner/repo to download from (default: wolviex/Claude-Multi-Agent)
#   MULTI_AGENT_REF   ref to install when --ref is not given (default: main)
#   MULTI_AGENT_SRC   local checkout to copy from instead of downloading (tests, offline installs)
#
# Phase 1 (preflight) fetches everything and validates settings.json without writing
# to the target. Phase 2 installs the files and updates settings.json and CLAUDE.md.
#
# Everything runs from main(), which is called on the last line. A truncated download
# therefore stops during parsing and runs nothing.

usage() {
  cat <<'EOF'
Usage: install.sh [--force] [--ref <git-ref>] [--dir <path>] [-h|--help]

Adds the Claude multi-agent framework (.claude/multi-agent.md, agents, hook,
settings.json hook entry, CLAUDE.md import) to a project.

Options:
  --force           overwrite framework files that differ from upstream
  --ref <git-ref>   branch, tag, or commit to install from (default: main)
  --dir <path>      target project (default: git top level, else current directory)
  -h, --help        show this help

Environment:
  MULTI_AGENT_REPO  owner/repo to download from (default: wolviex/Claude-Multi-Agent)
  MULTI_AGENT_REF   ref when --ref is not given (default: main)
  MULTI_AGENT_SRC   local checkout to copy from instead of downloading

Requires Claude Code 2.1.295 or later (the hook uses "onFailure").
EOF
}

err() {
  printf 'install.sh: error: %s\n' "$*" >&2
}

usage_error() {
  err "$*"
  usage >&2
  exit 2
}

# report <relative-path> <status>
report() {
  printf '  %s: %s\n' "$1" "$2"
}

# fetch_one <relative-path> <destination>
# Uses globals SRC, REPO, REF.
fetch_one() {
  local rel="$1" dest="$2" url
  if [ -n "$SRC" ]; then
    [ -f "$SRC/$rel" ] || return 1
    cp "$SRC/$rel" "$dest" || return 1
  else
    url="https://raw.githubusercontent.com/$REPO/$REF/$rel"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$url" -o "$dest" || return 1
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$dest" "$url" || return 1
    else
      err "neither curl nor wget is installed"
      exit 1
    fi
  fi
  [ -s "$dest" ] || return 1
  return 0
}

# install_file <relative-path>
# Uses globals STAGE, TARGET, FORCE, HOOK_REL.
install_file() {
  local rel="$1" src dst status
  src="$STAGE/$rel"
  dst="$TARGET/$rel"
  mkdir -p "$(dirname "$dst")"

  if [ ! -e "$dst" ]; then
    cp "$src" "$dst"
    status="installed"
  elif cmp -s "$src" "$dst"; then
    status="unchanged"
  elif [ "$FORCE" = 1 ]; then
    cp "$src" "$dst"
    status="updated"
  else
    status="skipped (local changes; re-run with --force to overwrite)"
  fi

  if [ "$rel" = "$HOOK_REL" ] && [ "$status" != "skipped (local changes; re-run with --force to overwrite)" ]; then
    chmod +x "$dst"
  fi

  report "$rel" "$status"
}

main() {
  set -euo pipefail

  local REPO REF SRC TARGET FORCE FILES HOOK_REL IMPORT_LINE ENTRY_JSON
  local HAVE_JQ SETTINGS CLAUDE_MD
  REPO="${MULTI_AGENT_REPO:-wolviex/Claude-Multi-Agent}"
  REF="${MULTI_AGENT_REF:-main}"
  SRC="${MULTI_AGENT_SRC:-}"
  TARGET=""
  FORCE=0

  # Framework files, relative to the repo root and to the target root.
  FILES=".claude/multi-agent.md .claude/agents/implementer.md .claude/agents/reviewer.md .claude/hooks/block-git-write.sh"
  HOOK_REL=".claude/hooks/block-git-write.sh"
  IMPORT_LINE="@.claude/multi-agent.md"

  # Hook entry for settings.json. $CLAUDE_PROJECT_DIR must stay literal; Claude Code expands it.
  # shellcheck disable=SC2016
  ENTRY_JSON='{"matcher":"Bash","hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/block-git-write.sh\"","onFailure":"block"}]}'

  # ---- Arguments -----------------------------------------------------------

  while [ $# -gt 0 ]; do
    case "$1" in
      --force)
        FORCE=1
        shift
        ;;
      --ref)
        [ $# -ge 2 ] || usage_error "--ref needs a value"
        REF="$2"
        shift 2
        ;;
      --ref=*)
        REF="${1#--ref=}"
        shift
        ;;
      --dir)
        [ $# -ge 2 ] || usage_error "--dir needs a value"
        TARGET="$2"
        shift 2
        ;;
      --dir=*)
        TARGET="${1#--dir=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage_error "unknown option: $1"
        ;;
    esac
  done

  [ -n "$REF" ] || usage_error "--ref must not be empty"

  # ---- Target --------------------------------------------------------------

  if [ -z "$TARGET" ]; then
    if top="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$top" ]; then
      TARGET="$top"
    else
      TARGET="$(pwd)"
    fi
  fi

  if [ ! -d "$TARGET" ]; then
    err "target directory does not exist: $TARGET"
    exit 1
  fi
  TARGET="$(cd "$TARGET" && pwd)"

  if [ -n "$SRC" ] && [ ! -d "$SRC" ]; then
    err "MULTI_AGENT_SRC is not a directory: $SRC"
    exit 1
  fi

  HAVE_JQ=0
  if command -v jq >/dev/null 2>&1; then
    HAVE_JQ=1
  fi

  SETTINGS="$TARGET/.claude/settings.json"
  CLAUDE_MD="$TARGET/CLAUDE.md"

  # ---- Phase 1: preflight (no writes to the target) ------------------------

  STAGE="$(mktemp -d)"
  trap 'rm -rf "$STAGE"' EXIT

  echo "Fetching framework files ($( [ -n "$SRC" ] && echo "from $SRC" || echo "from $REPO@$REF" ))..."
  for rel in $FILES; do
    mkdir -p "$(dirname "$STAGE/$rel")"
    if ! fetch_one "$rel" "$STAGE/$rel"; then
      err "could not fetch $rel (repo $REPO, ref $REF); target was not changed"
      exit 1
    fi
  done

  if [ -e "$SETTINGS" ] && [ "$HAVE_JQ" = 1 ]; then
    # Must be a JSON object whose .hooks (if present) is an object and .hooks.PreToolUse (if present) an array.
    if ! jq -e 'type == "object"
      and ((.hooks // {}) | type == "object")
      and (((.hooks // {}).PreToolUse // []) | type == "array")' "$SETTINGS" >/dev/null 2>&1; then
      err "$SETTINGS is not valid settings JSON (or its hooks/PreToolUse have the wrong shape); fix it and re-run. Nothing was changed."
      exit 1
    fi
  fi

  # ---- Phase 2: install ----------------------------------------------------

  echo "Installing into $TARGET"

  echo "Framework files:"
  for rel in $FILES; do
    install_file "$rel"
  done

  # settings.json: register the hook.
  local settings_status="" manual_merge=0 tmp
  if [ ! -e "$SETTINGS" ]; then
    mkdir -p "$(dirname "$SETTINGS")"
    if [ "$HAVE_JQ" = 1 ]; then
      jq -n --argjson entry "$ENTRY_JSON" '{hooks: {PreToolUse: [$entry]}}' > "$SETTINGS"
    else
      cat > "$SETTINGS" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/block-git-write.sh\"",
            "onFailure": "block"
          }
        ]
      }
    ]
  }
}
EOF
    fi
    settings_status="registered (created settings.json)"
  elif [ "$HAVE_JQ" = 0 ]; then
    settings_status="not modified (jq not installed); merge the entry below into .claude/settings.json by hand"
    manual_merge=1
  else
    if jq -e '[.hooks.PreToolUse[]?.hooks[]?.command? | select(type == "string" and contains("block-git-write.sh"))] | length > 0' "$SETTINGS" >/dev/null 2>&1; then
      settings_status="already registered"
    else
      tmp="$SETTINGS.tmp.$$"
      if jq --argjson entry "$ENTRY_JSON" \
        '.hooks = (.hooks // {}) | .hooks.PreToolUse = ((.hooks.PreToolUse // []) + [$entry])' \
        "$SETTINGS" > "$tmp"; then
        if [ -L "$SETTINGS" ]; then
          # Replacing a symlink with mv would break the link; write through it instead.
          cat "$tmp" > "$SETTINGS"
          rm -f "$tmp"
        else
          mv "$tmp" "$SETTINGS"
        fi
        settings_status="registered"
      else
        rm -f "$tmp"
        err "failed to update $SETTINGS; framework files were installed, settings.json was not changed"
        exit 1
      fi
    fi
  fi
  echo "Hook registration:"
  report ".claude/settings.json" "$settings_status"
  if [ "$manual_merge" = 1 ]; then
    printf '\n  Add this entry to the "PreToolUse" array in .claude/settings.json:\n\n%s\n\n' "$ENTRY_JSON"
  fi

  # CLAUDE.md: import the framework. Carriage returns are stripped before matching so CRLF files work.
  local claude_status="" import_count
  if [ ! -e "$CLAUDE_MD" ]; then
    printf '%s\n' \
      '# CLAUDE.md' \
      '' \
      "$IMPORT_LINE" \
      '' \
      '## Required checks' \
      '' \
      '- List the checks the implementer must run and the reviewer must rerun (for example `npm test`).' \
      > "$CLAUDE_MD"
    claude_status="created"
  else
    import_count="$(tr -d '\r' < "$CLAUDE_MD" | grep -cxF "$IMPORT_LINE" || true)"
    if [ "$import_count" -gt 0 ]; then
      claude_status="unchanged"
    else
      if [ -s "$CLAUDE_MD" ] && [ -n "$(tail -c 1 "$CLAUDE_MD")" ]; then
        # Last line has no newline: finish it, then leave one blank line.
        printf '\n\n%s\n' "$IMPORT_LINE" >> "$CLAUDE_MD"
      elif [ -s "$CLAUDE_MD" ]; then
        printf '\n%s\n' "$IMPORT_LINE" >> "$CLAUDE_MD"
      else
        printf '%s\n' "$IMPORT_LINE" >> "$CLAUDE_MD"
      fi
      claude_status="import added"
    fi
  fi
  echo "CLAUDE.md:"
  report "CLAUDE.md" "$claude_status"

  if [ "$HAVE_JQ" = 0 ]; then
    echo
    echo "WARNING: jq is not installed. The hook blocks all subagent Bash calls until jq is"
    echo "         installed (it fails closed, because it cannot parse the command)."
    echo "         Install jq (for example: brew install jq, or apt-get install jq)."
  fi

  echo
  echo "Next steps:"
  echo "  1. Review and commit .claude/ and CLAUDE.md."
  echo "  2. List the project's required checks in CLAUDE.md under \"## Required checks\"."
  echo "  3. Run Claude Code as the orchestrator on Opus (use /model to select it)."
  echo "  4. Claude Code 2.1.295 or later is needed for the hook's \"onFailure\" setting."
  exit 0
}

main "$@"
