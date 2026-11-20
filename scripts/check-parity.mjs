#!/usr/bin/env node
// Checks that each bookmarklet document's Copyable URL matches its Readable code.
//
// Usage:
//   node scripts/check-parity.mjs [file...]     check the given files, or every bookmarklets/*.md
//   node scripts/check-parity.mjs --self-test   run the checker against scripts/fixtures/*.md
//
// Exit codes: 0 = all passed (or nothing to check), 1 = a document failed,
//             2 = usage error or unreadable file.

import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse } from 'acorn';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const BOOKMARKLETS_DIR = join(ROOT, 'bookmarklets');
const FIXTURES_DIR = join(ROOT, 'scripts', 'fixtures');

const REQUIRED_SECTIONS = ['Purpose', 'Requirements', 'Copyable URL', 'Readable code'];
const OPTIONAL_FINAL_SECTION = 'Notes';
const URL_PREFIX = 'javascript:';
const ESCAPE_PATTERN = /%[0-9A-Fa-f]{2}/;
// Keys that describe source position or formatting rather than program meaning.
const IGNORED_AST_KEYS = new Set(['start', 'end', 'loc', 'range', 'raw']);

const USAGE = `Usage: node scripts/check-parity.mjs [file...]
       node scripts/check-parity.mjs --self-test`;

