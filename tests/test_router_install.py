"""Run installer lifecycle in a sandbox with mocked firmware commands."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RouterInstallTests(unittest.TestCase):
    def test_services_start_dispatches_hook_without_wan_or_arguments(self):
        import time
        with tempfile.TemporaryDirectory(prefix="axdhcp-boot-dispatch-") as temp:
            ks=Path(temp) / "koolshare"
            (ks / "init.d").mkdir(parents=True)
            (ks / "axdhcp/backend").mkdir(parents=True)
            backend=ks / "axdhcp/backend/axdhcp.sh"
            backend.write_text('#!/bin/sh\n[ "$1" = boot ] || exit 9\nprintf "boot\\n" >> "'+str(ks / "invocations")+'"\n')
            hook=ks / "init.d/V99axdhcp.sh"
            hook.write_text((ROOT / "adapters/koolshare/boot-router.sh").read_text().replace("/koolshare",str(ks)))
            hook.chmod(0o755)
            legacy=ks / "init.d/S99axdhcp.sh"
            legacy.write_text('#!/bin/sh\nexit 99\n');legacy.chmod(0o755)
            # Match ks-services-start's V* scan and no-argument invocation.
            dispatcher='for hook in $(find "'+str(ks / "init.d")+'" -name "V*" | sort -n); do "$hook" || exit; done'
            result=subprocess.run(["sh","-c",dispatcher],capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stderr)
            deadline=time.monotonic()+3
            while not (ks / "invocations").exists() and time.monotonic()<deadline:
                time.sleep(0.02)
            self.assertEqual((ks / "invocations").read_text(),"boot\n")

    def test_fresh_reinstall_residual_and_failure_restore(self):
        with tempfile.TemporaryDirectory(prefix="axdhcp-install-test-") as temp:
            base = Path(temp)
            ks = base / "koolshare"
            for name in ["scripts", "webs", "res", "init.d"]:
                (ks / name).mkdir(parents=True)
            src = base / "package"
            src.mkdir()
            import shutil
            for name in ["backend", "config", "docs"]:
                shutil.copytree(ROOT / name, src / name)
            (src / "res/axdhcp").mkdir(parents=True)
            for name in ["app.js", "presentation.js", "style.css", "router-style.css", "router-transport.js", "index.html"]:
                (src / "res/axdhcp" / name).write_text("asset")
            (src / "scripts").mkdir()
            (src / "scripts/axdhcp_api.sh").write_text("#!/bin/sh\n")
            (src / "scripts/axdhcp_boot.sh").write_text((ROOT / "adapters/koolshare/boot-router.sh").read_text())
            (src / "webs").mkdir()
            (src / "webs/Module_axdhcp.asp").write_text("page")
            (src / "uninstall.sh").write_text("#!/bin/sh\n")
            (src / "version").write_text("0.2.4-integration\n")
            # Redirect exact router paths; preserve production transaction logic.
            script = (ROOT / "adapters/koolshare/install-router.sh").read_text()
            script = script.replace("/koolshare", str(ks)).replace("/tmp/axdhcp", str(base / "runtime"))
            start = script.index('[ -r /proc/self/status ]')
            end = script.index('\n', start)
            script = script[:start] + ':' + script[end:]
            installer = src / "install.sh"
            installer.write_text(script)
            bins = base / "bin"
            bins.mkdir()
            mocks = {
                "nvram": "echo RT-AX88U",
                "uname": 'case "$1" in -m) echo aarch64;; -r) echo 5.4.0;; esac',
                "dbus": 'case "$*" in "get softcenter_version") echo 2.0.0;; esac',
                "ip": "exit 0", "wl": "exit 0", "ebtables": "exit 0", "dnsmasq": "exit 0",
            }
            for name, content in mocks.items():
                path = bins / name
                path.write_text("#!/bin/sh\n" + content + "\n")
                path.chmod(0o755)
            env = {**os.environ, "PATH": str(bins) + ":" + os.environ["PATH"]}

            def install():
                return subprocess.run(["sh", str(installer)], env=env, capture_output=True, text=True, timeout=20)

            first = install()
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(list(ks.glob(".axdhcp-install.*")),[])
            self.assertNotIn("旧文件和配置备份",first.stdout)
            self.assertEqual((ks / "res/axdhcp/app.js").stat().st_mode & 0o777, 0o644)
            self.assertEqual((ks / "init.d/V99axdhcp.sh").stat().st_mode & 0o777, 0o755)
            self.assertFalse((ks / "init.d/S99axdhcp.sh").exists())
            conf = ks / "axdhcp/config/axdhcp.conf"
            conf.write_text(conf.read_text().replace("lease_seconds=600", "lease_seconds=1200").replace("enabled=0", "enabled=1").replace("autostart=0", "autostart=1").replace("pool_confirmed=0", "pool_confirmed=1").replace("dns_confirmed=0", "dns_confirmed=1"))
            (ks / "init.d/S99axdhcp.sh").write_text("legacy boot hook\n")
            # Old stop is intercepted, never operates on router networking.
            old = ks / "axdhcp/backend/axdhcp.sh"
            old.unlink()
            old.write_text('#!/bin/sh\n[ "$1" = stop ]\n')
            second = install()
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertIn("lease_seconds=1200", conf.read_text())
            self.assertIn("enabled=0", conf.read_text())
            self.assertIn("autostart=0", conf.read_text())
            self.assertEqual(list(ks.glob(".axdhcp-install.*")),[])
            self.assertFalse((ks / "init.d/S99axdhcp.sh").exists())
            (ks / "init.d/V99axdhcp.sh").write_text("old boot hook\n")
            (ks / "init.d/S99axdhcp.sh").write_text("legacy boot hook\n")
            old.unlink()
            old.write_text('#!/bin/sh\n[ "$1" = stop ]\n')
            # Inject a late copy failure; expect old files restored.
            cp = bins / "cp"
            cp.write_text('#!/bin/sh\ncase "$*" in *Module_axdhcp.asp*) exit 1;; esac\nexec /bin/cp "$@"\n')
            cp.chmod(0o755)
            failed = install()
            self.assertNotEqual(failed.returncode, 0)
            self.assertEqual(old.read_text(), '#!/bin/sh\n[ "$1" = stop ]\n')
            self.assertIn("lease_seconds=1200", conf.read_text())
            self.assertEqual((ks / "webs/Module_axdhcp.asp").read_text(), "page")
            self.assertEqual((ks / "init.d/V99axdhcp.sh").read_text(), "old boot hook\n")
            self.assertEqual((ks / "init.d/S99axdhcp.sh").read_text(), "legacy boot hook\n")
            cp.unlink()
            # Orphan resource directory without backend is recoverable.
            subprocess.run(["mv", str(ks / "axdhcp"), str(base / "retired")], check=True)
            residual = install()
            self.assertEqual(residual.returncode, 0, residual.stderr)
            # Existing package-like legacy directory has no runtime markers:
            # do not invoke broken old stop or create a lock inside the package.
            legacy = base / "runtime"
            legacy.mkdir()
            (legacy / "install.sh").write_text("package")
            old.write_text('#!/bin/sh\necho broken-old-stop >&2\nexit 99\n')
            retry = install()
            self.assertEqual(retry.returncode, 0, retry.stderr)
            self.assertFalse((legacy / "lock").exists())
            # An actual uncertain legacy DNS launch must block upgrade.
            (legacy / "dns.launching").write_text("legacy-token")
            before = (ks / "axdhcp/VERSION").read_text()
            blocked = install()
            self.assertNotEqual(blocked.returncode, 0)
            self.assertEqual((ks / "axdhcp/VERSION").read_text(), before)

    def test_uninstall_retains_hook_on_stop_failure_and_retires_on_success(self):
        with tempfile.TemporaryDirectory(prefix="axdhcp-uninstall-test-") as temp:
            base=Path(temp);ks=base / "koolshare"
            for directory in ["axdhcp/backend","init.d","scripts","webs","res/axdhcp","bin"]:
                (ks / directory).mkdir(parents=True)
            backend=ks / "axdhcp/backend/axdhcp.sh"
            backend.write_text("#!/bin/sh\nexit 1\n")
            hook=ks / "init.d/V99axdhcp.sh";hook.write_text("boot hook")
            legacy=ks / "init.d/S99axdhcp.sh";legacy.write_text("legacy hook")
            dbus=ks / "bin/dbus";dbus.write_text("#!/bin/sh\nexit 0\n");dbus.chmod(0o755)
            script=base / "uninstall.sh"
            script.write_text((ROOT / "adapters/koolshare/uninstall-router.sh").read_text().replace("/koolshare",str(ks)))
            env={**os.environ,"PATH":str(ks / "bin")+":"+os.environ["PATH"]}
            failed=subprocess.run(["sh",str(script)],env=env,capture_output=True,text=True,timeout=10)
            self.assertNotEqual(failed.returncode,0)
            self.assertTrue(hook.exists());self.assertTrue(backend.exists())
            self.assertTrue(legacy.exists())
            backend.write_text("#!/bin/sh\nexit 0\n")
            success=subprocess.run(["sh",str(script)],env=env,capture_output=True,text=True,timeout=10)
            self.assertEqual(success.returncode,0,success.stderr)
            self.assertFalse(hook.exists())
            self.assertFalse(legacy.exists())
            retired=list(ks.glob("axdhcp.retired.*"))
            self.assertEqual(len(retired),1)
            self.assertEqual((retired[0] / "boot-hook.sh").read_text(),"boot hook")
            self.assertEqual((retired[0] / "legacy-boot-hook.sh").read_text(),"legacy hook")


if __name__ == "__main__":
    unittest.main()
