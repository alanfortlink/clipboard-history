#!/usr/bin/env python3
"""Clipboard capture for the alanfortlink.clipboard Omarchy shell plugin.

Invoked by `wl-paste --watch` (payload on stdin is ignored — we probe
ourselves so a single watcher covers every mime) or with no args to snapshot
the current clipboard. Emits exactly one JSON line per capture:

  {"type":"text","text":...,"ts":...,"bytes":...,"app":...}
  {"type":"image","mime":...,"path":...,"w":...,"h":...,"bytes":...,"ts":...,"app":...}
  {"type":"files","paths":[...],"bytes":...,"ts":...,"app":...}

Sensitive clips (x-kde-passwordManagerHint / CLIPBOARD_STATE=sensitive) and
binary payloads are skipped silently.

The clipboard owner is untrusted: every payload is read through a bounded
reader (byte cap + deadline) and QR/OCR only run on images whose header
dimensions are under a pixel cap, so a hostile or runaway source cannot make
the plugin buffer an unbounded payload or decode a decompression bomb.
"""

import hashlib
import json
import os
import select
import shutil
import struct
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


def _env_int(name, default):
    try:
        return max(0, int(os.environ.get(name, "") or default))
    except ValueError:
        return default


# Payload limits. Anything larger is dropped (not truncated) so the history
# never holds a partial clip. Overridable per environment.
MAX_IMAGE_BYTES = _env_int("CLIPBOARD_MAX_IMAGE_BYTES", 32 * 1024 * 1024)
MAX_TEXT_BYTES = _env_int("CLIPBOARD_MAX_TEXT_BYTES", 4 * 1024 * 1024)
# QR decoding and OCR decode the full bitmap; skip them above this many
# pixels (the image is still recorded and previewed by Qt, which has its own
# allocation limits).
MAX_PARSE_PIXELS = _env_int("CLIPBOARD_MAX_PARSE_PIXELS", 40 * 1000 * 1000)
READ_TIMEOUT = 5.0


def run(args, timeout=5):
    try:
        r = subprocess.run(args, capture_output=True, timeout=timeout)
        return r.stdout if r.returncode == 0 else None
    except Exception:
        return None


def read_bounded(args, limit, timeout=READ_TIMEOUT):
    """Run `args` and return its stdout, or None if it exits non-zero, writes
    more than `limit` bytes, or does not finish within `timeout` seconds.
    Output is streamed and the process is killed as soon as the cap is hit,
    so memory use is bounded by `limit` regardless of what the source sends."""
    try:
        proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except Exception:
        return None
    chunks = []
    total = 0
    ok = True
    deadline = time.monotonic() + timeout
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                ok = False
                break
            ready, _, _ = select.select([proc.stdout], [], [], remaining)
            if not ready:
                ok = False
                break
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                break
            total += len(chunk)
            if total > limit:
                ok = False
                break
            chunks.append(chunk)
    except Exception:
        ok = False
    finally:
        if not ok:
            proc.kill()
        try:
            proc.wait(timeout=2)
        except Exception:
            proc.kill()
        proc.stdout.close()
    if not ok or proc.returncode != 0:
        return None
    return b"".join(chunks)


def read_clipboard(mime, limit):
    return read_bounded(["wl-paste", "--type", mime, "--no-newline"], limit)


