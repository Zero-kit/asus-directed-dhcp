"""Verify production browser action flows with a small DOM/transport fixture."""
from pathlib import Path
import subprocess
import unittest

ROOT=Path(__file__).resolve().parents[1]


class WebTests(unittest.TestCase):
    def test_start_error_and_autostart_flows(self):
        result=subprocess.run(["node",str(ROOT / "tests/web_lifecycle.mjs")],capture_output=True,text=True,timeout=15)
        self.assertEqual(result.returncode,0,result.stderr)


if __name__=="__main__":
    unittest.main()
