#!/usr/bin/env python3
"""Bounded, on-demand metadata for one local copied file; never modifies it."""
import base64
import json
import mimetypes
import os
from pathlib import Path
import stat
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from capture import read_bounded


def preview(path):
    result = {'path': path}
    deadline = time.monotonic() + 6

    def run(args, limit=128 * 1024):
        remaining = deadline - time.monotonic()
        return read_bounded(args, limit, timeout=min(2, remaining)) if remaining > 0 else None

    try:
        info = os.stat(path)
        result.update(bytes=info.st_size, modified=int(info.st_mtime))
        if stat.S_ISDIR(info.st_mode):
            result['kind'] = 'Folder'
            return result
        if not stat.S_ISREG(info.st_mode):
            result['kind'] = 'Special file'
            return result
        mime = mimetypes.guess_type(path)[0] or 'application/octet-stream'
        result['mime'] = mime
        result['kind'] = mime
        # Do not let a media playlist cause ffmpeg to open referenced resources.
        media = Path(path).suffix.lower() in {'.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp', '.tiff', '.tif', '.avif', '.heic', '.mp4', '.mkv', '.webm', '.mov', '.avi', '.m4v', '.mp3', '.flac', '.wav', '.ogg', '.opus', '.m4a', '.aac'}
        if media:
            options = ['-v', 'error', '-max_alloc', '67108864', '-protocol_whitelist', 'file', '-probesize', '1048576', '-analyzeduration', '1000000']
            data = run(['ffprobe'] + options + ['-show_entries', 'format=duration:stream=codec_type,codec_name,width,height,sample_rate,channels', '-of', 'json', path])
            if data:
                parsed = json.loads(data)
                duration = float(parsed.get('format', {}).get('duration', 0))
                if 0 < duration < 1e9:
                    result['duration'] = duration
                streams = parsed.get('streams', [])
                visual = next((s for s in streams if s.get('codec_type') == 'video'), {})
                audio = next((s for s in streams if s.get('codec_type') == 'audio'), {})
                for key in ('width', 'height'):
                    if visual.get(key):
                        result[key] = int(visual[key])
                if audio:
                    result['audio'] = ' · '.join(str(audio[k]) + suffix for k, suffix in [('codec_name', ''), ('sample_rate', ' Hz'), ('channels', ' channels')] if audio.get(k))
                if 0 < result.get('width', 0) * result.get('height', 0) <= 40000000:
                    thumb = run(['ffmpeg'] + options + ['-nostdin', '-threads', '1', '-i', path, '-frames:v', '1', '-vf', 'scale=640:360:force_original_aspect_ratio=decrease', '-threads', '1', '-f', 'image2pipe', '-c:v', 'mjpeg', '-protocol_whitelist', 'pipe', 'pipe:1'], 512 * 1024)
                    if thumb:
                        result['thumbnail'] = 'data:image/jpeg;base64,' + base64.b64encode(thumb).decode('ascii')
        elif mime == 'application/pdf':
            thumb = run(['pdftoppm', '-f', '1', '-singlefile', '-scale-to', '640', '-jpeg', path], 512 * 1024)
            if thumb:
                result['thumbnail'] = 'data:image/jpeg;base64,' + base64.b64encode(thumb).decode('ascii')
            data = run(['pdfinfo', path])
            if data:
                result['details'] = '\n'.join(line.strip() for line in data.decode('utf-8', 'replace').splitlines() if line.startswith(('Pages:', 'Page size:', 'Title:', 'Author:')))
        elif mime.startswith('text/') or Path(path).suffix.lower() in {'.json', '.yaml', '.yml', '.toml', '.md', '.py', '.js', '.ts', '.qml', '.sh', '.rs', '.go', '.log', '.csv'}:
            # Nonblocking open avoids hanging on a file replaced with a FIFO.
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
            with os.fdopen(fd, 'rb') as source:
                if stat.S_ISREG(os.fstat(source.fileno()).st_mode):
                    data = source.read(8193)
                    if b'\0' not in data:
                        result['text'] = data[:8192].decode('utf-8', 'replace')
                        result['truncated'] = len(data) > 8192
    except (OSError, ValueError, TypeError) as error:
        result['error'] = str(error)
    return result


if __name__ == '__main__':
    print(json.dumps({'request': sys.argv[1], 'file': preview(os.path.abspath(sys.argv[2]))}))
