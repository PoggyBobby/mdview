# MDView

A small, fully local Markdown viewer for macOS. One Swift file plus a WebKit
page. No network access, no telemetry, no accounts. Register it once and every
`.md` file on your Mac opens in it with a double-click.

## Install

Requires macOS 13 or newer and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/PoggyBobby/mdview.git
cd mdview
./build.sh --default
```

`--default` builds the app, copies it to `/Applications`, and makes it the
default app for Markdown. Use `--install` to install without changing the
default, or run with no flags to only build `build/MDView.app`.

To hand `.md` files back to another app later, use Finder: select a Markdown
file, Get Info, Open With, Change All.

## What it renders

- GitHub-flavored Markdown via marked (tables, task lists, strikethrough, autolinks)
- Syntax-highlighted code blocks via highlight.js, with a hover **Copy** button
- YAML front matter, shown as a collapsed **Properties** block
- Obsidian extras: `[[wikilinks]]`, `![[image.png|300]]` embeds, `==highlight==`, callouts (`> [!NOTE]`)
- GitHub-style alerts, which use the same callout syntax
- Relative images and links, resolved from the file's folder
- Raw HTML passes through, but scripts, iframes, and event handlers are stripped

## Keyboard

| Shortcut | Action |
|---|---|
| ⌘O | Open a file |
| ⌘F / ⌘G / ⇧⌘G | Find / next / previous |
| ⇧⌘O | Toggle outline sidebar |
| ⌘+ / ⌘- / ⌘0 | Zoom (⌘= also zooms in) |
| ⌘R | Re-render (also happens automatically when the file changes) |
| ⌘E | Edit in your editor (double-clicking empty space does the same) |
| ⌥⌘R | Reveal in Finder |
| ⌥⌘C | Copy the file's path |
| ⇧⌘E | Export as PDF |
| ⌘P | Print |

## Behavior

- Links to other `.md` files and wikilinks open in a new MDView window.
  Wikilinks search the file's folder first, then the enclosing Obsidian vault.
- Web links open in your browser. Other local files open in their default
  app, except programs, scripts, bundles, disk images and installer packages,
  which are revealed in Finder instead of launched.
- Scroll position is remembered per file. The app quits when its last window closes.
- Light and dark follow the system; force one from the View menu.

## Settings

Set with `defaults write one.sellab.mdview <key> <value>`:

| Key | Values | Meaning |
|---|---|---|
| `EditorApp` | app name, bundle id, or path | App used by ⌘E. Default: VS Code, Cursor, Zed, Sublime Text, BBEdit, Nova, or TextEdit, whichever is installed first |
| `appearance` | `system`, `light`, `dark` | Same as the View menu |

## Layout

```
Sources/main.swift      AppKit app: windows, menus, file watching, link routing
Resources/viewer.html   page template and CSS
Resources/app.js        renderer setup, outline, find bar, link handling
Resources/vendor/       marked 18.1.1 (MIT), highlight.js 11.12.0 (BSD-3) and their licenses
icon/make_icon.swift    draws the app icon
samples/                a document that exercises every supported feature
build.sh                compile, bundle, ad-hoc sign, optional install
```

Debug flags: `MDView --snapshot out.png file.md` renders a file and exits
(`out.pdf` writes a full-page PDF instead; `MDVIEW_SNAPSHOT_DELAY` sets the
wait in seconds); `MDView --which` prints the current default app for
Markdown; `MDView --set-default` registers the running copy.

## License

MIT. Bundled libraries keep their own licenses, included in `Resources/vendor/`.
