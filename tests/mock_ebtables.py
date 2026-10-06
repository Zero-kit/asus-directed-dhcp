#!/usr/bin/env python3
"""No networking: a rule-store simulator with deterministic mutation failures."""
import json
import os
import sys
from pathlib import Path

path = Path(os.environ["AXDHCP_MOCK_STATE"])
db = json.loads(path.read_text()) if path.exists() else {
    "chains": {"INPUT": [], "FORWARD": [], "OUTPUT": []}, "journal": [], "mutations": 0
}
args = sys.argv[1:]
if args[:2] != ["-t", "filter"]:
    sys.exit(2)
args = args[2:]
op, chain = args[:2]
rest = args[2:]
mutation = op in ("-N", "-X", "-A", "-I", "-D", "-F")
if op in ("-X", "-D", "-F") and os.environ.get("AXDHCP_REQUIRE_STOP_MARKER"):
    if not Path(os.environ["AXDHCP_REQUIRE_STOP_MARKER"]).exists():
        raise AssertionError("Filters removed before DHCP was stopped")
db["journal"].append(args)
if mutation:
    db["mutations"] += 1
    if db["mutations"] == int(os.environ.get("AXDHCP_MOCK_FAIL_AT", "-1")):
        path.write_text(json.dumps(db))
        sys.exit(1)
chains = db["chains"]
code = 0
if op == "-N":
    if chain in chains:
        code = 1
    else:
        chains[chain] = []
elif chain not in chains:
    code = 1
elif op == "-L":
    if "--Lx" in rest:
        print(f"ebtables -t filter -N {chain}")
        for rule in chains[chain]:
            print(f"ebtables -t filter -A {chain} " + " ".join(rule))
    else:
        print(f"Bridge chain: {chain}, entries: {len(chains[chain])}")
elif op == "-A":
    chains[chain].append(rest)
elif op == "-I":
    if rest[0] != "1":
        code = 2
    else:
        chains[chain].insert(0, rest[1:])
elif op == "-D":
    try:
        chains[chain].remove(rest)
    except ValueError:
        code = 1
elif op == "-F":
    if chain in ("INPUT", "FORWARD", "OUTPUT"):
        raise AssertionError("Global flush is forbidden")
    chains[chain] = []
elif op == "-X":
    references = any("-j" in rule and rule[rule.index("-j")+1] == chain for rows in chains.values() for rule in rows)
    if chains[chain] or references:
        code = 1
    else:
        del chains[chain]
else:
    code = 2
path.write_text(json.dumps(db))
sys.exit(code)
