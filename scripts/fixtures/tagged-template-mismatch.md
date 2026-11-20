# Raw Text Alert (tagged template mismatch)

## Purpose

Deliberately out of sync: both blocks produce the same cooked text, but the tagged template reads different raw text, so the programs differ.

## Requirements

- Used only as a checker fixture.

## Copyable URL

```text
javascript:(()=>{alert(String.raw`A`)})()
```

## Readable code

```js
// The escape \x41 has the same cooked value as A, but String.raw sees different raw text.
(() => {
  alert(String.raw`\x41`);
})();
```
