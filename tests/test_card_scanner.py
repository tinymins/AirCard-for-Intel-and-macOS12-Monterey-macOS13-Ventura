import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from aircard import CARD_REGEXES


@unittest.skipUnless(sys.platform == "darwin", "The native log reader requires macOS")
class CardScannerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.executable = Path(cls.temporary.name) / "test_os_trace"
        source = Path(__file__).with_name("test_os_trace.m")
        subprocess.run(
            ["xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
             "-framework", "Foundation", str(source), "-o", str(cls.executable)],
            check=True, capture_output=True, text=True,
        )

    def test_activity_stream_protocol(self):
        result = subprocess.run(
            [str(self.executable)], check=True, capture_output=True, text=True,
        )
        self.assertIn("malformed records passed", result.stdout)

    def test_ios18_resource_path_reaches_existing_card_patterns(self):
        result = subprocess.run(
            [str(self.executable), "--fixture"], check=True,
            capture_output=True, text=True,
        )
        hashes = {
            match.group(1)
            for line in result.stdout.splitlines()
            if "/cards/" in line.lower()
            for pattern in CARD_REGEXES
            for match in pattern.finditer(line)
        }
        self.assertEqual(hashes, {"AAAAAAAAAAAAAAAAAAAAAAAAAAA="})


if __name__ == "__main__":
    unittest.main()
