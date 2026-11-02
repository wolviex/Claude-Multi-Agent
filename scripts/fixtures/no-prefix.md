# Page Title Alert (no prefix)

## Purpose

Deliberately broken: the copyable URL is missing the javascript: prefix.

## Requirements

- Used only as a checker fixture.

## Copyable URL

```text
(()=>{const t=document.title;alert(t)})()
```

## Readable code

```js
// Show the current page title in an alert box.
(() => {
  const t = document.title;
  alert(t);
})();
```
