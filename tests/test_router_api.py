"""Execute the adapter with local backend and intercepted response transport."""
import json
import base64
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RouterAPITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="axdhcp-api-test-")
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.home = self.path / "home"
        self.home.mkdir()
        (self.home / "backend").symlink_to(ROOT / "backend")
        (self.home / "config").mkdir()
        self.conf = self.home / "config/axdhcp.conf"
        self.example = (ROOT / "config/axdhcp.conf.example").read_text()
        self.conf.write_text(self.example)
        mockbin = self.path / "bin"
        mockbin.mkdir()
        curl = mockbin / "curl"
        curl.write_text('#!/bin/sh\nwhile [ "$#" -gt 0 ]; do\nif [ "$1" = --data-binary ]; then printf "%s" "$2" > "$AXDHCP_RESPONSE"; exit; fi\nshift\ndone\nexit 1\n')
        curl.chmod(0o755)
        self.response = self.path / "response.json"
        self.env = {**os.environ, "PATH": str(mockbin) + ":" + os.environ["PATH"], "AXDHCP_HOME": str(self.home), "AXDHCP_RUN": str(self.path / "runtime"), "AXDHCP_RESPONSE": str(self.response)}

    def call(self, *args):
        if len(args) == 3 and args[1] == "save":
            args = (*args[:2], "AXDHCP64:" + base64.b64encode(args[2].encode()).decode())
        result = subprocess.run(["sh", str(ROOT / "adapters/koolshare/router-api.sh"), *args], env=self.env, capture_output=True, text=True, timeout=15)
        payload = None
        if self.response.exists():
            wire = self.response.read_text()
            self.assertTrue(wire.startswith("AXDHCP64:"))
            # Reproduce the firmware's unescaped quoted result wrapper.
            envelope = json.loads('{"result":"' + wire + '"}')
            payload = json.loads(base64.b64decode(envelope["result"][9:]).decode())
        return result, payload

    def test_read_and_save_configuration_without_activation(self):
        result, payload = self.call("123", "read")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(payload["ok"])
        self.assertIn("hardware_verified=0", payload["status"])
        changed = self.example.replace("lease_seconds=600", "lease_seconds=1200")
        result, payload = self.call("124", "save", changed)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(payload["ok"])
        self.assertIn("lease_seconds=1200", self.conf.read_text())
        self.assertFalse((self.path / "runtime/generation").exists())

    def test_status_poll_skips_discovery_and_full_read_returns_interfaces(self):
        import shutil
        (self.home / "backend").unlink()
        shutil.copytree(ROOT / "backend",self.home / "backend")
        (self.home / "backend/discover.sh").write_text("#!/bin/sh\nprintf '[{\"name\":\"br-lan\",\"kind\":\"bridge\"}]\\n'\n")
        result,payload=self.call("140","read")
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(payload["interfaces"][0]["name"],"br-lan")
        (self.home / "backend/discover.sh").write_text("#!/bin/sh\nexit 99\n")
        result,payload=self.call("141","read","status-only")
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIsNone(payload["interfaces"])

    def test_activation_invalid_data_and_unknown_actions_rejected(self):
        for action, args in [("save", [self.example.replace("downstream=eth6,wl1.1", "downstream=eth7")]), ("start", []), ("filters-test", []), ("save", ["enabled=$(reboot)"] )]:
            with self.subTest(action=action, args=args):
                before = self.conf.read_text()
                result, payload = self.call("125", action, *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(payload["ok"])
                self.assertEqual(self.conf.read_text(), before)
                self.assertFalse((self.path / "runtime/generation").exists())

    def test_request_id_rejected_before_transport(self):
        result, payload = self.call("../other", "read")
        self.assertEqual(result.returncode, 64)
        self.assertIsNone(payload)

    def test_retired_page_actions_cannot_activate_network(self):
        for action, confirmation in [("filters", "network-change-confirmed"), ("dhcp", "network-and-filter-paths-confirmed")]:
            result, payload = self.call("129", action, confirmation)
            self.assertEqual(result.returncode, 64)
            self.assertFalse(payload["ok"])
            self.assertIn("Action unavailable", payload["message"])
            self.assertFalse((self.path / "runtime/generation").exists())

    def test_saving_enabled_does_not_start_service(self):
        result, payload = self.call("132", "save", self.example.replace("enabled=0", "enabled=1"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("enabled=1", self.conf.read_text())
        self.assertFalse((self.path / "runtime/generation").exists())

    def test_continuous_requires_acknowledgement_and_enabled_configuration(self):
        for args in [(), ("network-and-filter-paths-confirmed",)]:
            result, payload = self.call("133", "run", *args)
            self.assertEqual(result.returncode, 64)
            self.assertFalse(payload["ok"])
        result, payload = self.call("134", "run", "network-change-and-unverified-paths-acknowledged")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("disabled", payload["message"])
        self.assertFalse((self.path / "runtime/generation").exists())
        result, payload = self.call("135", "read")
        self.assertIn("last_error=Configuration is disabled", payload["status"])
        self.assertIn("Operation failed: Configuration is disabled", payload["logs"])

    def test_save_autostart_optin_does_not_launch_and_cancels_boot_wait(self):
        runtime=self.path / "runtime"
        runtime.mkdir(mode=0o700)
        (runtime / "boot.pending").write_text("123 456\n")
        enabled=self.example.replace("enabled=0","enabled=1").replace("autostart=0","autostart=1").replace("pool_confirmed=0","pool_confirmed=1").replace("dns_confirmed=0","dns_confirmed=1")
        result, payload = self.call("136", "save", enabled)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn("autostart=1",self.conf.read_text())
        self.assertFalse((runtime / "generation").exists())
        self.assertFalse((runtime / "boot.pending").exists())

    def test_readonly_check_action_returns_report(self):
        # Run production adapter; replace only firmware-only diagnostic script.
        import shutil
        (self.home / "backend").unlink()
        shutil.copytree(ROOT / "backend", self.home / "backend")
        (self.home / "backend/check-env.sh").write_text("#!/bin/sh\nprintf 'AXDHCP_CHECK_BEGIN\\n只读\\nAXDHCP_CHECK_END\\n'\n")
        result, payload = self.call("126", "check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(payload["ok"])
        self.assertIn("AXDHCP_CHECK_END", payload["logs"])
        self.assertFalse((self.path / "runtime/generation").exists())


if __name__ == "__main__":
    unittest.main()
