"""Static/config tests and mocked rule lifecycle. Never operates on a router."""
import json
import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT / "backend/axdhcp.sh"
LIBRARY = BACKEND.read_text().split('case ${1:-help} in', 1)[0]
EXAMPLE = (ROOT / "config/axdhcp.conf.example").read_text()


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="axdhcp-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.run = self.root / "runtime"
        self.run.mkdir(mode=0o700)
        self.home = self.root / "home"
        (self.home / "config").mkdir(parents=True)
        (self.home / "backend").symlink_to(ROOT / "backend", target_is_directory=True)
        self.config = self.home / "config/axdhcp.conf"
        self.config.write_text(EXAMPLE)
        self.db = self.root / "rules.json"
        self.env = {**os.environ, "AXDHCP_HOME": str(self.home), "AXDHCP_RUN": str(self.run), "AXDHCP_MOCK_STATE": str(self.db)}

    def call(self, *args, **kwargs):
        return subprocess.run(["sh", str(BACKEND), *map(str,args)], env=self.env, capture_output=True, text=True, timeout=15, **kwargs)

    def shell(self, script):
        mock = "python3 " + shlex.quote(str(ROOT / "tests/mock_ebtables.py"))
        # Function library is production code. Only external packet operations
        # are replaced; the real lifecycle/rule-monitoring functions execute.
        prefix = LIBRARY + '\neb() { ' + mock + ' -t filter "$@"; }\nBRIDGE=br0\nBACKHAUL=eth7\nDOWN=wl1.1\n'
        result = subprocess.run(["sh"], input=prefix + script, env=self.env, text=True, capture_output=True, timeout=20)
        return result

    def valid(self, changes=None, suffix="", bridge_ip=None, prefix=None):
        data = dict(line.split("=",1) for line in EXAMPLE.splitlines() if line and not line.startswith("#"))
        data.update(changes or {})
        self.config.write_text("\n".join(f"{k}={v}" for k,v in data.items()) + "\n" + suffix)
        args = ["awk"]
        if bridge_ip is not None:
            args += ["-v", f"bridge_ip={bridge_ip}"]
        if prefix is not None:
            args += ["-v", f"bridge_prefix={prefix}"]
        return subprocess.run(args + ["-f", str(ROOT / "backend/validate.awk"), str(self.config)], capture_output=True, text=True, timeout=10)

    def db_read(self):
        return json.loads(self.db.read_text())

    def test_defaults_are_disabled_valid_data(self):
        result = self.call("validate", self.config)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("enabled=0\n", result.stdout)
        self.assertIn("autostart=0\n", result.stdout)
        self.assertIn("pool_confirmed=0\n", result.stdout)

    def test_custom_interfaces_validate_and_rules_restore_selected_bridge(self):
        self.assertEqual(self.valid({"bridge":"br-lan","backhaul":"wifi1","downstream":"wifi0,wifi1.2"}).returncode,0)
        r=self.shell('''
BRIDGE=br-lan; BACKHAUL=wifi1; DOWN=wifi0,wifi1.2
printf '%s\\n' "$BRIDGE" > "$RUN/bridge.snapshot"
install_rules || exit 1
check_rules || exit 2
BRIDGE=wrong
remove_rules || exit 3
''')
        self.assertEqual(r.returncode,0,r.stderr)
        db=self.db_read()
        self.assertEqual(set(db["chains"]),{"INPUT","OUTPUT","FORWARD"})
        insertions=[row for row in db["journal"] if row[0]=="-I"]
        self.assertEqual(len(insertions),3)
        self.assertTrue(all("br-lan" in row for row in insertions))
        self.assertTrue(any("wifi0" in row for row in db["journal"]))
        self.assertTrue(any("wifi1.2" in row for row in db["journal"]))
        self.assertFalse(any("wifi1" in row for row in db["journal"]))

    def test_generated_dns_config_uses_internal_server_identifier(self):
        r=self.shell('''
cp "$CONF" "$RUN/config.valid"
BRIDGE=br0; BRIDGE_IP=10.0.0.7
ls() { printf 'eth6\\n'; }
cat() {
    case "$1" in /sys/class/net/eth6/type) printf '1\\n';; /sys/class/net/eth6/address) printf '02:00:00:00:00:01\\n';; *) command cat "$@";; esac
}
dnsmasq() {
    [ "$1" = --test ] || return 9
    grep -q '^dhcp-host=02:00:00:00:00:01,ignore$' "$RUN/dnsmasq.conf" || return 9
    ! grep -q 'server-identifier' "$RUN/dnsmasq.conf"
}
make_dns_config
''')
        self.assertEqual(r.returncode,0,r.stderr)
        generated=(self.run / "dnsmasq.conf").read_text()
        self.assertIn("dhcp-option=option:router,10.0.0.1",generated)
        self.assertIn("\nuser=\ngroup=\n",generated)
        self.assertNotIn("user=root",generated)
        self.assertNotIn("server-identifier",generated)

    def test_dns_config_failure_exposes_dnsmasq_original_diagnostic(self):
        r=self.shell('''
cp "$CONF" "$RUN/config.valid"
BRIDGE=br0; REPORT_ERRORS=1
ls() { return 0; }
dnsmasq() { printf 'dnsmasq: bad dhcp-option at line 15\\n' >&2; return 1; }
make_dns_config
''')
        self.assertEqual(r.returncode,1,r.stderr)
        self.assertIn("bad dhcp-option at line 15",r.stderr)
        self.assertIn("bad dhcp-option at line 15",(self.run / "last-error").read_text())
        self.assertIn("bad dhcp-option at line 15",(self.run / "control.log").read_text())
        self.assertFalse((self.run / "generation").exists())

    def test_startup_diagnostics_capture_exited_process_and_dnsmasq_cause(self):
        r=self.shell('''
dns_pid=99999999; dns_start=123
printf 'dnsmasq: unknown user or group: root\\n' > "$RUN/dnsmasq-startup.log"
printf 'dnsmasq runtime diagnostic\\n' > "$RUN/dhcp.log"
dns_startup_details
''')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn("process=exited",r.stdout)
        self.assertIn("unknown user or group: root",r.stdout)
        self.assertIn("dnsmasq runtime diagnostic",r.stdout)
        self.assertFalse((self.run / "generation").exists())

    def test_tunnel_addresses_do_not_abort_ethernet_mac_exclusions(self):
        r=self.shell('''
cp "$CONF" "$RUN/config.valid"
BRIDGE=br0; BACKHAUL=eth7
ls() { printf 'br0\\neth6\\nsit0\\nip6tnl0\\nlo\\n'; }
cat() {
    case "$1" in
        /sys/class/net/br0/type|/sys/class/net/eth6/type) printf '1\\n';;
        /sys/class/net/br0/address) printf '02:00:00:00:00:01\\n';;
        /sys/class/net/eth6/address) printf '02:00:00:00:00:02\\n';;
        /sys/class/net/sit0/type) printf '776\\n';;
        /sys/class/net/ip6tnl0/type) printf '769\\n';;
        /sys/class/net/lo/type) printf '772\\n';;
        /sys/class/net/*/address) exit 9;;
        *) command cat "$@";;
    esac
}
dnsmasq() { return 0; }
make_dns_config
''')
        self.assertEqual(r.returncode,0,r.stderr)
        generated=(self.run / "dnsmasq.conf").read_text()
        self.assertEqual(generated.count("dhcp-host="),2)
        self.assertIn("dhcp-host=02:00:00:00:00:01,ignore",generated)
        self.assertIn("dhcp-host=02:00:00:00:00:02,ignore",generated)

    def test_ethernet_address_errors_report_interface_before_dnsmasq(self):
        for address in ["bad-mac","00:00:00:00:00:00",""]:
            with self.subTest(address=address):
                r=self.shell('''
cp "$CONF" "$RUN/config.valid"
BRIDGE=br0; BACKHAUL=eth7; DOWN=eth6; REPORT_ERRORS=1
ls() { printf 'eth6\\n'; }
cat() {
    case "$1" in
        /sys/class/net/eth6/type) printf '1\\n';;
        /sys/class/net/eth6/address) printf '%s\\n' '''+shlex.quote(address)+''';;
        *) command cat "$@";;
    esac
}
dnsmasq() { exit 9; }
make_dns_config
''')
                self.assertEqual(r.returncode,1,r.stderr)
                self.assertIn("DHCP configuration generation failed",r.stderr)
                self.assertIn("eth6",r.stderr)
                self.assertIn("eth6",(self.run / "last-error").read_text())

    @unittest.skipUnless(os.environ.get("AXDHCP_TEST_DNSMASQ"), "dnsmasq parser binary not configured")
    def test_generated_config_passes_real_dnsmasq_parser(self):
        parser=shlex.quote(os.environ["AXDHCP_TEST_DNSMASQ"])
        r=self.shell('''
cp "$CONF" "$RUN/config.valid"
BRIDGE=br0; BRIDGE_IP=10.0.0.7
ls() { printf 'eth6\\n'; }
cat() {
    case "$1" in /sys/class/net/eth6/type) printf '1\\n';; /sys/class/net/eth6/address) printf '02:00:00:00:00:01\\n';; *) command cat "$@";; esac
}
dnsmasq() { '''+parser+''' "$@"; }
make_dns_config
''')
        self.assertEqual(r.returncode,0,r.stderr)
        old=subprocess.run([os.environ["AXDHCP_TEST_DNSMASQ"],"--test",f"--conf-file={self.run / 'dnsmasq.conf'}","--dhcp-option=option:server-identifier,10.0.0.7"],capture_output=True,text=True,timeout=10)
        self.assertNotEqual(old.returncode,0)
        self.assertIn("bad dhcp-option",old.stderr)

    def test_default_route_parses_tokens_without_device_filtered_output(self):
        routes=["default via 10.0.0.1 dev br0", "default via 10.0.0.1 proto dhcp dev br0 metric 10", "default dev br0 via 10.0.0.1", "0.0.0.0/0 via 10.0.0.1 dev br0"]
        for route in routes:
            with self.subTest(route=route):
                r=self.shell('''
cp "$CONF" "$RUN/config.valid"
BRIDGE=br0
ip() {
    [ "$*" = '-4 route show default' ] || exit 9
    printf '%s\\n' '''+shlex.quote(route)+'''
}
check_default_route
''')
                self.assertEqual(r.returncode,0,r.stderr)

    def test_default_route_mismatch_reports_actual_and_records_failure(self):
        routes=["", "default via 10.0.0.2 dev br0", "default via 10.0.0.1 dev eth7", "default via 10.0.0.1 dev br0 linkdown", "default via 10.0.0.1 dev br0\ndefault via 10.0.0.2 dev br0"]
        for route in routes:
            with self.subTest(route=route):
                r=self.shell('''
cp "$CONF" "$RUN/config.valid"
BRIDGE=br0; REPORT_ERRORS=1
ip() { printf '%s\\n' '''+shlex.quote(route)+'''; }
check_default_route
''')
                self.assertEqual(r.returncode,1,r.stderr)
                self.assertIn("expected gateway=10.0.0.1 interface=br0",r.stderr)
                self.assertIn("actual="+route,r.stderr)
                self.assertIn("Default route mismatch",(self.run / "last-error").read_text())
                self.assertFalse((self.run / "generation").exists())

    def test_default_route_uses_configured_gateway_not_home_network(self):
        self.config.write_text(EXAMPLE.replace("10.0.0.","192.168.50."))
        r=self.shell('''
cp "$CONF" "$RUN/config.valid"
BRIDGE=br0
ip() { printf 'default via 192.168.50.1 dev br0 proto dhcp\\n'; }
check_default_route
''')
        self.assertEqual(r.returncode,0,r.stderr)

    def test_autostart_requires_saved_enable_and_address_confirmations(self):
        ready={"enabled":"1","autostart":"1","pool_confirmed":"1","dns_confirmed":"1"}
        self.assertEqual(self.valid(ready).returncode,0)
        for key in ["enabled","pool_confirmed","dns_confirmed"]:
            self.assertNotEqual(self.valid({**ready,key:"0"}).returncode,0)

    def test_boot_disabled_never_checks_or_launches_network(self):
        r=self.shell('preflight() { exit 9; }\nlaunch() { exit 9; }\nboot\n')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertFalse((self.run / "generation").exists())
        self.assertFalse((self.run / "boot.pending").exists())
        self.assertIn("Boot startup invoked",(self.run / "control.log").read_text())
        self.assertIn("Boot startup skipped",(self.run / "control.log").read_text())

    def test_dead_boot_worker_reports_fault_instead_of_waiting_forever(self):
        (self.run / "boot.pending").write_text("99999999 123\n")
        (self.run / "state").write_text("starting\n")
        r=self.call("status")
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn("state=fault",r.stdout)
        self.assertIn("last_error=Boot startup worker exited",r.stdout)
        self.assertNotIn("boot_pending=1",r.stdout)

    def test_boot_waits_for_readiness_then_launches_continuous_once(self):
        self.valid({"enabled":"1","autostart":"1","pool_confirmed":"1","dns_confirmed":"1"})
        r=self.shell('''
identity() { printf '123\\n'; }
preflight() {
    count=$(cat "$RUN/attempts" 2>/dev/null || printf 0)
    count=$((count+1)); printf '%s\\n' "$count" > "$RUN/attempts"
    [ "$count" -ge 2 ] || die 'network not ready'
}
sleep() { :; }
launch() { printf '%s|%s\\n' "$LIFETIME" "$*" >> "$RUN/launched"; }
boot
''')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual((self.run / "attempts").read_text(),"2\n")
        self.assertEqual((self.run / "launched").read_text(),"continuous|dhcp --network-change-confirmed --unverified-paths-acknowledged\n")
        self.assertFalse((self.run / "boot.pending").exists())
        self.assertFalse((self.run / "lock").exists())

    def test_manual_stop_cancels_waiting_boot(self):
        self.valid({"enabled":"1","autostart":"1","pool_confirmed":"1","dns_confirmed":"1"})
        r=self.shell('''
preflight() { return 1; }
launch() { exit 9; }
sleep() { sh ''' + shlex.quote(str(BACKEND)) + ''' stop || exit 9; }
boot
''')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertFalse((self.run / "boot.pending").exists())
        self.assertEqual((self.run / "state").read_text(),"unverified\n")

    def test_boot_timeout_records_cause_without_starting_dhcp(self):
        self.valid({"enabled":"1","autostart":"1","pool_confirmed":"1","dns_confirmed":"1"})
        r=self.shell('''
preflight() { printf 'network not ready\\n'; return 1; }
launch() { exit 9; }
sleep() { :; }
boot
''')
        self.assertEqual(r.returncode,1,r.stderr)
        self.assertIn("Boot startup timed out: network not ready",(self.run / "last-error").read_text())
        self.assertEqual((self.run / "state").read_text(),"fault\n")
        self.assertFalse((self.run / "boot.pending").exists())
        self.assertFalse((self.run / "generation").exists())

    def test_reject_ipv4_and_pool_errors(self):
        cases = [
            {"pool_start":"10.0.0.020"}, {"pool_end":"10.0.0.256"},
            {"pool_start":"10.0.0.0"}, {"pool_end":"10.0.0.255"},
            {"pool_start":"10.0.0.251"}, {"pool_end":"10.0.1.250"},
            {"gateway":"10.0.0.210"}, {"gateway":"10.0.1.1"},
            {"gateway":"10.0.0.255"}, {"netmask":"255.0.255.0"},
            {"netmask":"255.255.255.255"}, {"dns":"127.0.0.1"},
            {"dns":"224.0.0.1"}, {"dns":"1.1.1.1,"},
            {"pool_start":"0.0.0.1"}, {"pool_start":"169.254.0.1"},
            {"pool_start":"224.0.0.201", "pool_end":"224.0.0.250", "gateway":"224.0.0.1"},
        ]
        for case in cases:
            with self.subTest(case=case):
                self.assertNotEqual(self.valid(case).returncode, 0)

    def test_live_bridge_ip_prefix_and_conflicts(self):
        self.assertEqual(self.valid(bridge_ip="10.0.0.7", prefix=24).returncode,0)
        for addr, prefix in [("10.0.0.201",24),("10.0.1.7",24),("10.0.0.1",24),("10.0.0.7",16)]:
            with self.subTest(addr=addr, prefix=prefix):
                self.assertNotEqual(self.valid(bridge_ip=addr,prefix=prefix).returncode,0)

    def test_shell_injection_unknown_duplicate_and_crlf(self):
        marker=self.root / "injected"
        for value in [f"$(touch {marker})", f"`touch {marker}`", "wl1.1;reboot", "wl1.1\nreboot", "wl1.1\r"]:
            with self.subTest(value=value):
                self.assertNotEqual(self.valid({"downstream":value}).returncode,0)
                self.assertFalse(marker.exists())
        self.assertNotEqual(self.valid(suffix="enabled=1\n").returncode,0)
        self.assertNotEqual(self.valid(suffix="unknown=1\n").returncode,0)

    def test_time_and_interface_gates(self):
        for changes in [{"lease_seconds":"119"},{"lease_seconds":"86401"},{"test_seconds":"301"},{"test_seconds":"29"},{"autostart":"1"},{"downstream":"eth7"},{"downstream":"eth6,eth7"},{"downstream":"wl1.1,wl1.1"},{"downstream":"eth6,"},{"downstream":""},{"bridge":"-br1"},{"bridge":"br0/../x"},{"enabled":"2"}]:
            with self.subTest(changes=changes):
                self.assertNotEqual(self.valid(changes).returncode,0)

    def test_save_is_atomic_and_has_no_network_actions(self):
        incoming=self.root / "incoming.conf"
        incoming.write_text(EXAMPLE.replace("lease_seconds=600","lease_seconds=1200"))
        result=self.call("save",incoming)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn("lease_seconds=1200",self.config.read_text())
        incoming.write_text("enabled=$(reboot)\n")
        before=self.config.read_text()
        self.assertNotEqual(self.call("save",incoming).returncode,0)
        self.assertEqual(self.config.read_text(),before)
        self.assertFalse(self.db.exists())
        self.assertFalse((self.run / "generation").exists())
        self.assertFalse((self.run / "lock").exists())

    def test_authorization_and_disabled_start_gate(self):
        self.assertNotEqual(self.call("test").returncode,0)
        r=self.call("test","--network-change-confirmed","--filter-paths-confirmed")
        self.assertNotEqual(r.returncode,0)
        self.assertIn("disabled",r.stderr)
        self.assertFalse(self.db.exists())

    def test_config_confirmations_required(self):
        self.valid({"enabled":"1"})
        r=self.call("test","--network-change-confirmed","--filter-paths-confirmed")
        self.assertIn("Confirm pool",r.stderr)
        self.assertFalse(self.db.exists())

    def test_rule_install_monitor_cleanup_preserves_foreign_rules(self):
        result=self.shell('''
eb -A INPUT -p ARP -j ACCEPT
eb -N FOREIGN
eb -A FORWARD -j FOREIGN
install_rules || exit 1
check_rules || exit 2
remove_rules || exit 3
remove_rules || exit 4
''')
        self.assertEqual(result.returncode,0,result.stderr)
        db=self.db_read()
        self.assertEqual(db["chains"]["INPUT"],[["-p","ARP","-j","ACCEPT"]])
        self.assertEqual(db["chains"]["FORWARD"],[["-j","FOREIGN"]])
        self.assertEqual(set(db["chains"]),{"INPUT","OUTPUT","FORWARD","FOREIGN"})

    def test_reject_existing_owned_name_without_altering_it(self):
        result=self.shell('eb -N AXDI\neb -A AXDI -p ARP -j DROP\ninstall_rules && exit 8\nremove_rules\n')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.db_read()["chains"]["AXDI"],[["-p","ARP","-j","DROP"]])

    def test_failure_at_each_filter_mutation_restores_parent_chains(self):
        # Three creations, five appends per interface, three tails, three hooks.
        for downstream, count in [("eth6",14),("wl1.1",14),("eth6,wl1.1",19)]:
            for nth in range(1,count+1):
                with self.subTest(downstream=downstream, mutation=nth):
                    self.db.unlink(missing_ok=True)
                    self.env["AXDHCP_MOCK_FAIL_AT"]=str(nth)
                    r=self.shell(f'DOWN={shlex.quote(downstream)}\ninstall_rules && exit 9\nremove_rules || exit 8\n')
                    self.assertEqual(r.returncode,0,r.stderr)
                    self.assertEqual(self.db_read()["chains"],{"INPUT":[],"FORWARD":[],"OUTPUT":[]})
        self.env.pop("AXDHCP_MOCK_FAIL_AT",None)

    def test_single_and_dual_band_configuration(self):
        for selected in ["eth6", "wl1.1", "eth6,wl1.1"]:
            with self.subTest(selected=selected):
                r=self.valid({"downstream":selected})
                self.assertEqual(r.returncode,0,r.stderr)
                self.assertIn(f"downstream={selected}\n",r.stdout)

    def test_selected_bands_have_exact_rules_and_exclude_backhaul(self):
        for selected in ["eth6", "wl1.1", "eth6,wl1.1"]:
            with self.subTest(selected=selected):
                self.db.unlink(missing_ok=True)
                r=self.shell(f'DOWN={shlex.quote(selected)}\ninstall_rules || exit 1\ncheck_rules || exit 2\n')
                self.assertEqual(r.returncode,0,r.stderr)
                chains=self.db_read()["chains"]
                interfaces=selected.split(",")
                self.assertEqual(chains["AXDI"],[["-i",i,"-j","RETURN"] for i in interfaces]+[["-j","DROP"]])
                self.assertEqual(chains["AXDO"],[["-o",i,"-j","RETURN"] for i in interfaces]+[["-j","DROP"]])
                expected=[]
                for i in interfaces:
                    for port,direction in [("--ip-dport","-i"),("--ip-sport","-o"),("--ip-sport","-i")]:
                        expected.append(["-p","IPv4","--ip-proto","udp",port,"67",direction,i,"-j","DROP"])
                self.assertEqual(chains["AXDF"],expected+[["-j","RETURN"]])
                self.assertNotIn("eth7",json.dumps(chains))

    def test_either_band_rule_loss_detected_in_dual_mode(self):
        for iface in ["eth6", "wl1.1"]:
            self.db.unlink(missing_ok=True)
            r=self.shell(f'DOWN=eth6,wl1.1\ninstall_rules || exit 1\neb -D AXDI -i {iface} -j RETURN\ncheck_rules && exit 2\nexit 0\n')
            self.assertEqual(r.returncode,0,r.stderr)

    def test_rule_loss_and_prior_accept_detected(self):
        for command in ['eb -D AXDF -p IPv4 --ip-proto udp --ip-dport 67 -i wl1.1 -j DROP', 'eb -I INPUT 1 -j ACCEPT']:
            with self.subTest(command=command):
                self.db.unlink(missing_ok=True)
                r=self.shell('install_rules || exit 1\n'+command+'\ncheck_rules && exit 2\nexit 0\n')
                self.assertEqual(r.returncode,0,r.stderr)

    def test_rollback_generation_guard(self):
        (self.run / "generation").write_text("new-123\n")
        (self.run / "state").write_text("testing\n")
        result=self.call("rollback","old-456")
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.run / "generation").read_text(),"new-123\n")
        self.assertFalse(self.db.exists())

    def test_stop_order_and_uncertain_identity_retains_filters(self):
        self.env["AXDHCP_REQUIRE_STOP_MARKER"]=str(self.run / "order")
        result=self.shell('''
install_rules || exit 1
stop_dns() { printf 'stopped\\n' >> "$RUN/order"; }
abort_transaction unverified || exit 2
''')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(set(self.db_read()["chains"]),{"INPUT","OUTPUT","FORWARD"})
        self.assertEqual((self.run / "order").read_text(),"stopped\n")
        self.db.unlink()
        self.env.pop("AXDHCP_REQUIRE_STOP_MARKER")
        r=self.shell('install_rules || exit 1\nstop_dns() { return 1; }\nabort_transaction fault && exit 9\nexit 0\n')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn("AXDI",self.db_read()["chains"])
        self.assertEqual((self.run / "state").read_text(),"fault\n")

    def test_watchdog_rule_fault_stops_service_before_cleanup(self):
        r=self.shell('''
install_rules || exit 1
printf 'test-gen\\n' > "$RUN/generation"
printf 'dhcp\\n' > "$RUN/mode"
printf 'snapshot\\n' > "$RUN/network.initial"
: > "$RUN/ready"
network_fingerprint() { printf 'snapshot\\n'; }
stop_dns() { printf 'stop:%s\\n' "$1" >> "$RUN/emergency"; }
owned_process() { return 0; }
eb -F AXDF
watch test-gen
''')
        self.assertNotEqual(r.returncode,0)
        self.assertIn("stop:test-gen",(self.run / "emergency").read_text())
        self.assertEqual((self.run / "state").read_text(),"fault\n")
        self.assertEqual(set(self.db_read()["chains"]),{"INPUT","OUTPUT","FORWARD"})

    def test_stale_dns_generation_is_not_killed(self):
        (self.run / "dns.identity").write_text("123 456 current-generation\n")
        r=self.shell('owned_process() { return 1; }\nidentity() { printf "456\\n"; }\nstop_dns old-generation\n')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertTrue((self.run / "dns.identity").exists())

    def test_missing_dns_identity_keeps_filters_fail_closed(self):
        r=self.shell('''
install_rules || exit 1
printf 'incomplete-gen\\n' > "$RUN/dns.launching"
abort_transaction unverified && exit 9
exit 0
''')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual((self.run / "state").read_text(),"fault\n")
        self.assertIn("AXDI",self.db_read()["chains"])

    def test_timer_expiry_restores_only_current_generation(self):
        r=self.shell('''
install_rules || exit 1
printf 'timer-gen\\n' > "$RUN/generation"
printf '1\\n' > "$RUN/deadline"
stop_dns() { printf 'stopped\\n' > "$RUN/expired"; }
awk() {
    case "$*" in *"/proc/uptime"*) printf '999\\n';; *) /usr/bin/awk "$@";; esac
}
timer timer-gen
''')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertTrue((self.run / "expired").exists())
        self.assertFalse((self.run / "generation").exists())
        self.assertEqual(set(self.db_read()["chains"]),{"INPUT","OUTPUT","FORWARD"})
        self.assertEqual((self.run / "state").read_text(),"unverified\n")

    def test_timer_with_busy_lock_stops_dhcp_retains_filters(self):
        r=self.shell('''
install_rules || exit 1
printf 'busy-gen\\n' > "$RUN/generation"
printf '1\\n' > "$RUN/deadline"
mkdir "$RUN/lock"
sleep() { :; }
stop_dns() { printf 'stop:%s\\n' "$1" > "$RUN/expired"; }
awk() {
    case "$*" in *"/proc/uptime"*) printf '999\\n';; *) /usr/bin/awk "$@";; esac
}
timer busy-gen
''')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual((self.run / "expired").read_text(),"stop:busy-gen\n")
        self.assertTrue((self.run / "fault.busy-gen").exists())
        self.assertIn("AXDI",self.db_read()["chains"])

    def test_old_timer_does_not_touch_new_transaction(self):
        (self.run / "generation").write_text("new-gen\n")
        r=self.shell('stop_dns() { [ "$1" = old-gen ] || exit 9; }\ntimer old-gen\n')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual((self.run / "generation").read_text(),"new-gen\n")
        self.assertFalse(self.db.exists())

    def test_timer_watchdog_exit_stops_service(self):
        r=self.shell('''
install_rules || exit 1
printf 'watch-exit-gen\\n' > "$RUN/generation"
: > "$RUN/ready"
stop_dns() { printf 'stop:%s\\n' "$1" >> "$RUN/supervisor"; }
owned_process() { return 1; }
timer watch-exit-gen
''')
        self.assertEqual(r.returncode,1,r.stderr)
        self.assertIn("stop:watch-exit-gen",(self.run / "supervisor").read_text())
        self.assertEqual((self.run / "state").read_text(),"fault\n")
        self.assertFalse((self.run / "generation").exists())
        self.assertEqual(set(self.db_read()["chains"]),{"INPUT","OUTPUT","FORWARD"})

    def test_continuous_supervisor_has_no_expiry_and_stop_restores_rules(self):
        r=self.shell('''
install_rules || exit 1
printf 'continuous-gen\\n' > "$RUN/generation"
printf 'continuous\\n' > "$RUN/lifetime"
printf 'continuous\\n' > "$RUN/deadline"
printf 'dhcp\\n' > "$RUN/mode"
printf 'running\\n' > "$RUN/state"
: > "$RUN/ready"
owned_process() { return 0; }
stop_dns() { printf 'stop:%s\\n' "$1" >> "$RUN/stops"; }
status > "$RUN/status.before"
# Advance multiple supervision iterations without waiting or touching packets.
ticks=0
sleep() {
    ticks=$((ticks+1))
    [ "$ticks" -lt 4 ] || abort_transaction unverified
}
timer continuous-gen
printf '%s\\n' "$ticks" > "$RUN/ticks"
''')
        self.assertEqual(r.returncode,0,r.stderr)
        before=(self.run / "status.before").read_text()
        self.assertIn("lifetime=continuous",before)
        self.assertNotIn("remaining_seconds",before)
        self.assertEqual((self.run / "ticks").read_text(),"4\n")
        self.assertFalse((self.run / "generation").exists())
        self.assertEqual(set(self.db_read()["chains"]),{"INPUT","OUTPUT","FORWARD"})

    def test_continuous_supervisor_still_stops_on_watchdog_exit(self):
        r=self.shell('''
install_rules || exit 1
printf 'continuous-fault\\n' > "$RUN/generation"
printf 'continuous\\n' > "$RUN/lifetime"
printf 'continuous\\n' > "$RUN/deadline"
: > "$RUN/ready"
owned_process() { return 1; }
stop_dns() { printf 'stop:%s\\n' "$1" >> "$RUN/stops"; }
timer continuous-fault
''')
        self.assertEqual(r.returncode,1,r.stderr)
        self.assertIn("stop:continuous-fault",(self.run / "stops").read_text())
        self.assertEqual((self.run / "state").read_text(),"fault\n")
        self.assertFalse((self.run / "generation").exists())
        self.assertEqual(set(self.db_read()["chains"]),{"INPUT","OUTPUT","FORWARD"})

    def test_disabled_adapter_and_software_center_install(self):
        r=subprocess.run(["sh",str(ROOT / "adapters/koolshare/axdhcp-api.sh")],capture_output=True,text=True)
        self.assertEqual(r.returncode,78)
        r=subprocess.run(["sh",str(ROOT / "install.sh")],capture_output=True,text=True)
        self.assertEqual(r.returncode,78)


if __name__ == "__main__":
    unittest.main()
