import os
import subprocess
import sys
import tempfile
import unittest


class WatcherInputTests(unittest.TestCase):
    def helper(self, stdin, timeout=0.2):
        return subprocess.Popen(
            [sys.executable, "-c", """
import capture
import sys
import tracemalloc
tracemalloc.start()
drain = capture.drain_stdin
capture.drain_stdin = lambda: drain(timeout=float(sys.argv[1]))
capture.list_types = lambda: print('probed') or []
capture.main()
assert tracemalloc.get_traced_memory()[1] < 1024 * 1024
""", str(timeout)], stdin=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

    def finish(self, proc, expected, payload=None):
        try:
            out, err = proc.communicate(input=payload, timeout=8)
            self.assertEqual(proc.returncode, 0, err.decode())
            self.assertEqual(out, expected)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()

    def test_large_payload_is_discarded_without_accumulation(self):
        with tempfile.TemporaryFile() as source:
            source.truncate(64 * 1024 * 1024)
            self.finish(self.helper(source, timeout=5), b"probed\n")

    def test_finite_pipe_still_probes(self):
        self.finish(self.helper(subprocess.PIPE, timeout=5), b"probed\n",
                    payload=b"clipboard content\n" * 16384)

    def test_stalled_pipe_exits_without_probing(self):
        reader, writer = os.pipe()
        try:
            with os.fdopen(reader, "rb") as source:
                self.finish(self.helper(source), b"")
        finally:
            os.close(writer)

    def test_endless_source_exits_without_probing(self):
        with open('/dev/zero', 'rb') as source:
            self.finish(self.helper(source), b"")

    def test_empty_input_still_probes(self):
        self.finish(self.helper(subprocess.DEVNULL), b"probed\n")
