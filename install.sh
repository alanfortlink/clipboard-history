#!/bin/bash
# Install the alanfortlink.clipboard Omarchy shell plugin from this repo.
#
# - symlinks the repo root (the plugin folder) into ~/.config/omarchy/plugins/alanfortlink.clipboard
# - rescans + enables it (shell.json gets plugins[] entry; the built-in
#   omarchy.clipboard is recorded in disabledPlugins[] and routed here)
# - checks and installs dependencies transparently (QR/OCR degrade without them)
# - rebinds ALT+SHIFT+V from vicinae to this picker (backs up bindings.lua/.conf)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$REPO_DIR"
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
PLUGIN_ID="alanfortlink.clipboard"
BINDINGS="$HOME/.config/hypr/bindings.conf"

echo "==> Checking dependencies"
SKIP_DEPS=false
for a in "$@"; do [[ $a == --skip-deps ]] && SKIP_DEPS=true; done
missing=()
command -v python3   >/dev/null 2>&1 || missing+=("python3")
command -v jq        >/dev/null 2>&1 || missing+=("jq")
command -v wl-copy   >/dev/null 2>&1 || missing+=("wl-clipboard")
command -v wtype     >/dev/null 2>&1 || missing+=("wtype")
command -v zbarimg   >/dev/null 2>&1 || missing+=("zbar")          # QR decode
command -v tesseract >/dev/null 2>&1 || missing+=("tesseract")     # OCR search
if [[ $SKIP_DEPS == true ]]; then
  echo "    skipped (--skip-deps)"
elif (( ${#missing[@]} > 0 )); then
  echo "    installing missing packages (nothing hidden): ${missing[*]}"
  omarchy pkg add "${missing[@]}" || echo "    WARNING: install failed — QR/OCR degrade gracefully without them"
else
  echo "    all present: wl-clipboard, jq, python3, wtype, zbar, tesseract"
fi

echo "==> Linking plugin into $PLUGINS_DIR/$PLUGIN_ID"
mkdir -p "$PLUGINS_DIR"
ln -sTfn "$PLUGIN_DIR" "$PLUGINS_DIR/$PLUGIN_ID"
# On other machines, install directly from git instead:
#   omarchy plugin add <this-repo-git-url> --enable
chmod +x "$PLUGIN_DIR"/capture.py "$PLUGIN_DIR"/paste-entry.sh "$PLUGIN_DIR"/open-entry.sh

echo "==> Rescanning shell plugins"
omarchy-shell shell rescanPlugins >/dev/null
discovered=0
for _ in $(seq 1 40); do
  if omarchy-plugin-list --json | jq -e --arg id "$PLUGIN_ID" 'any(.[]; .id == $id)' >/dev/null 2>&1; then
    discovered=1
    break
  fi
  sleep 0.05
done
if [[ $discovered != 1 ]]; then
  echo "ERROR: plugin was not discovered by the shell" >&2
  exit 1
fi

echo "==> Enabling $PLUGIN_ID (replaces built-in omarchy.clipboard)"
omarchy plugin enable "$PLUGIN_ID"

echo "==> Rebinding ALT+SHIFT+V"
# Omarchy's live config may be bindings.lua (Quattro) or legacy bindings.conf —
# edit whichever exists and let the other alone.
rebound=0
if [[ -f $HOME/.config/hypr/bindings.lua ]]; then
  LUA="$HOME/.config/hypr/bindings.lua"
  if grep -q 'omarchy-shell shell toggle alanfortlink.clipboard' "$LUA"; then
    echo "    bindings.lua already points at alanfortlink.clipboard"
    rebound=1
  elif grep -q 'ALT + SHIFT + V' "$LUA"; then
    cp "$LUA" "$LUA.bak.$(date +%s)"
    sed -i 's|^o.bind("ALT + SHIFT + V", "Clipboard manager (vicinae)", "vicinae deeplink vicinae://launch/clipboard/history")|o.bind("ALT + SHIFT + V", "Clipboard manager (clipboard-history)", "omarchy-shell shell toggle alanfortlink.clipboard")|' "$LUA"
    echo "    rebound in bindings.lua (vicinae binding replaced)"
    rebound=1
  fi
fi
if [[ $rebound != 1 && -f $HOME/.config/hypr/bindings.conf ]] && grep -q "^bindd = ALT SHIFT, V, " "$HOME/.config/hypr/bindings.conf"; then
  CONF="$HOME/.config/hypr/bindings.conf"
  cp "$CONF" "$CONF.bak.$(date +%s)"
  sed -i 's|^bindd = ALT SHIFT, V, .*|bindd = ALT SHIFT, V, Clipboard manager (clipboard-history), exec, omarchy-shell shell toggle alanfortlink.clipboard|' "$CONF"
  echo "    rebound in bindings.conf"
  rebound=1
fi
if (( rebound )); then
  hyprctl reload >/dev/null
else
  echo "    no ALT+SHIFT+V binding found — add manually to ~/.config/hypr/bindings.lua:"
  echo '    o.bind("ALT + SHIFT + V", "Clipboard manager (clipboard-history)", "omarchy-shell shell toggle alanfortlink.clipboard")'
fi

echo
echo "Done. Press ALT+SHIFT+V to open the clipboard picker."
echo "Edit code in $REPO_DIR; run 'omarchy-shell shell rescanPlugins' after changes."
