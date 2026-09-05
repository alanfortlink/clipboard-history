#!/bin/bash
set -euo pipefail

for id in tank.clipboard alanfortlink.clipboard; do
  if [[ -e "$HOME/.config/omarchy/plugins/$id" || -L "$HOME/.config/omarchy/plugins/$id" ]]; then
    omarchy plugin remove "$id" --yes
  fi
done

omarchy plugin add https://github.com/alanfortlink/clipboard-history.git --enable --yes

bash "$HOME/.config/omarchy/plugins/alanfortlink.clipboard/scripts/configure-bindings.sh"

omarchy restart shell
