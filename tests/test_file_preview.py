import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('file_preview', Path(__file__).resolve().parents[1] / 'scripts/file-preview.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FilePreviewTests(unittest.TestCase):
    def test_text_is_bounded_and_path_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'a " quoted.txt'
            path.write_text('a' * 10000)
            data = module.preview(str(path))
            self.assertEqual(data['bytes'], 10000)
            self.assertEqual(len(data['text']), 8192)
            self.assertTrue(data['truncated'])
            self.assertEqual(data['path'], str(path))

    def test_missing_file_and_folder(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(module.preview(directory)['kind'], 'Folder')
            self.assertIn('error', module.preview(directory + '/missing'))

    def test_special_file_is_not_read(self):
        with tempfile.TemporaryDirectory() as directory:
            path = directory + '/fifo.txt'
            os.mkfifo(path)
            self.assertEqual(module.preview(path)['kind'], 'Special file')

    def test_missing_media_tools_preserve_basic_metadata(self):
        with tempfile.NamedTemporaryFile(suffix='.mp4') as source:
            with patch.object(module, 'read_bounded', return_value=None):
                data = module.preview(source.name)
            self.assertEqual(data['mime'], 'video/mp4')
            self.assertIn('bytes', data)
            self.assertNotIn('thumbnail', data)

    @unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'ffmpeg optional')
    def test_video_resolution_duration_and_thumbnail(self):
        with tempfile.TemporaryDirectory() as directory:
            path = directory + '/clip.mkv'
            subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=red:s=160x90:d=1', '-c:v', 'ffv1', path], check=True, timeout=10)
            data = module.preview(path)
            self.assertEqual((data['width'], data['height']), (160, 90))
            self.assertAlmostEqual(data['duration'], 1, places=1)
            self.assertTrue(data['thumbnail'].startswith('data:image/jpeg;base64,'))

    @unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'ffmpeg optional')
    def test_audio_details(self):
        with tempfile.TemporaryDirectory() as directory:
            path = directory + '/audio.wav'
            subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'sine=duration=1', path], check=True, timeout=10)
            data = module.preview(path)
            self.assertAlmostEqual(data['duration'], 1, places=1)
            self.assertIn('44100 Hz', data['audio'])
            self.assertNotIn('thumbnail', data)

    def test_generic_binary_not_shown_as_text(self):
        with tempfile.NamedTemporaryFile(suffix='.txt') as source:
            source.write(b'abc\x00def')
            source.flush()
            self.assertNotIn('text', module.preview(source.name))
