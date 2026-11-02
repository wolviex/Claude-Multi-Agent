# CLAUDE.md

@AGENTS.md
@.claude/multi-agent.md

AGENTS.md, imported above, defines the bookmarklet document format and the code-parity rules. `.claude/multi-agent.md` defines the multi-agent workflow: roles, the review gate, and git rules. It is the same file the installer copies into other projects, so keep repo-specific rules here instead.

## Required checks

- For every changed bookmarklet `.md`, run `node scripts/check-parity.mjs <file>`. It checks AST parity, that the URL is a single line, the `javascript:` prefix, and the IIFE wrapper. If `node_modules` is missing, run `npm install` once first.
- For every changed `.js` or `.mjs` file, run `node --check <file>`.
