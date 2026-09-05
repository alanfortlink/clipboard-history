#!/bin/bash
# Open a history entry from the tank.clipboard store with the right app.
# Usage: open-entry.sh <entry-id>
set -euo pipefail

STATE="$HOME/.local/state/omarchy/clipboard-history-rich.json"
ID="${1:-}"

[[ -n $ID && -r $STATE ]] || exit 0

entry=$(jq -c --arg id "$ID" '[.[] | select(.id == $id)][0]' "$STATE") || exit 0
[[ $entry != "null" && -n $entry ]] || exit 0

open_text() {
  local text=$1 url=""
  url=$(grep -Eom1 'https?://[^[:space:]"<>]+' <<<"$text" || true)
  if [[ -z $url ]]; then
    local www
    www=$(grep -Eom1 'www\.[^[:space:]]+' <<<"$text" || true)
    [[ -n $www ]] && url="https://$www"
  fi
  if [[ -z $url && $text =~ ^[[:space:]]*([[:alnum:]][[:alnum:].-]+\.[[:alpha:]]{2,})(/[^[:space:]]*)?[[:space:]]*$ ]]; then
    url="https://${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  fi
  if [[ -n $url ]]; then
    exec omarchy-launch-browser "$url"
  fi
  local dir file
  dir="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/clipboard-open"
  mkdir -p "$dir"
  file=$(mktemp --tmpdir="$dir" clipboard.XXXXXX.txt)
  printf '%s' "$text" >"$file"
  exec omarchy-launch-editor "$file"
}

case $(jq -r '.type' <<<"$entry") in
  image)
    path=$(jq -r '.path' <<<"$entry")
    [[ -r $path ]] || exit 0
    if command -v tensaku-edit >/dev/null 2>&1; then
      exec tensaku-edit "$path"
    fi
    exec xdg-open "$path"
    ;;
  files)
    first=$(jq -r '.paths[0]' <<<"$entry")
    [[ -n $first ]] || exit 0
    exec xdg-open "$first"
    ;;
  text)
    open_text "$(jq -j '.text' <<<"$entry")"
    ;;
esac
