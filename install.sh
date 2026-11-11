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

Adds the Claude multi-agent framework to a project: .claude/multi-agent.md, the
implementer, supervisor and architect agents, the block-git-write and agent-gate
hooks, their settings.json registrations, the multiAgent role defaults, and the
CLAUDE.md import.

Options:
  --force           overwrite framework files that differ from upstream
  --ref <git-ref>   branch, tag, or commit to install from (default: main)
  --dir <path>      target project (default: git top level, else current directory)
  -h, --help        show this help

Environment:
  MULTI_AGENT_REPO  owner/repo to download from (default: wolviex/Claude-Multi-Agent)
  MULTI_AGENT_REF   ref when --ref is not given (default: main)
  MULTI_AGENT_SRC   local checkout to copy from instead of downloading

Requires Claude Code 2.1.295 or later (the block-git-write hook uses "onFailure").
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
# Uses globals STAGE, TARGET, FORCE. Hook scripts (.claude/hooks/*.sh) are made executable.
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

  case "$rel" in
    .claude/hooks/*.sh)
      if [ "$status" != "skipped (local changes; re-run with --force to overwrite)" ]; then
        chmod +x "$dst"
      fi
      ;;
  esac

  report "$rel" "$status"
}

main() {
  set -euo pipefail

  local REPO REF SRC TARGET FORCE FILES IMPORT_LINE
  local ENTRY_JSON GATE_AGENT_JSON GATE_WRITE_JSON MULTI_AGENT_JSON
  local HAVE_JQ SETTINGS CLAUDE_MD
  REPO="${MULTI_AGENT_REPO:-wolviex/Claude-Multi-Agent}"
  REF="${MULTI_AGENT_REF:-main}"
  SRC="${MULTI_AGENT_SRC:-}"
  TARGET=""
  FORCE=0

  # Framework files, relative to the repo root and to the target root.
  FILES=".claude/multi-agent.md .claude/agents/implementer.md .claude/agents/supervisor.md .claude/agents/architect.md .claude/hooks/block-git-write.sh .claude/hooks/agent-gate.sh"
  IMPORT_LINE="@.claude/multi-agent.md"

  # Hook entries for settings.json. $CLAUDE_PROJECT_DIR must stay literal; Claude Code expands it.
  # The block-git-write entry fails closed (onFailure). The agent-gate entries have no
  # onFailure, so a crash in that hook never locks the orchestrator out; its denials are
  # printed as JSON.
  # shellcheck disable=SC2016
  ENTRY_JSON='{"matcher":"Bash","hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/block-git-write.sh\"","onFailure":"block"}]}'
  # shellcheck disable=SC2016
  GATE_AGENT_JSON='{"matcher":"Agent|Task","hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/agent-gate.sh\""}]}'
  # shellcheck disable=SC2016
  GATE_WRITE_JSON='{"matcher":"Write|Edit|NotebookEdit","hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/agent-gate.sh\""}]}'

  # Default top-level multiAgent block, added only when settings.json has no multiAgent key.
  MULTI_AGENT_JSON='{"roles":{"orchestrator":{"model":"opus"},"supervisor":{"agent":"supervisor","model":"sonnet"},"implementer":{"agent":"implementer","model":"haiku"},"architect":{"agent":"architect","model":"fable"}},"architect":{"enabled":true,"requireManualEnable":false,"maxRunsPerBranch":3,"maxRunsPerDay":3,"outputDir":"dev"}}'

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

  # Legacy reviewer agent: superseded by supervisor.md. Reported, never deleted.
  if [ -e "$TARGET/.claude/agents/reviewer.md" ]; then
    report "legacy .claude/agents/reviewer.md" "found (delete it after review)"
    printf '  NOTE: .claude/agents/reviewer.md is the legacy reviewer agent. It is superseded by\n'
    printf '        .claude/agents/supervisor.md. Delete it once you have reviewed it; the installer\n'
    printf '        does not delete it.\n'
  fi

  # settings.json: register the hooks and add the multiAgent defaults.
  local settings_status="" ma_status="" manual_merge=0 tmp added
  local need_block=0 need_agent=0 need_write=0 need_ma=0
  if [ ! -e "$SETTINGS" ]; then
    mkdir -p "$(dirname "$SETTINGS")"
    if [ "$HAVE_JQ" = 1 ]; then
      jq -n --argjson block "$ENTRY_JSON" \
        --argjson agent "$GATE_AGENT_JSON" \
        --argjson write "$GATE_WRITE_JSON" \
        --argjson defaults "$MULTI_AGENT_JSON" \
        '{hooks: {PreToolUse: [$block, $agent, $write]}, multiAgent: $defaults}' > "$SETTINGS"
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
      },
      {
        "matcher": "Agent|Task",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/agent-gate.sh\""
          }
        ]
      },
      {
        "matcher": "Write|Edit|NotebookEdit",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/agent-gate.sh\""
          }
        ]
      }
    ]
  },
  "multiAgent": {
    "roles": {
      "orchestrator": {
        "model": "opus"
      },
      "supervisor": {
        "agent": "supervisor",
        "model": "sonnet"
      },
      "implementer": {
        "agent": "implementer",
        "model": "haiku"
      },
      "architect": {
        "agent": "architect",
        "model": "fable"
      }
    },
    "architect": {
      "enabled": true,
      "requireManualEnable": false,
      "maxRunsPerBranch": 3,
      "maxRunsPerDay": 3,
      "outputDir": "dev"
    }
  }
}
EOF
    fi
    settings_status="registered (created settings.json)"
    ma_status="added defaults"
  elif [ "$HAVE_JQ" = 0 ]; then
    settings_status="not modified (jq not installed); merge the pieces below into .claude/settings.json by hand"
    ma_status="not checked (jq not installed); see below"
    manual_merge=1
  else
    # Each detection is independent: a missing piece is added, a present one is left alone.
    if ! jq -e '[.hooks.PreToolUse[]?.hooks[]?.command? | select(type == "string" and contains("block-git-write.sh"))] | length > 0' "$SETTINGS" >/dev/null 2>&1; then
      need_block=1
    fi
    if ! jq -e '[.hooks.PreToolUse[]? | select(.matcher == "Agent|Task") | .hooks[]?.command? | select(type == "string" and contains("agent-gate.sh"))] | length > 0' "$SETTINGS" >/dev/null 2>&1; then
      need_agent=1
    fi
    if ! jq -e '[.hooks.PreToolUse[]? | select(.matcher == "Write|Edit|NotebookEdit") | .hooks[]?.command? | select(type == "string" and contains("agent-gate.sh"))] | length > 0' "$SETTINGS" >/dev/null 2>&1; then
      need_write=1
    fi
    if ! jq -e 'has("multiAgent")' "$SETTINGS" >/dev/null 2>&1; then
      need_ma=1
    fi

    if [ "$need_block$need_agent$need_write$need_ma" = "0000" ]; then
      settings_status="already registered"
      ma_status="kept (existing configuration)"
    else
      added=""
      [ "$need_block" = 1 ] && added="$added block-git-write (Bash)"
      [ "$need_agent" = 1 ] && added="$added agent-gate (Agent|Task)"
      [ "$need_write" = 1 ] && added="$added agent-gate (Write|Edit|NotebookEdit)"
      [ "$need_ma" = 1 ] && added="$added multiAgent"
      tmp="$SETTINGS.tmp.$$"
      if jq --argjson block "$ENTRY_JSON" \
        --argjson agent "$GATE_AGENT_JSON" \
        --argjson write "$GATE_WRITE_JSON" \
        --argjson defaults "$MULTI_AGENT_JSON" \
        --argjson need_block "$([ "$need_block" = 1 ] && echo true || echo false)" \
        --argjson need_agent "$([ "$need_agent" = 1 ] && echo true || echo false)" \
        --argjson need_write "$([ "$need_write" = 1 ] && echo true || echo false)" \
        --argjson need_ma "$([ "$need_ma" = 1 ] && echo true || echo false)" \
        '.hooks = (.hooks // {})
         | .hooks.PreToolUse = ((.hooks.PreToolUse // []) + [
             (if $need_block then $block else empty end),
             (if $need_agent then $agent else empty end),
             (if $need_write then $write else empty end)])
         | if $need_ma then .multiAgent = $defaults else . end' \
        "$SETTINGS" > "$tmp"; then
        if [ -L "$SETTINGS" ]; then
          # Replacing a symlink with mv would break the link; write through it instead.
          cat "$tmp" > "$SETTINGS"
          rm -f "$tmp"
        else
          mv "$tmp" "$SETTINGS"
        fi
        settings_status="registered (added:$added)"
        if [ "$need_ma" = 1 ]; then
          ma_status="added defaults"
        else
          ma_status="kept (existing configuration)"
        fi
      else
        rm -f "$tmp"
        err "failed to update $SETTINGS; framework files were installed, settings.json was not changed"
        exit 1
      fi
    fi
  fi
  echo "Hook registration and settings:"
  report ".claude/settings.json" "$settings_status"
  report "multiAgent" "$ma_status"
  if [ "$manual_merge" = 1 ]; then
    printf '\n  Merge these into .claude/settings.json by hand. Skip any that are already present.\n\n'
    printf '  Append these entries to the "hooks.PreToolUse" array:\n\n%s\n%s\n%s\n\n' \
      "$ENTRY_JSON" "$GATE_AGENT_JSON" "$GATE_WRITE_JSON"
    printf '  Add this top-level key, unless "multiAgent" already exists (keep yours if it does):\n\n"multiAgent": %s\n\n' \
      "$MULTI_AGENT_JSON"
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
      '- List the checks the implementer must run and the supervisor must rerun (for example `npm test`).' \
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
    echo "WARNING: jq is not installed. The block-git-write hook blocks all subagent Bash calls"
    echo "         until jq is installed (it fails closed, because it cannot parse the command)."
    echo "         Install jq (for example: brew install jq, or apt-get install jq)."
  fi

  echo
  echo "Next steps:"
  echo "  1. Review and commit .claude/ and CLAUDE.md."
  echo "  2. List the project's required checks in CLAUDE.md under \"## Required checks\"."
  echo "  3. Role models are set in .claude/settings.json under \"multiAgent.roles\". Override them"
  echo "     for one person in .claude/settings.local.json."
  echo "  4. Run the main Claude Code session as the orchestrator on the model in"
  echo "     multiAgent.roles.orchestrator (default opus; use /model to select it)."
  echo "  5. The architect is gated by multiAgent.architect. With requireManualEnable set, start"
  echo "     Claude Code with MULTI_AGENT_ENABLE_ARCHITECT=1 in the environment to allow it. In a"
  echo "     cloud session, set MULTI_AGENT_ENABLE_ARCHITECT=1 as an environment variable in the"
  echo "     cloud environment's settings."
  echo "  6. In cloud sessions, the hooks run only in sessions with this single repository (not in"
  echo "     multi-repository sessions or project threads); see the README's Cloud sessions section."
  echo "  7. By default the architect's run log is <outputDir>/.architect-runs.log (dev/.architect-runs.log"
  echo "     with the default outputDir). Commit it with the architect's output so run caps persist"
  echo "     across cloud sessions."
  echo "  8. Claude Code 2.1.295 or later is needed for the block-git-write hook's \"onFailure\" setting."
  exit 0
}

main "$@"
