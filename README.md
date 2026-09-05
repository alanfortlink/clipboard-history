# clipboard-history

A Raycast/vicinae-style clipboard history manager for Omarchy — implemented as
an Omarchy shell plugin (`tank.clipboard`, a clone of `omarchy.clipboard`) so it
rides on the system theme, fonts, and layer-shell infrastructure.

## Features

- **Rich capture** — a `wl-paste --watch` daemon records every clip with mime
  type, byte size, source app (via `hyprctl`), timestamp, and image dimensions.
  Text, images, and `file://` URI lists (file-manager copies) are supported;
  password-manager clips and binary payloads are skipped.
- **QR codes** — copied QR images are decoded with `zbarimg`; the payload shows
  in the list title, the preview pane (copy-selectable), and a metadata chip,
  and is fuzzy-searchable like any text clip.
- **Fuzzy search over everything** — fzf-style scoring over content, source
  app, and type, plus recency, pin, and usage boosts. Query tokens:
  - `type:image|link|text|files|code|json|color|email|html|number` (prefix match)
  - `app:firefox` — fuzzy match on the source app
  - `is:pinned`, `today`, `yesterday`, `week`, `<2h`, `>30s`, `<3d`
- **Raycast-style UI** — search bar with blinking cursor, type filter chips,
  two-line result rows with type icons / image thumbnails and metadata
  (type · app · age · size), and a right-hand preview pane:
  - images rendered inline (with dimensions + size)
  - colors shown as a swatch with hex/rgb/hsl values
  - links show the domain headline
  - JSON is pretty-printed; code/html shown appropriately
  - file lists with paths; every preview shows metadata chips (app, date,
    words/lines, bytes, pin/paste counts)
- **Fully theme-integrated** — colors, spacing, corner radius, borders, and the
  monospace font all come from the Omarchy shell's `Color`/`Style` singletons;
  it re-themes itself on `omarchy theme set`.

## Keys

| Key | Action |
| --- | --- |
| `Ctrl+N` / `Ctrl+P` (or arrows) | navigate results |
| `Enter` | copy to clipboard and paste into the focused window |
| `Shift+Enter` | copy only |
| `Ctrl+O` | open (link → browser, image → editor, file → xdg-open, text → editor) |
| `Tab` | pin/unpin |
| `Delete` | remove entry · `Shift+Delete` clear all (with confirm) |
| `Esc` | clear filter, then close |

## Install

```bash
./install.sh
```

This symlinks the repo (the plugin root) into
`~/.config/omarchy/plugins/tank.clipboard`, rescans + enables the plugin (the
built-in `omarchy.clipboard` is replaced — revert with
`omarchy plugin disable tank.clipboard`), and rebinds `ALT+SHIFT+V` from
vicinae to this picker (backing up `bindings.conf`).

On other machines, install straight from git — no clone/step needed:

```bash
omarchy plugin add <this-repo-git-url> --enable
```

Note: the local dev symlink trips `omarchy plugin validate` (it refuses
symlinked plugin folders); a git-cloned copy validates clean.

## Layout

The repo root *is* the plugin folder (so `omarchy plugin add <git-url>` works
directly — it validates and clones a repo whose root holds `manifest.json`).

```
├── manifest.json      # plugin manifest (clonedFrom omarchy.clipboard)
├── Clipboard.qml      # picker overlay: search, chips, list, keys, capture watchers
├── PreviewPane.qml    # per-type preview + metadata chips
├── Store.js           # history model: dedup, pins, pruning, ids
├── Fuzzy.js           # query parser, fuzzy matcher, scoring, highlighting
├── Classify.js        # type detection, app names, formatting, color math
├── capture.py         # clipboard watcher → one JSON line per clip (incl. QR decode)
├── paste-entry.sh     # copy + shift-insert paste into the focused window
└── open-entry.sh      # open with the right app

tests/                 # node --test suites for the JS logic
```

History is stored in `~/.local/state/omarchy/clipboard-history-rich.json`
(image blobs content-addressed under `~/.local/state/omarchy/clipboard-images/`).

## Development

- Run logic tests: `tests/run.sh` (49 tests).
- After editing files in the repo, reload with `omarchy-shell shell rescanPlugins`
  (the plugin dir is a symlink, so the shell's inotify does not watch repo edits).
- Data lives in `~/.local/state/omarchy/`; the picker state is independent of
  the built-in clipboard plugin's `clipboard-history.json`.
