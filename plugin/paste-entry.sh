#!/bin/bash
# Paste (or just copy) a history entry from the tank.clipboard store.
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
      printf 'file://%s\n' "$p"
    done < <(jq -r '.paths[]' <<<"$entry") | wl-copy --type text/uri-list
    ;;
  *)
    jq -j '.text' <<<"$entry" | wl-copy
    ;;
esac

[[ $MODE == "--copy-only" ]] && exit 0

# Give the layer surface a moment to close and focus to fall back to the
# previously-focused window, then paste via the universal Shift+Insert.
sleep 0.15
wtype -M shift -k Insert -m shift 2>/dev/null || true
