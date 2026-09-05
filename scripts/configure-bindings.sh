#!/bin/bash
# Configure clipboard shortcuts through Omarchy's clone-aware source id.
# The same bindings open alanfortlink.clipboard while installed and the
# built-in omarchy.clipboard after this plugin is disabled or removed.
set -euo pipefail

HYPR_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
LUA="$HYPR_DIR/bindings.lua"
CONF="$HYPR_DIR/bindings.conf"
STAMP=$(date +%s)
changed=0

if [[ -f $LUA ]]; then
  tmp=$(mktemp)
  trap 'rm -f "${tmp:-}"' EXIT
  python3 - "$LUA" >"$tmp" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
command = "omarchy-shell shell toggle omarchy.clipboard"
for chord in ("SUPER + SHIFT + V", "ALT + SHIFT + V"):
    line = f'o.bind("{chord}", "Clipboard manager", "{command}")'
    pattern = re.compile(r'^\s*o\.bind\("' + re.escape(chord) + r'".*$', re.MULTILINE)
    if pattern.search(text):
        text = pattern.sub(line, text, count=1)
    else:
        text = text.rstrip() + "\n" + line + "\n"
sys.stdout.write(text)
PY
  if ! cmp -s "$LUA" "$tmp"; then
    cp "$LUA" "$LUA.bak.clipboard.$STAMP"
    mv "$tmp" "$LUA"
    changed=1
    echo "Updated $LUA (backup: $LUA.bak.clipboard.$STAMP)"
  else
    echo "$LUA already uses clone-aware clipboard bindings"
  fi
elif [[ -f $CONF ]]; then
  tmp=$(mktemp)
  trap 'rm -f "${tmp:-}"' EXIT
  grep -vE '^bindd = (SUPER|ALT) SHIFT, V, ' "$CONF" >"$tmp" || true
  printf '%s\n' \
    'bindd = SUPER SHIFT, V, Clipboard manager, exec, omarchy-shell shell toggle omarchy.clipboard' \
    'bindd = ALT SHIFT, V, Clipboard manager, exec, omarchy-shell shell toggle omarchy.clipboard' >>"$tmp"
  if ! cmp -s "$CONF" "$tmp"; then
    cp "$CONF" "$CONF.bak.clipboard.$STAMP"
    mv "$tmp" "$CONF"
    changed=1
    echo "Updated $CONF (backup: $CONF.bak.clipboard.$STAMP)"
  else
    echo "$CONF already uses clone-aware clipboard bindings"
  fi
else
  echo "configure-bindings: no bindings.lua or bindings.conf found in $HYPR_DIR" >&2
  exit 1
fi

if (( changed )); then
  hyprctl reload >/dev/null
fi

errors=$(hyprctl configerrors)
if [[ -n $errors ]]; then
  printf '%s\n' "$errors" >&2
  exit 1
fi

echo "Clipboard shortcuts ready: SUPER+SHIFT+V and ALT+SHIFT+V"
