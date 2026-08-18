"""Validate test plans against the authoritative Agentic HIL test schema
(GAP-004). Guards the logical-only rule: no COM ports / probe serials /
absolute machine paths in committed plans."""

import json
import os
import re
import subprocess
import sys

import pytest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
AGENTIC_HIL = os.path.join(REPO_ROOT, ".venv", "Scripts", "agentic-hil.exe")
PLANS = ["test-plans/real-smoke.yaml", "test-plans/smoke.yaml", "test-plans/regression.yaml"]


@pytest.fixture(scope="module")
def schema() -> dict:
    if not os.path.isfile(AGENTIC_HIL):
        pytest.skip("agentic-hil not installed; cannot validate against authoritative schema")
    r = subprocess.run([AGENTIC_HIL, "test-schema"], capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=60)
    assert r.returncode == 0, r.stderr
    # schema output ends with a trailing {"ok": true}
    return json.loads(r.stdout[: r.stdout.rfind("\n{")])


def test_real_smoke_matches_authoritative_schema(schema):
    import jsonschema
    import yaml

    plan = yaml.safe_load(open(os.path.join(REPO_ROOT, "test-plans", "real-smoke.yaml"), encoding="utf-8"))
    jsonschema.validate(plan, schema)  # raises on mismatch


def test_plans_contain_no_machine_specifics():
    """Logical-only rule (GAP-004): plans must not embed physical identifiers."""
    forbidden = re.compile(r"(COM\d+|probe[_ ]?serial|(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)|[A-Za-z]:\\\\|/home/|/Users/)", re.IGNORECASE)
    for rel in PLANS:
        path = os.path.join(REPO_ROOT, rel)
        if not os.path.isfile(path):
            continue
        # strip comment lines: the logical-only rule applies to the PLAN body
        lines = [ln for ln in open(path, encoding="utf-8").read().splitlines() if not ln.strip().startswith("#")]
        text = "\n".join(lines)
        m = forbidden.search(text)
        assert m is None, f"{rel} contains machine-specific value: {m.group(0)}"


def test_plan_device_names_are_logical():
    import yaml

    plan = yaml.safe_load(open(os.path.join(REPO_ROOT, "test-plans", "real-smoke.yaml"), encoding="utf-8"))
    devices = {s.get("device") for s in plan["steps"] if s.get("device")}
    assert devices <= {"dut", "dut_uart"}, f"unexpected physical device names: {devices}"