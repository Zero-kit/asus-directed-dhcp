"""Read-only discovery with a fake firmware and sysfs tree."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]


class InterfaceTests(unittest.TestCase):
    def test_multiple_radios_bridges_roles_and_untrusted_ssid(self):
        with tempfile.TemporaryDirectory(prefix="axdhcp-interfaces-") as tmp:
            root=Path(tmp);net=root / "net";bins=root / "bin";bins.mkdir();net.mkdir()
            for name in ["br-lan","br-guest","wifi0","wifi1","wifi1.2","eth2","lo"]:
                (net / name).mkdir()
                (net / name / "type").write_text("772\n" if name=="lo" else "1\n")
            for bridge in ["br-lan","br-guest"]:
                (net / bridge / "bridge").mkdir();(net / bridge / "brif").mkdir()
            for name in ["wifi0","wifi1","wifi1.2","eth2"]:
                (net / "br-lan/brif" / name).mkdir()
            data={"wl0_ifname":"wifi0","wl0_mode":"ap","wl0_nband":"2","wl0_ssid":'SSID "quoted" <tag>',"wl1_ifname":"wifi1","wl1_mode":"wet","wl1_nband":"1","wl1_ssid":"Upstream","wl1_vifs":"wl1.2","wl1.2_ifname":"wifi1.2","wl1.2_mode":"ap","wl1.2_ssid":"Guest"}
            # argv lookup only; malicious SSID is data, never shell source.
            db=root / "nvram.json";db.write_text(json.dumps(data))
            mock=bins / "nvram"
            mock.write_text('#!/usr/bin/env python3\nimport json,sys\nprint(json.load(open('+repr(str(db))+')).get(sys.argv[2],""))\n');mock.chmod(0o755)
            env={**os.environ,"PATH":str(bins)+":"+os.environ["PATH"],"AXDHCP_NET_ROOT":str(net)}
            result=subprocess.run(["sh",str(ROOT / "backend/discover.sh")],env=env,capture_output=True,text=True,timeout=15)
            self.assertEqual(result.returncode,0,result.stderr)
            items={item["name"]:item for item in json.loads(result.stdout)}
            self.assertEqual(items["br-lan"]["kind"],"bridge")
            self.assertEqual(items["wifi0"]["role"],"ap")
            self.assertEqual(items["wifi0"]["band"],"2.4 GHz")
            self.assertEqual(items["wifi0"]["ssid"],data["wl0_ssid"])
            self.assertEqual(items["wifi1"]["role"],"uplink")
            self.assertEqual(items["wifi1.2"]["role"],"ap")
            self.assertEqual(items["wifi1.2"]["prefix"],"wl1.2")
            self.assertEqual(items["eth2"]["kind"],"ethernet")
            self.assertNotIn("lo",items)
            self.assertEqual(items["wifi1"]["bridge"],"br-lan")
            data["wl0_mode"]="";db.write_text(json.dumps(data))
            unknown=subprocess.run(["sh",str(ROOT / "backend/discover.sh")],env=env,capture_output=True,text=True,timeout=15)
            self.assertEqual(next(item for item in json.loads(unknown.stdout) if item["name"]=="wifi0")["role"],"unknown")
            driver=bins / "wl"
            driver.write_text('#!/bin/sh\ncase "$*" in "-i wifi0 status") printf "Mode: AP\\n";; esac\n');driver.chmod(0o755)
            driver_result=subprocess.run(["sh",str(ROOT / "backend/discover.sh")],env=env,capture_output=True,text=True,timeout=15)
            self.assertEqual(next(item for item in json.loads(driver_result.stdout) if item["name"]=="wifi0")["role"],"ap")
            data["wl0_mode"]="ap";db.write_text(json.dumps(data))
            for name in ["br-lan","br-guest","wifi0","wifi1","wifi1.2","eth2"]:
                (net / name / "address").write_text("02:00:00:00:00:01\n")
                (net / name / "carrier").write_text("1\n")
                (net / name / "operstate").write_text("up\n")
            library=(ROOT / "backend/axdhcp.sh").read_text().split('case ${1:-help} in',1)[0]
            prefix=library+'''
ip() { printf 'UP\\n'; }
wl() { printf '02:00:00:00:00:01\\n'; }
cat() {
    case "$1" in /proc/sys/net/ipv4/ip_forward) printf '0\\n';; *) command cat "$@";; esac
}
BRIDGE=br-lan; BACKHAUL=wifi1; DOWN=wifi0,wifi1.2
'''
            backend_env={**env,"AXDHCP_HOME":str(ROOT)}
            for suffix,expected in [("network_fingerprint",0),("DOWN=wifi1; network_fingerprint",1),("BRIDGE=br-guest; network_fingerprint",1),("DOWN=wifi0; BACKHAUL=wifi0; network_fingerprint",1)]:
                checked=subprocess.run(["sh"],input=prefix+suffix,env=backend_env,capture_output=True,text=True,timeout=15)
                self.assertEqual(checked.returncode,expected,checked.stderr)
            data["wl0_mode"]="sta";db.write_text(json.dumps(data))
            changed=subprocess.run(["sh"],input=prefix+"network_fingerprint",env=backend_env,capture_output=True,text=True,timeout=15)
            self.assertEqual(changed.returncode,1,changed.stderr)
            data.update({"wl0_mode":"ap","wl1_mode":"ap","sw_mode":"3","wlc_mode":"1","wlc_band":"1"});db.write_text(json.dumps(data))
            repeater=subprocess.run(["sh",str(ROOT / "backend/discover.sh")],env=env,capture_output=True,text=True,timeout=15)
            repeater_items={item["name"]:item for item in json.loads(repeater.stdout)}
            self.assertEqual(repeater_items["wifi1"]["role"],"uplink")
            self.assertEqual(repeater_items["wifi1.2"]["role"],"ap")


if __name__=="__main__":
    unittest.main()
