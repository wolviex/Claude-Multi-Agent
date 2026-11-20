# CLAUDE.md

@AGENTS.md
@.claude/multi-agent.md

AGENTS.md, imported above, defines the bookmarklet document format and the code-parity rules. `.claude/multi-agent.md` defines the multi-agent workflow: roles, the review gate, and git rules. It is the same file the installer copies into other projects, so keep repo-specific rules here instead.

## Required checks

- For every changed bookmarklet `.md`, run `node scripts/check-parity.mjs <file>`. It checks AST parity, that the URL is a single line, the `javascript:` prefix, and the IIFE wrapper. If `node_modules` is missing, run `npm install` once first.
- For every changed `.js` or `.mjs` file, run `node --check <file>`.
- For a changed `install.sh` or `scripts/test-install.sh`, run `npm run test:install`.
- For a changed `.claude/hooks/agent-gate.sh` or `scripts/test-agent-gate.sh`, run `npm run test:agent-gate`.
- For a changed `.claude/hooks/block-git-write.sh` or `scripts/test-block-git-write.sh`, run `npm run test:git-guard`.
- For every changed `.sh` file, run `bash -n <file>`, and `shellcheck <file>` if shellcheck is installed (report SKIPPED if it is not).
- For a changed `scripts/check-parity.mjs` or any file in `scripts/fixtures/`, run `npm test`.
- CI (`.github/workflows/ci.yml`) runs all suites on push and pull requests.
