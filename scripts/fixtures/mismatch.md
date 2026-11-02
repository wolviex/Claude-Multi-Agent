# Page Title Alert (mismatch)

## Purpose

Deliberately out of sync: the URL alerts, but the readable code prompts.

## Requirements

- Used only as a checker fixture.

## Copyable URL

```text
javascript:(()=>{const t=document.title;alert(t)})()
```

## Readable code

```js
// Show the current page title in a prompt box.
(() => {
  const t = document.title;
  prompt(t);
})();
```
