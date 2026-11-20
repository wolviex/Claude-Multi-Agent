# Page Title Alert (closing hashes)

## Purpose ##

Shows the current page title in an alert box. The Purpose heading uses a CommonMark closing sequence.

## Requirements

- Runs on any page.
- Needs no network access.

## Copyable URL

```text
javascript:(()=>{const t=document.title;alert(t)})()
```

## Readable code

```js
// Show the current page title in an alert box.
(() => {
  const t = document.title;
  alert(t);
})();
```

## Notes

- Fenced blocks are allowed in Notes.

```
Any text here is documentation, not code under test.
```
