#!/usr/bin/env python3
"""Clipboard capture for the tank.clipboard Omarchy shell plugin.

Invoked by `wl-paste --watch` (payload on stdin is ignored — we probe
ourselves so a single watcher covers every mime) or with no args to snapshot
the current clipboard. Emits exactly one JSON line per capture:

  {"type":"text","text":...,"ts":...,"bytes":...,"app":...}
  {"type":"image","mime":...,"path":...,"w":...,"h":...,"bytes":...,"ts":...,"app":...}
  {"type":"files","paths":[...],"bytes":...,"ts":...,"app":...}

Sensitive clips (x-kde-passwordManagerHint / CLIPBOARD_STATE=sensitive) and
binary payloads are skipped silently.
"""

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.parse

STATE_DIR = os.path.join(
    os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")), "omarchy"
)
IMAGE_DIR = os.path.join(STATE_DIR, "clipboard-images")

IMAGE_MIMES = ["image/png", "image/jpeg", "image/webp", "image/gif", "image/bmp", "image/tiff"]
IMAGE_EXT = {"image/png": "png", "image/jpeg": "jpg", "image/webp": "webp",
             "image/gif": "gif", "image/bmp": "bmp", "image/tiff": "tiff"}
TEXT_TYPES = ["text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING", "TEXT", "COMPOUND_TEXT"]


def run(args, timeout=5):
    try:
        r = subprocess.run(args, capture_output=True, timeout=timeout)
        return r.stdout if r.returncode == 0 else None
    except Exception:
        return None


def list_types():
    out = run(["wl-paste", "--list-types"])
    if not out:
        return []
    return [line for line in out.decode("utf-8", "replace").splitlines() if line]


def focused_app():
    out = run(["hyprctl", "activewindow", "-j"], timeout=2)
    if not out:
        return ""
    try:
        data = json.loads(out)
        return str(data.get("class") or "")
    except Exception:
        return ""


def emit(entry):
    entry["ts"] = int(time.time())
    print(json.dumps(entry))
    sys.stdout.flush()


def decode_qr(path):
    """Decode a QR code with zbarimg; returns the payload or None."""
    try:
        r = subprocess.run(
            ["zbarimg", "-q", "--raw", "--", path],
            capture_output=True, timeout=10
        )
        # zbarimg exits 4 when no barcode is found.
        if r.returncode != 0:
            return None
        text = r.stdout.decode("utf-8", "replace").rstrip("\n")
        return text or None
    except Exception:
        return None


def capture_image(types, app):
    mime = next((m for m in IMAGE_MIMES if m in types), None)
    if not mime:
        return
    data = run(["wl-paste", "--type", mime, "--no-newline"])
    if not data:
        return
    os.makedirs(IMAGE_DIR, exist_ok=True)
    digest = hashlib.sha256(data).hexdigest()
    path = os.path.join(IMAGE_DIR, f"{digest}.{IMAGE_EXT[mime]}")
    entry = {"type": "image", "mime": mime, "path": path, "bytes": len(data), "app": app}

    # Dimensions via Pillow when available; harmless without it.
    try:
        from PIL import Image  # noqa: PLC0415
        import io  # noqa: PLC0415
        with Image.open(io.BytesIO(data)) as im:
            entry["w"], entry["h"] = im.size
    except Exception:
        pass

    if not os.path.exists(path):
        fd, tmp = tempfile.mkstemp(dir=IMAGE_DIR)
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(data)
            os.replace(tmp, path)
        except Exception:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            return

    qr = decode_qr(path) if os.environ.get("CLIPBOARD_QR", "1") != "0" else None
    if qr:
        entry["qr"] = qr

    emit(entry)
    return True


def decode_text(data):
    """Best-effort text decode; returns None for binary-looking payloads."""
    for enc in ("utf-8", "utf-16"):
        try:
            text = data.decode(enc)
            break
        except (UnicodeDecodeError, UnicodeError):
            continue
    else:
        return None
    # Reject payloads that still look binary after decoding.
    if "\x00" in text:
        return None
    if text:
        nul_control = sum(1 for c in text if ord(c) < 32 and c not in "\n\r\t")
        if nul_control / max(1, len(text)) > 0.05:
            return None
    return text


def capture_uri_list(types, app):
    if "text/uri-list" not in types:
        return False
    data = run(["wl-paste", "--type", "text/uri-list", "--no-newline"])
    if not data:
        return False
    text = decode_text(data)
    if text is None:
        return False
    uris = [u.strip() for u in text.splitlines() if u.strip() and not u.startswith("#")]
    if not uris:
        return False
    paths = []
    for uri in uris:
        if uri.startswith("file://"):
            paths.append(urllib.parse.unquote(urllib.parse.urlparse(uri).path))
        else:
            return False  # remote URI → keep it as plain text below
    if not paths:
        return False
    emit({"type": "files", "paths": paths, "bytes": len(data), "app": app})
    return True


def capture_text(types, app):
    mime = next((m for m in TEXT_TYPES if m in types), None)
    if not mime:
        return
    data = run(["wl-paste", "--type", mime, "--no-newline"])
    if not data:
        return
    text = decode_text(data)
    if text is None or not text.strip():
        return
    emit({"type": "text", "text": text, "bytes": len(data), "app": app})


def main():
    # The watcher pipes the clipboard payload to us; wl-clipboard blocks on
    # writes if we close the pipe early, so drain it instead (we still probe
    # types ourselves below).
    try:
        sys.stdin.buffer.read()
    except Exception:
        pass
    types = list_types()
    if not types:
        return
    if "x-kde-passwordManagerHint" in types:
        return
    if os.environ.get("CLIPBOARD_STATE", "") == "sensitive":
        return

    app = focused_app()
    if capture_image(types, app):
        return
    if capture_uri_list(types, app):
        return
    capture_text(types, app)


if __name__ == "__main__":
    main()
