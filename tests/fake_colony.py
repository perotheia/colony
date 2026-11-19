#!/usr/bin/env python3
"""A fake `bin/colony`: prints a recorded ansible-playbook log line by line with small sleeps.

$FAKE_COLONY_LOG   the recorded log (SECRETS_FILE / SECRET_VALUE are replaced by the secrets file path and
                   the vpn_authkey read from it, as a careless task would echo them)
$FAKE_COLONY_DELAY seconds between lines (default 0.03)
$FAKE_COLONY_RC    exit code (default 0)
$FAKE_COLONY_SEEN  optional: append the secrets file path (+ whether it existed) here
"""
import json
import os
import sys
import time

sec_path = os.environ.get("COLONY_SECRETS_FILE", "")
secret = ""
if sec_path and os.path.isfile(sec_path):
    with open(sec_path) as f:
        secret = json.load(f).get("vpn_authkey", "")
seen = os.environ.get("FAKE_COLONY_SEEN")
if seen:
    with open(seen, "a") as f:
        f.write(f"{sec_path} {os.path.isfile(sec_path) if sec_path else False} {' '.join(sys.argv[1:])}\n")
delay = float(os.environ.get("FAKE_COLONY_DELAY", "0.03"))
with open(os.environ["FAKE_COLONY_LOG"]) as f:
    for line in f:
        line = line.replace("SECRETS_FILE", sec_path or "-").replace("SECRET_VALUE", secret or "-")
        sys.stdout.write(line)
        sys.stdout.flush()
        time.sleep(delay)
sys.exit(int(os.environ.get("FAKE_COLONY_RC", "0")))
