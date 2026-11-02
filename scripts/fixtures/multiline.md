# Page Title Alert (multi-line URL)

## Purpose

Deliberately broken: the copyable URL is split across two lines.

## Requirements

- Used only as a checker fixture.

## Copyable URL

```text
javascript:(()=>{const t=document.title;
alert(t)})()
```

## Readable code

```js
// Show the current page title in an alert box.
(() => {
  const t = document.title;
  alert(t);
})();
```
