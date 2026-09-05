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
  # Prune temp copies older than a week; nothing else reclaims them.
  find "$dir" -type f -name 'clipboard.*.txt' -mtime +7 -delete 2>/dev/null || true
  file=$(mktemp --tmpdir="$dir" clipboard.XXXXXX.txt)
  printf '%s' "$text" >"$file"
  exec omarchy-launch-editor "$file"
}

case $(jq -r '.type' <<<"$entry") in
  image)
    path=$(jq -r '.path' <<<"$entry")
    # A decoded QR payload often IS a link — opening it beats opening the image.
    qr=$(jq -r '.qr // empty' <<<"$entry")
    if [[ -n $qr ]]; then
      url=$(printf '%s' "$qr" | grep -Eom1 'https?://[^[:space:]"<>]+' || true)
      if [[ -z $url ]] && [[ $qr =~ ^[[:alnum:]][[:alnum:].-]*\.[[:alpha:]]{2,}(/[^[:space:]]*)?[[:space:]]*$ ]]; then
        url="https://${BASH_REMATCH[0]}"
      fi
      if [[ -n $url ]]; then
        exec omarchy-launch-browser "$url"
      fi
    fi
    [[ -r $path ]] || exit 0
    if command -v tensaku-edit >/dev/null 2>&1; then
      exec tensaku-edit "$path"
    fi
    exec xdg-open "$path"
    ;;
  files)
    first=$(jq -r '.paths[0] // empty' <<<"$entry")
    [[ -n $first ]] || exit 0
    exec xdg-open "$first"
    ;;
  text)
    open_text "$(jq -j '.text' <<<"$entry")"
    ;;
esac
