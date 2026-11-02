# AGENTS.md

This repository holds browser bookmarklets. Each bookmarklet is documented in one Markdown file that contains a copyable URL and the readable code it was generated from. These rules apply to every agent and human who creates or edits these files.

## Location and naming

- One file per bookmarklet: `bookmarklets/<kebab-case-name>.md`.
- File names use lowercase letters, digits, and hyphens only.

## Document format

Every bookmarklet document has these sections, in this exact order, with these exact headings:

1. `# <Bookmarklet title>`: the title line.
2. `## Purpose`: prose describing what the bookmarklet does and when to use it.
3. `## Requirements`: a bullet list of conditions it needs (site or page, browser, permissions).
4. `## Copyable URL`: exactly one fenced code block with info string `text`, containing exactly one line.
5. `## Readable code`: exactly one fenced code block with info string `js`.
6. `## Notes`: optional; limitations and known issues.

## Copyable URL rules

- The URL is a single line and starts with `javascript:`.
- The code after the prefix may be percent-encoded. The checker decodes it with `decodeURIComponent` before checking.
- The decoded code must be one IIFE: the whole program is a single expression statement that calls a function expression or arrow function, such as `(()=>{...})()` or `(function(){...})()`. An optional leading `void` is allowed.

## Readable code rules

- The code is the same IIFE, formatted for review: 2-space indent, one statement per line.
- Comments are allowed.

## Code parity rules

- The decoded copyable URL and the readable code must be the same program. Parse both with acorn (`ecmaVersion: "latest"`, script mode). Their ASTs must be identical after ignoring positions, `raw` text, and comments.
- Workflow: edit the readable code first, then regenerate the URL from it. Never change logic in only one of the two.
- The Purpose and Requirements text must keep matching what the code does.

## Checking

- If `node_modules` is missing, run `npm install` once first.
- `node scripts/check-parity.mjs <file>...` verifies the sections, the single-line URL, the `javascript:` prefix, the IIFE wrapper, and AST parity. It exits non-zero on any failure.
- With no arguments, it checks every `bookmarklets/*.md`.

## Example

Here is a minimal, valid document. Its URL decodes to `javascript:(()=>{alert(document.title)})()`, and its readable code is AST-identical to that URL.

````markdown
# Show Page Title

## Purpose

Shows an alert with the current page's title. Use it to check quickly which tab you are on.

## Requirements

- Any web page.
- Any modern desktop browser.

## Copyable URL

```text
javascript:(()=>{alert(document.title)})()
```

## Readable code

```js
(() => {
  alert(document.title);
})();
```

## Notes

- Does nothing on pages that block `alert` dialogs.
````
