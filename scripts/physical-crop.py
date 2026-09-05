#!/usr/bin/env python3
"""Print the PHYSICAL-pixel crop geometry (WxH+X+Y) of the alanfortlink-clipboard
layer surface on grim's combined framebuffer. Monitors report logical .x/.y
with .scale; layers report logical xywh; grim captures physical pixels."""
import json
import re
import subprocess

layers = subprocess.run(["hyprctl", "layers"], capture_output=True, text=True).stdout
m = re.search(r"xywh:\s*(\d+) (\d+) (\d+) (\d+).*namespace: alanfortlink-clipboard", layers)
if not m:
    raise SystemExit(1)
lx, ly, lw, lh = map(int, m.groups())

mons = json.loads(subprocess.run(["hyprctl", "monitors", "-j"], capture_output=True, text=True).stdout)
# Physical framebuffer layout: monitors sorted by (y, x); each occupies its
# physical width/height; offsets accumulate.
mons.sort(key=lambda d: (d["y"], d["x"]))
for i, d in enumerate(mons):
    logical_w = d["width"] / d["scale"]
    if d["x"] <= lx < d["x"] + logical_w and d["y"] <= ly < d["y"] + d["height"] / d["scale"]:
        phys_x = sum(o["width"] for o in mons[:i])
        px = phys_x + round((lx - d["x"]) * d["scale"])
        py = round((ly - d["y"]) * d["scale"])
        pw = round(lw * d["scale"])
        ph = round(lh * d["scale"])
        print(f"{pw}x{ph}+{px}+{py}")
        break
else:
    raise SystemExit(1)
