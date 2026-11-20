# Page Title Alert (extra fence)

## Purpose

Deliberately broken: the Copyable URL section holds a second fenced block with a different URL.

## Requirements

- Used only as a checker fixture.

## Copyable URL

```text
javascript:(()=>{const t=document.title;alert(t)})()
```

```
javascript:(()=>{alert("other")})()
```

## Readable code

```js
// Show the current page title in an alert box.
(() => {
  const t = document.title;
  alert(t);
})();
```
