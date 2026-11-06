#!/bin/bash
# Paste (or just copy) a history entry from the alanfortlink.clipboard store.
# Usage: paste-entry.sh <entry-id> [--copy-only]
set -euo pipefail

STATE="$HOME/.local/state/omarchy/clipboard-history-rich.json"
ID="${1:-}"
MODE="${2:-}"

[[ -n $ID && -r $STATE ]] || exit 0

entry=$(jq -c --arg id "$ID" '[.[] | select(.id == $id)][0]' "$STATE") || exit 0
[[ $entry != "null" && -n $entry ]] || exit 0

type=$(jq -r '.type' <<<"$entry")

case "$type" in
  image)
    path=$(jq -r '.path' <<<"$entry")
    mime=$(jq -r '.mime // "image/png"' <<<"$entry")
    [[ -r $path ]] || exit 0
    wl-copy --type "$mime" <"$path"
    ;;
  files)
    while IFS= read -r p; do
      printf 'file://%s\n' "$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$p")"
    done < <(jq -r '.paths[]' <<<"$entry") | wl-copy --type text/uri-list
    ;;
  *)
    jq -j '.text' <<<"$entry" | wl-copy
    ;;
esac

[[ $MODE == "--copy-only" ]] && exit 0

# Give the layer surface a moment to close and focus to fall back to the
# previously-focused window, then paste into it.
sleep 0.15

# Terminals want Shift+Insert; everything else wants Ctrl+V (Firefox-based
# browsers ignore Shift+Insert). Mirrors Omarchy's universal paste, which keys
# off the "terminal" window tag. Dynamic Hyprland tags end in "*".
# Images always get Ctrl+V: Shift+Insert is text-only in terminals, while
# terminal apps (e.g. pi) read the clipboard themselves on Ctrl+V.
tags=$(hyprctl activewindow -j 2>/dev/null | jq -r '[.tags[]? | sub("\\*$"; "")] | join(" ")' 2>/dev/null) || tags=""

if [[ $type != "image" && " $tags " == *" terminal "* ]]; then
  wtype -M shift -k Insert -m shift 2>/dev/null || true
else
  wtype -M ctrl -k v -m ctrl 2>/dev/null || true
fi
