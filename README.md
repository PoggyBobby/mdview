# mdview

A lightweight Markdown viewer for Mac and Linux. It renders a file the moment
you open it, re-renders when the file changes on disk, and stays out of the way.
Everything runs locally: no network access, no telemetry, no accounts.

On macOS it is a small native app (one Swift target plus a Quick Look extension)
built around a WebKit page. On Linux the same page runs inside a GTK window.
Both share one renderer, so a note looks the same on either system.

## Install

One command on either platform:

```sh
curl -fsSL https://raw.githubusercontent.com/PoggyBobby/mdview/main/install.sh | sh
```

It installs mdview and makes it the default app for Markdown files. Add
`-s -- --no-default` to the end of the command to leave the default alone, or
`-s -- --uninstall` to remove it.

- **macOS 13 or newer.** The installer builds the app with the Xcode Command Line
  Tools (it offers to install them) and places `MDView.app` in `/Applications`,
  with a Quick Look extension so Space in Finder previews `.md` files.
- **Linux.** The installer adds the GTK 3 and WebKitGTK Python bindings through
  apt, dnf, pacman, zypper or apk, then installs under `~/.local` (override with
  `MDVIEW_PREFIX`). It registers a desktop entry for `text/markdown` and a
  `mdview` command in `~/.local/bin`.

From a clone, `./install.sh` does the same. On macOS, `./build.sh` alone just
builds `build/MDView.app`; `--install` and `--default` add the install and the
default-app registration.

## What it renders

- GitHub-flavored Markdown (tables, task lists, strikethrough, autolinks) and footnotes
- Syntax highlighting for 190+ languages, with a hover **Copy** button on code blocks
- Math with KaTeX: `$inline$` and `$$display$$`
- Mermaid diagrams in ```` ```mermaid ```` blocks, loaded only when a document uses one
- YAML front matter: `title` becomes the heading and window title, `tags` become chips, the rest collapses under **Properties**
- Obsidian syntax: `[[wikilinks]]`, `![[image.png|300]]` embeds, `==highlight==`, callouts such as `> [!NOTE]`
- GitHub-style alerts, which use the same callout syntax
- Raw HTML, with scripts, iframes and event handlers stripped

## Working with files

- Wikilinks and embeds are found by name anywhere in the enclosing vault or
  project (the nearest folder containing `.obsidian`, `.git` or `.mdview-root`),
  so an `attachments` folder at the vault root just works.
- The page can only read files inside that root. A link or image pointing
  outside it stays blank.
- Links to other Markdown files open in a new window. Web links open in your
  browser. Other local files open in their default app, except programs,
  scripts, bundles, disk images and installer packages, which are revealed in
  the file manager instead of launched.
- The file is watched for changes and re-rendered in place, keeping your scroll
  position. Scroll position is also remembered per file between sessions.
- Opening the app without a file shows a start page with recent documents and a
  drop target.
- Light and dark follow the system; force one from the menu.

## Keyboard

| macOS | Linux | Action |
|---|---|---|
| ⌘O | Ctrl+O | Open a file |
| ⌘N | Ctrl+N | New window |
| ⌘F / ⌘G / ⇧⌘G | Ctrl+F / Ctrl+G / Ctrl+Shift+G | Find / next / previous |
| ⇧⌘O | Ctrl+Shift+O | Toggle the outline sidebar (it follows your scroll position) |
| ⌘+ / ⌘- / ⌘0 | Ctrl++ / Ctrl+- / Ctrl+0 | Zoom |
| ⌘R | Ctrl+R or F5 | Re-render |
| ⌘E | Ctrl+E | Edit in your editor (double-clicking empty space does the same) |
| ⌥⌘R | Ctrl+Alt+R | Reveal in Finder / show in Files |
| ⇧⌘E | Ctrl+Shift+E | Export as a standalone HTML file (images and math fonts embedded) |
| ⇧⌘P | Ctrl+Shift+P | Export as PDF |
| ⌘P | Ctrl+P | Print |

## Settings

macOS, with `defaults write one.sellab.mdview <key> <value>`:

| Key | Values | Meaning |
|---|---|---|
| `EditorApp` | app name, bundle id, or path | App used by ⌘E. Default: VS Code, Cursor, Zed, Sublime Text, BBEdit, Nova or TextEdit, whichever is installed first |
| `appearance` | `system`, `light`, `dark` | Same as the View menu |

Linux, in `~/.config/mdview/prefs.json`:

| Key | Values | Meaning |
|---|---|---|
| `editor` | a command, e.g. `"code"` | Used by Ctrl+E. Otherwise the default app for `text/plain`, then `$VISUAL` or `$EDITOR` |
| `appearance` | `system`, `light`, `dark` | Same as the menu |

## Command line

```
mdview file.md            open a file (reuses the running app)
mdview --set-default      make mdview the default app for Markdown
mdview --which            print the current default app for Markdown
mdview --snapshot OUT f   render f to OUT (.png, .pdf or .html) and exit; used by the tests
```

## Layout

```
Sources/Shared/Core.swift       mdview:// scheme handler, root rules, page template, HTML export (macOS)
Sources/App/main.swift          windows, menus, file watching, link routing (macOS)
Sources/QuickLook/              Quick Look preview extension (macOS)
linux/mdview.py                 the GTK edition, same page runtime
linux/mdview.desktop            desktop entry template
Resources/viewer.html           page template and CSS
Resources/app.js                renderer setup, footnotes, math, mermaid, outline, find, start page
Resources/vendor/               marked 18.1.1 (MIT), highlight.js 11.12.0 (BSD-3), KaTeX 0.19.1 (MIT), mermaid 12.2.0 (MIT), with licenses
samples/Sample.md               exercises every supported feature
tests/make_large.py             generates big documents for timing
install.sh                      one-command installer for both platforms
build.sh                        macOS build: app, extension, ad-hoc signing, optional install
.github/workflows/build.yml     builds and renders on macOS and Linux for every push
```

A 20,000-line document (600 KB, 400 code blocks) renders in about a quarter of
a second; a 100,000-line one in just over a second. Code blocks above 40,000
characters are shown without highlighting to keep that true.

## License

MIT. Bundled libraries keep their own licenses, included in `Resources/vendor/`.
