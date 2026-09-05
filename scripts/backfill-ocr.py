#!/usr/bin/env python3
"""Backfill OCR text for image entries already in clipboard history.

Run manually (optional): python3 scripts/backfill-ocr.py [--lang eng]
Images are not re-decoded unless their entry has no `ocr` field; the history
file is updated in place (atomic). Requires tesseract for the chosen lang.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time

STATE = os.path.join(
    os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
    "omarchy", "clipboard-history-rich.json"
)


def ocr(path, lang):
    try:
        r = subprocess.run(
            ["tesseract", path, "stdout", "-l", lang],
            capture_output=True, timeout=30
        )
        if r.returncode != 0:
            return None
        text = "\n".join(l.strip() for l in r.stdout.decode("utf-8", "replace").splitlines() if l.strip())
        return text[:4000] or None
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lang", default="eng")
    ap.add_argument("--force", action="store_true", help="re-OCR even when ocr exists")
    args = ap.parse_args()

    if shutil.which("tesseract") is None:
        sys.exit("tesseract not found — install with: omarchy pkg add tesseract tesseract-data-" + args.lang)

    if not os.path.exists(STATE):
        sys.exit("no history at " + STATE)

    with open(STATE) as f:
        history = json.load(f)

    changed = 0
    for entry in history:
        if entry.get("type") != "image" or not entry.get("path"):
            continue
        if entry.get("ocr") and not args.force:
            continue
        if not os.path.exists(entry["path"]):
            continue
        text = ocr(entry["path"], args.lang)
        if text:
            entry["ocr"] = text
            changed += 1
            print(f"  + {entry['id']}: {text[:60]!r}…")

    if changed:
        tmp = STATE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(history, f, indent=1)
            f.write("\n")
        os.replace(tmp, STATE)
    print(f"OCR'd {changed} image(s); {sum(1 for e in history if e.get('ocr'))} total with OCR text")


if __name__ == "__main__":
    main()
