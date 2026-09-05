#!/bin/bash
# Install the alanfortlink.clipboard Omarchy shell plugin from this repo.
#
# - symlinks the repo root (the plugin folder) into ~/.config/omarchy/plugins/alanfortlink.clipboard
# - rescans + enables it (shell.json gets plugins[] entry; the built-in
#   omarchy.clipboard is recorded in disabledPlugins[] and routed here)
# - checks and installs dependencies transparently (QR/OCR degrade without them)
# - binds SUPER+SHIFT+V and ALT+SHIFT+V directly to this picker (with backup)
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

echo "==> Binding SUPER+SHIFT+V and ALT+SHIFT+V directly to $PLUGIN_ID"
# Do not route through `shell toggle`: plugin rescans can leave its panel Loader
# stale. The plugin-owned IPC target always controls the mapped picker window.
rebound=0
if [[ -f $HOME/.config/hypr/bindings.lua ]]; then
  LUA="$HOME/.config/hypr/bindings.lua"
  tmp=$(mktemp)
  python3 - "$LUA" >"$tmp" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
command = "omarchy-shell alanfortlink.clipboard toggle"
for chord in ("SUPER + SHIFT + V", "ALT + SHIFT + V"):
    line = f'o.bind("{chord}", "Clipboard manager (clipboard-history)", "{command}")'
    pattern = re.compile(r'^\s*o\.bind\("' + re.escape(chord) + r'".*$', re.M)
    if pattern.search(text):
        text = pattern.sub(line, text, count=1)
    else:
        text = text.rstrip() + "\n" + line + "\n"
sys.stdout.write(text)
PY
  if ! cmp -s "$LUA" "$tmp"; then
    cp "$LUA" "$LUA.bak.$(date +%s)"
    mv "$tmp" "$LUA"
    echo "    updated bindings.lua (backup created)"
  else
    rm -f "$tmp"
    echo "    bindings.lua already correct"
  fi
  rebound=1
elif [[ -f $HOME/.config/hypr/bindings.conf ]]; then
  CONF="$HOME/.config/hypr/bindings.conf"
  cp "$CONF" "$CONF.bak.$(date +%s)"
  sed -i '/^bindd = \(SUPER\|ALT\) SHIFT, V, /d' "$CONF"
  printf '%s\n' \
    'bindd = SUPER SHIFT, V, Clipboard manager (clipboard-history), exec, omarchy-shell alanfortlink.clipboard toggle' \
    'bindd = ALT SHIFT, V, Clipboard manager (clipboard-history), exec, omarchy-shell alanfortlink.clipboard toggle' >>"$CONF"
  echo "    updated bindings.conf (backup created)"
  rebound=1
fi
if (( rebound )); then
  hyprctl reload >/dev/null
else
  echo "ERROR: no live Hyprland bindings file found" >&2
  exit 1
fi

echo
echo "Done. Press SUPER+SHIFT+V (or ALT+SHIFT+V) to open the clipboard picker."
echo "Edit code in $REPO_DIR; run 'omarchy-shell shell rescanPlugins' after changes."