// Finds headings and fenced code blocks. Lines inside a fence are never headings.
function parseDocument(text) {
  const lines = text.split(/\r?\n/);
  const headings = []; // { level, text, line }
  const fences = []; // { info, content, section, line }
  let section = null; // text of the most recent "## " heading
  let open = null; // fence currently being read: { marker, length, info, lines, line, section }

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    if (open) {
      const close = line.match(/^\s{0,3}(`{3,}|~{3,})\s*$/);
      if (close && close[1][0] === open.marker && close[1].length >= open.length) {
        fences.push({ info: open.info, content: open.lines.join('\n'), section: open.section, line: open.line });
        open = null;
      } else {
        open.lines.push(line);
      }
      continue;
    }

    const fenceStart = line.match(/^\s{0,3}(`{3,}|~{3,})\s*(.*?)\s*$/);
    if (fenceStart) {
      open = {
        marker: fenceStart[1][0],
        length: fenceStart[1].length,
        info: fenceStart[2],
        lines: [],
        line: i + 1,
        section,
      };
      continue;
    }

    const heading = line.match(/^(#{1,6})\s+(.+?)\s*$/);
    if (heading) {
      const level = heading[1].length;
      // CommonMark closing sequence: #s preceded by a space or tab, e.g. "## Purpose ##".
      const text = heading[2].replace(/(^|[ \t]+)#+[ \t]*$/, '');
      headings.push({ level, text, line: i + 1 });
      if (level === 1) section = null;
      if (level === 2) section = text;
    }
  }

  return { headings, fences, unclosedFenceLine: open ? open.line : null };
}

function checkHeadings(headings, reasons) {
  if (headings.length === 0 || headings[0].level !== 1) {
    reasons.push('Headings: the first heading must be an h1 "# <title>"');
  }
  const h1Count = headings.filter((h) => h.level === 1).length;
  if (h1Count !== 1) {
    reasons.push(`Headings: expected exactly one h1 "# <title>", found ${h1Count}`);
  }

  const sections = headings.filter((h) => h.level === 2).map((h) => h.text);
  const missing = REQUIRED_SECTIONS.filter((name) => !sections.includes(name));
  for (const name of missing) {
    reasons.push(`Headings: missing section "## ${name}"`);
  }

  const orderWithNotes = [...REQUIRED_SECTIONS, OPTIONAL_FINAL_SECTION];
  const sameAsRequired = sections.join('|') === REQUIRED_SECTIONS.join('|');
  const sameWithNotes = sections.join('|') === orderWithNotes.join('|');
  if (missing.length === 0 && !sameAsRequired && !sameWithNotes) {
    reasons.push(
      `Headings: sections are out of order or unexpected; found [${sections.join(', ')}], ` +
        `expected ${REQUIRED_SECTIONS.join(', ')} with optional "${OPTIONAL_FINAL_SECTION}" last`,
    );
  }
}

// Returns the JavaScript source carried by the URL, or null if the block is unusable.
function extractUrlSource(content, reasons) {
  const lines = content
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l.length > 0);

  if (lines.length !== 1) {
    reasons.push(`Copyable URL: block must be a single line, found ${lines.length} non-empty lines`);
    return null;
  }

  const [line] = lines;
  if (!line.startsWith(URL_PREFIX)) {
    reasons.push(`Copyable URL: line must start with '${URL_PREFIX}'`);
    return null;
  }

  let source = line.slice(URL_PREFIX.length);
  if (ESCAPE_PATTERN.test(source)) {
    try {
      source = decodeURIComponent(source);
    } catch (err) {
      reasons.push(`Copyable URL: decodeURIComponent failed: ${err.message}`);
      return null;
    }
  }
  return source;
}

function parseSource(source, label, reasons) {
  try {
    return parse(source, { ecmaVersion: 'latest', sourceType: 'script' });
  } catch (err) {
    reasons.push(`${label}: parse error: ${err.message}`);
    return null;
  }
}

// The program must be one call of a function expression or arrow function,
// optionally prefixed with `void`, e.g. (() => { ... })() or void function () { ... }().
function checkIife(ast, label, reasons) {
  if (ast.body.length !== 1) {
    reasons.push(`${label}: program must contain exactly one statement, found ${ast.body.length}`);
    return;
  }
  const statement = ast.body[0];
  if (statement.type !== 'ExpressionStatement') {
    reasons.push(`${label}: not an IIFE: the statement is ${statement.type}, not an expression`);
    return;
  }
  let expression = statement.expression;
  if (expression.type === 'UnaryExpression' && expression.operator === 'void') {
    expression = expression.argument;
  }
  if (expression.type !== 'CallExpression') {
    reasons.push(`${label}: not an IIFE: the top-level expression is ${expression.type}, not a call`);
    return;
  }
  const callee = expression.callee.type;
  if (callee !== 'FunctionExpression' && callee !== 'ArrowFunctionExpression') {
    reasons.push(`${label}: not an IIFE: the callee is ${callee}, expected a function or arrow function`);
  }
}

const isObject = (v) => v !== null && typeof v === 'object';

function describe(value) {
  if (isObject(value)) return Array.isArray(value) ? 'array' : (value.type ?? 'object');
  return typeof value === 'string' ? JSON.stringify(value) : String(value);
}

// `raw` is program meaning only for a template literal that is the quasi of a tagged template,
// where the tag can read it (String.raw). Everywhere else it is formatting and is ignored.
// Returns whether the child at `key` of `node` is such a template's raw-carrying part.
function rawMeaningfulChild(node, key, inherited) {
  if (node.type === 'TaggedTemplateExpression') return key === 'quasi';
  if (node.type === 'TemplateLiteral') return key === 'quasis' && inherited;
  if (node.type === 'TemplateElement') return key === 'value' && inherited;
  return false;
}

// Deep-compares two ASTs and returns the first differing path, or null if equal.
// `rawMeaningful` is true inside a tagged template's quasi, where value.raw is compared.
function findDifference(a, b, path, rawMeaningful = false) {
  if (a === b) return null;
  const mismatch = (detail) => ({ path, detail });

  if (a instanceof RegExp || b instanceof RegExp) {
    return String(a) === String(b) ? null : mismatch(`${String(a)} vs ${String(b)}`);
  }
  if (!isObject(a) || !isObject(b) || Array.isArray(a) !== Array.isArray(b)) {
    return mismatch(`${describe(a)} vs ${describe(b)}`);
  }

  if (Array.isArray(a)) {
    const length = Math.max(a.length, b.length);
    for (let i = 0; i < length; i++) {
      const childPath = `${path}[${i}]`;
      if (i >= a.length || i >= b.length) {
        return { path: childPath, detail: 'present on only one side' };
      }
      const diff = findDifference(a[i], b[i], childPath, rawMeaningful);
      if (diff) return diff;
    }
    return null;
  }

  const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
  const compared = [...keys].filter((k) => !IGNORED_AST_KEYS.has(k) || (k === 'raw' && rawMeaningful));
  for (const key of compared.sort()) {
    const childPath = path ? `${path}.${key}` : key;
    if (!(key in a) || !(key in b)) {
      return { path: childPath, detail: 'present on only one side' };
    }
    const childRaw = rawMeaningfulChild(a, key, rawMeaningful);
    const diff = findDifference(a[key], b[key], childPath, childRaw);
    if (diff) return diff;
  }
  return null;
}

// A section must contain exactly one fenced block of any kind, and it must use the given info string.
// Returns that fence, or null after recording a reason.
function checkSingleFence(fences, info, sectionName, reasons) {
  if (fences.length !== 1) {
    reasons.push(`${sectionName}: expected exactly one fenced block (\`\`\`${info}), found ${fences.length}`);
    return null;
  }
  const [fence] = fences;
  if (fence.info !== info) {
    const found = fence.info ? `\`\`\`${fence.info}` : 'no info string';
    reasons.push(`${sectionName}: fenced block must use info string \`\`\`${info}, found ${found}`);
    return null;
  }
  return fence;
}

// Returns an array of failure reasons for one document. An empty array means PASS.
function checkDocument(text) {
  const reasons = [];
  const doc = parseDocument(text);

  if (doc.unclosedFenceLine !== null) {
    reasons.push(`Fences: code fence opened at line ${doc.unclosedFenceLine} is never closed`);
  }
  checkHeadings(doc.headings, reasons);

  const urlBlock = checkSingleFence(
    doc.fences.filter((f) => f.section === 'Copyable URL'),
    'text',
    'Copyable URL',
    reasons,
  );
  const codeBlock = checkSingleFence(
    doc.fences.filter((f) => f.section === 'Readable code'),
    'js',
    'Readable code',
    reasons,
  );
  if (!urlBlock || !codeBlock) return reasons;

  const urlSource = extractUrlSource(urlBlock.content, reasons);
  const urlAst = urlSource === null ? null : parseSource(urlSource, 'Copyable URL', reasons);
  const codeAst = parseSource(codeBlock.content, 'Readable code', reasons);

  if (urlAst) checkIife(urlAst, 'Copyable URL', reasons);
  if (codeAst) checkIife(codeAst, 'Readable code', reasons);

  if (urlAst && codeAst) {
    const diff = findDifference(urlAst, codeAst, '');
    if (diff) {
      const where = diff.path || '(root)';
      reasons.push(`AST mismatch at ${where}: ${diff.detail} (Copyable URL vs Readable code)`);
    }
  }
  return reasons;
}

// Lists bookmarklets/*.md as display names and absolute paths. Missing directory means none.
function defaultTargets() {
  let names;
  try {
    names = readdirSync(BOOKMARKLETS_DIR);
  } catch (err) {
    if (err.code === 'ENOENT') return [];
    throw err;
  }
  return names
    .filter((n) => n.endsWith('.md'))
    .sort()
    .map((n) => ({ display: `bookmarklets/${n}`, path: join(BOOKMARKLETS_DIR, n) }));
}

function checkFiles(targets) {
  let exitCode = 0; // 0 pass, 1 fail, 2 error (2 takes priority)
  for (const target of targets) {
    let text;
    try {
      text = readFileSync(target.path, 'utf8');
    } catch (err) {
      console.error(`ERROR ${target.display}: ${err.message}`);
      exitCode = 2;
      continue;
    }
    const reasons = checkDocument(text);
    if (reasons.length === 0) {
      console.log(`PASS ${target.display}`);
    } else {
      console.log(`FAIL ${target.display}`);
      for (const reason of reasons) console.log(`  - ${reason}`);
      if (exitCode === 0) exitCode = 1;
    }
  }
  return exitCode;
}

// Each fixture must produce the stated outcome; for FAIL, one reason must match the pattern.
const FIXTURE_EXPECTATIONS = {
  'valid.md': { pass: true },
  'encoded.md': { pass: true },
  'mismatch.md': { pass: false, reason: /AST mismatch/ },
  'multiline.md': { pass: false, reason: /single line/ },
  'no-prefix.md': { pass: false, reason: /must start with 'javascript:'/ },
  'not-iife.md': { pass: false, reason: /not an IIFE/ },
  'tagged-template-mismatch.md': { pass: false, reason: /AST mismatch/ },
  'extra-fence.md': { pass: false, reason: /expected exactly one fenced block.*found 2/ },
  'closing-hashes.md': { pass: true },
};

function runSelfTest() {
  let fixtureNames;
  try {
    fixtureNames = readdirSync(FIXTURES_DIR).filter((n) => n.endsWith('.md'));
  } catch (err) {
    console.error(`ERROR cannot read ${FIXTURES_DIR}: ${err.message}`);
    return 2;
  }

  const names = [...new Set([...Object.keys(FIXTURE_EXPECTATIONS), ...fixtureNames])].sort();
  let allOk = true;

  for (const name of names) {
    const expectation = FIXTURE_EXPECTATIONS[name];
    if (!expectation) {
      console.log(`FAIL  ${name}: no expectation defined for this fixture`);
      allOk = false;
      continue;
    }
    if (!fixtureNames.includes(name)) {
      console.log(`FAIL  ${name}: fixture file is missing`);
      allOk = false;
      continue;
    }

    let reasons;
    try {
      reasons = checkDocument(readFileSync(join(FIXTURES_DIR, name), 'utf8'));
    } catch (err) {
      console.log(`FAIL  ${name}: cannot read fixture: ${err.message}`);
      allOk = false;
      continue;
    }

    const passed = reasons.length === 0;
    const wanted = expectation.pass ? 'PASS' : 'FAIL';
    if (passed !== expectation.pass) {
      console.log(`FAIL  ${name}: expected ${wanted}, got ${passed ? 'PASS' : 'FAIL'}`);
      for (const reason of reasons) console.log(`        - ${reason}`);
      allOk = false;
    } else if (!expectation.pass && !reasons.some((r) => expectation.reason.test(r))) {
      console.log(`FAIL  ${name}: FAIL, but no reason matched ${expectation.reason}`);
      for (const reason of reasons) console.log(`        - ${reason}`);
      allOk = false;
    } else if (expectation.pass) {
      console.log(`OK    ${name}: PASS as expected`);
    } else {
      const matched = reasons.find((r) => expectation.reason.test(r));
      console.log(`OK    ${name}: FAIL as expected (${matched})`);
    }
  }

  return allOk ? 0 : 1;
}

function main(args) {
  if (args.includes('-h') || args.includes('--help')) {
    console.log(USAGE);
    return 0;
  }

  const unknown = args.find((a) => a.startsWith('-') && a !== '--self-test');
  if (unknown !== undefined) {
    console.error(`Unknown option: ${unknown}\n${USAGE}`);
    return 2;
  }

  if (args.includes('--self-test')) {
    if (args.length > 1) {
      console.error(`--self-test takes no other arguments\n${USAGE}`);
      return 2;
    }
    return runSelfTest();
  }

  const targets = args.length
    ? args.map((file) => ({ display: file, path: file }))
    : defaultTargets();

  if (targets.length === 0) {
    console.log('No bookmarklet documents found in bookmarklets/.');
    return 0;
  }
  return checkFiles(targets);
}

try {
  process.exitCode = main(process.argv.slice(2));
} catch (err) {
  console.error(`ERROR: ${err.message}`);
  process.exitCode = 2;
}