def image_size(data, mime):
    """(width, height) from the container header alone — no pixel decoding.
    Returns None when the header is not understood."""
    try:
        if mime == "image/png" and data[:8] == b"\x89PNG\r\n\x1a\n" and data[12:16] == b"IHDR":
            return struct.unpack(">II", data[16:24])
        if mime == "image/gif" and data[:6] in (b"GIF87a", b"GIF89a"):
            return struct.unpack("<HH", data[6:10])
        if mime == "image/bmp" and data[:2] == b"BM":
            w, h = struct.unpack("<ii", data[18:26])
            return abs(w), abs(h)
        if mime == "image/webp" and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
            chunk = data[12:16]
            if chunk == b"VP8X":
                w = int.from_bytes(data[24:27], "little") + 1
                h = int.from_bytes(data[27:30], "little") + 1
                return w, h
            if chunk == b"VP8L" and data[20] == 0x2F:
                bits = int.from_bytes(data[21:25], "little")
                return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
            if chunk == b"VP8 ":
                w, h = struct.unpack("<HH", data[26:30])
                return w & 0x3FFF, h & 0x3FFF
        if mime == "image/jpeg" and data[:2] == b"\xff\xd8":
            i = 2
            n = len(data)
            while i + 9 < n:
                if data[i] != 0xFF:
                    i += 1
                    continue
                marker = data[i + 1]
                if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                    i += 2
                    continue
                length = struct.unpack(">H", data[i + 2:i + 4])[0]
                if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                    h, w = struct.unpack(">HH", data[i + 5:i + 9])
                    return w, h
                i += 2 + length
        if mime == "image/tiff" and data[:4] in (b"II*\x00", b"MM\x00*"):
            end = "<" if data[:2] == b"II" else ">"
            off = struct.unpack(end + "I", data[4:8])[0]
            count = struct.unpack(end + "H", data[off:off + 2])[0]
            w = h = None
            for k in range(min(count, 64)):
                e = off + 2 + k * 12
                tag, typ = struct.unpack(end + "HH", data[e:e + 4])
                val = struct.unpack(end + ("H" if typ == 3 else "I"), data[e + 8:e + 8 + (2 if typ == 3 else 4)])[0]
                if tag == 256:
                    w = val
                elif tag == 257:
                    h = val
            if w and h:
                return w, h
    except Exception:
        return None
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
    data = read_clipboard(mime, MAX_IMAGE_BYTES)
    if not data:
        # Oversized, slow, or empty: skip the clip entirely (an image mime was
        # offered, so we do not fall through to a text capture of it either).
        return True
    os.makedirs(IMAGE_DIR, exist_ok=True)
    digest = hashlib.sha256(data).hexdigest()
    path = os.path.join(IMAGE_DIR, f"{digest}.{IMAGE_EXT[mime]}")
    entry = {"type": "image", "mime": mime, "path": path, "bytes": len(data), "app": app}

    # Dimensions from the header only; the bitmap is never decoded here.
    size = image_size(data, mime)
    if size:
        entry["w"], entry["h"] = int(size[0]), int(size[1])
    # Unknown or huge dimensions → no QR/OCR pass (both decode the full image).
    parse_ok = bool(size) and size[0] * size[1] <= MAX_PARSE_PIXELS

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

    qr = decode_qr(path) if parse_ok and os.environ.get("CLIPBOARD_QR", "1") != "0" else None
    if qr:
        entry["qr"] = qr

    ocr = decode_ocr(path, os.environ.get("CLIPBOARD_OCR_LANG", "eng")) if parse_ok else None
    if ocr:
        entry["ocr"] = ocr

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


def decode_ocr(path, lang):
    """Recognize text in an image with tesseract; None when unavailable/binary."""
    if os.environ.get("CLIPBOARD_OCR", "1") == "0":
        return None
    # Tesseract is optional — degrade to no-OCR when missing.
    if shutil.which("tesseract") is None:
        return None
    try:
        r = subprocess.run(
            ["tesseract", path, "stdout", "-l", lang],
            capture_output=True, timeout=30
        )
        if r.returncode != 0:
            return None
        text = r.stdout.decode("utf-8", "replace")
        # Collapse tesseract's whitespace so the stored haystack stays dense.
        text = "\n".join(line.strip() for line in text.splitlines()
                         if line.strip())
        text = text.strip()
        return text[:4000] or None
    except Exception:
        return None


def capture_uri_list(types, app):
    if "text/uri-list" not in types:
        return False
    data = read_clipboard("text/uri-list", MAX_TEXT_BYTES)
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
    data = read_clipboard(mime, MAX_TEXT_BYTES)
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
