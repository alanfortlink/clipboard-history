#!/bin/bash
# Regenerate README screenshots (docs/screenshots/*.png).
# Stages demo clipboard entries, opens the picker keyboard-free (IPC), and
# crops the card from a full-screen capture. Run in a graphical session.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO_DIR/docs/screenshots"
mkdir -p "$OUT"

crop_shot() { # <output.png> — open via IPC first; caller decides what's on screen
  local out=$1
  omarchy-shell shell hide alanfortlink.clipboard
  sleep 0.4
  local geo
  case $out in
    "$OUT/search.png")
      omarchy-shell shell call alanfortlink.clipboard debugSetFilter '{"text":"omarchy"}'
      ;;
    *)
      omarchy-shell shell toggle alanfortlink.clipboard
      ;;
  esac
  sleep 1.5
  local geo; geo=$(python3 "$REPO_DIR/scripts/physical-crop.py")
  grim /tmp/clipshot-full.png
  omarchy-shell shell hide alanfortlink.clipboard
  sleep 0.4
  magick /tmp/clipshot-full.png -crop "$geo" +repage "$out"
}

# ---- stage demo content ----------------------------------------------------
qrencode -s 10 -o /tmp/clipshot-qr-repo.png "https://github.com/alanfortlink/clipboard-history"
qrencode -s 10 -o /tmp/clipshot-qr-omarchy.png "https://omarchy.org"
# stage newest-last so the QR pointing at this repo is selected on open
printf 'The quick brown fox jumps over the lazy dog.' | wl-copy; sleep 1.5
printf 'function pasteEntry(id) {\n  const entry = store.findById(id)\n  return paste(entry)\n}' | wl-copy; sleep 1.5
printf '#7aa2f7' | wl-copy; sleep 1.5
printf 'https://omarchy.org/manual/shell-plugins/' | wl-copy; sleep 1.5
wl-copy --type image/png < /tmp/clipshot-qr-omarchy.png; sleep 1.5
wl-copy --type image/png < /tmp/clipshot-qr-repo.png; sleep 1.5

# ---- shots -----------------------------------------------------------------
crop_shot "$OUT/picker.png"
crop_shot "$OUT/search.png"

echo "Wrote $OUT/picker.png and $OUT/search.png"
