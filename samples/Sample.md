---
title: Sample document
tags: [test, mdview]
date: 2026-10-27
---

# MDView sample

A paragraph with **bold**, *italic*, `inline code`, a [web link](https://example.com), a [[Other Note]] wikilink, a [relative file link](Other%20Note.md), and ==highlighted text==. Task: ~~strike~~.

## Lists

- Item one
- Item two
  - Nested item
- [x] Done task
- [ ] Open task

1. First
2. Second

## Code

```swift
import AppKit
let app = NSApplication.shared   // comment
print("hello \(app)")
```

```python
def fib(n: int) -> int:
    return n if n < 2 else fib(n - 1) + fib(n - 2)
```

## Table

| Name | Role | Notes |
|------|------|-------|
| Argus | Detection kit | open code |
| Aegis | Finance tool | local-first |

## Callouts and quotes

> [!NOTE]
> This is a note callout with `code`.

> [!WARNING] Custom title
> Be careful here.

> A plain blockquote.

## Image

![relative image](img/red.png)

![[red.png|48]]

### Deep heading

Some text under a level-3 heading. Jump to [the top](#mdview-sample).

<details><summary>Raw HTML details</summary>Hidden content. <script>document.title='XSS'</script></details>

---
Horizontal rule above. Press ⌘F to find "callout".
