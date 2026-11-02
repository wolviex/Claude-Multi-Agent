# Page Title Greeting

## Purpose

Greets the visitor with the current page title, using a percent-encoded URL.

## Requirements

- Runs on any page.
- Spaces and quotes in the URL are percent-encoded.

## Copyable URL

```text
javascript:(()=>{const%20t%20=%20document.title;%20alert(%22Title:%20%22%20+%20t)})()
```

## Readable code

```js
// Greet the page by its title.
(() => {
  const t = document.title;
  alert("Title: " + t);
})();
```
