#!/bin/bash
# Install the tank.clipboard Omarchy shell plugin from this repo.
#
# - symlinks plugin/ into ~/.config/omarchy/plugins/tank.clipboard
# - rescans + enables it (shell.json gets plugins[] entry; the built-in
#   omarchy.clipboard is recorded in disabledPlugins[] and routed here)
# - rebinds ALT+SHIFT+V from vicinae to this picker (backs up bindings.conf)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$REPO_DIR/plugin"
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
PLUGIN_ID="tank.clipboard"
BINDINGS="$HOME/.config/hypr/bindings.conf"

echo "==> Symlinking plugin into $PLUGINS_DIR/$PLUGIN_ID"
mkdir -p "$PLUGINS_DIR"
ln -sTfn "$PLUGIN_DIR" "$PLUGINS_DIR/$PLUGIN_ID"
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
if [[ -f $BINDINGS ]] && grep -q "^bindd = ALT SHIFT, V, " "$BINDINGS"; then
  cp "$BINDINGS" "$BINDINGS.bak.$(date +%s)"
  sed -i 's|^bindd = ALT SHIFT, V, .*|bindd = ALT SHIFT, V, Clipboard manager (clipboard-history), exec, omarchy-shell shell toggle tank.clipboard|' "$BINDINGS"
  hyprctl reload >/dev/null
  echo "    rebound; previous bindings backed up next to $BINDINGS"
else
  echo "    no ALT SHIFT V binding found in $BINDINGS — add manually:"
  echo '    bindd = ALT SHIFT, V, Clipboard manager (clipboard-history), exec, omarchy-shell shell toggle tank.clipboard'
fi

echo
echo "Done. Press ALT+SHIFT+V to open the clipboard picker."
echo "Edit code in $REPO_DIR; run 'omarchy-shell shell rescanPlugins' after changes."
