"""GAP-009 safety policy tests: authoritative limits live OUTSIDE the
workspace; workspace edits must never escalate privileges (tamper test);
real hardware writes fail closed without a trusted policy."""

import json
import os
import subprocess
import sys

import pytest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CLI = os.path.join(REPO_ROOT, "tools", "instrument_cli.py")
PYTHON = sys.executable


def _run_cli(env: dict, *args: str) -> dict:
    full_env = dict(os.environ)
    full_env.pop("FIRMWARELOOP_BENCH_CONFIG", None)
    full_env.pop("FIRMWARELOOP_BENCH_ID", None)
    full_env.update(env)
    r = subprocess.run(
        [PYTHON, CLI, *args],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
        env=full_env, cwd=REPO_ROOT, timeout=60,
    )
    for line in reversed(r.stdout.strip().splitlines()):
        if line.strip().startswith("{"):
            return json.loads(line)
    raise AssertionError(f"no JSON from CLI: {r.stdout} {r.stderr}")


@pytest.fixture()
def trusted_limits(tmp_path):
    """A bench policy living outside the workspace: max 5 V / 1 A."""
    bench = tmp_path / "bench-dev-01"
    bench.mkdir()
    policy = bench / "limits.yaml"
    policy.write_text(
        "power:\n"
        "  psu1:\n"
        "    max_voltage_v: 5.0\n"
        "    max_current_a: 1.0\n"
        "    allow_output_toggle: true\n"
        "relay:\n"
        "  allowed:\n"
        "    - DUT_POWER\n",
        encoding="utf-8",
    )
    return str(bench)


def test_write_without_authoritative_config_fails_closed():
    """No trusted policy + write => CONFIG_ERROR (never example fallback)."""
    payload = _run_cli({}, "psu", "output", "--instrument", "psu1", "--state", "on")
    assert payload["ok"] is False
    assert payload["error_class"] == "CONFIG_ERROR"
    assert "authoritative" in payload["error"]


def test_write_respects_trusted_limit(trusted_limits):
    """Request 12 V against a trusted 5 V policy => SAFETY_LIMIT."""
    payload = _run_cli(
        {"FIRMWARELOOP_BENCH_CONFIG": trusted_limits},
        "psu", "output", "--instrument", "psu1", "--state", "on",
        "--voltage", "12", "--current", "0.2",
    )
    assert payload["ok"] is False
    assert payload["error_class"] == "SAFETY_LIMIT", payload
    assert "5.0" in payload["error"]


def test_tamper_repo_example_does_not_escalate(trusted_limits, monkeypatch):
    """Workspace edit to limits.example.yaml (50 V) must NOT change the
    outcome: the trusted 5 V policy still rejects a 12 V request."""
    example = os.path.join(REPO_ROOT, "lab", "limits.example.yaml")
    original = open(example, encoding="utf-8").read()
    try:
        with open(example, "w", encoding="utf-8") as fh:
            fh.write("power:\n  psu1:\n    max_voltage_v: 50.0\n    max_current_a: 10.0\n"
                     "    allow_output_toggle: true\n")
        payload = _run_cli(
            {"FIRMWARELOOP_BENCH_CONFIG": trusted_limits},
            "psu", "output", "--instrument", "psu1", "--state", "on",
            "--voltage", "12",
        )
    finally:
        with open(example, "w", encoding="utf-8") as fh:
            fh.write(original)
    assert payload["ok"] is False
    assert payload["error_class"] == "SAFETY_LIMIT", payload


def test_read_measurement_ok_without_authoritative():
    """Reads may use the example fallback (no write risk)."""
    payload = _run_cli({}, "psu", "measure-current", "--instrument", "psu1")
    assert payload["ok"] is True
    assert payload["simulated"] is True
    assert payload["hardware_validated"] is False


def test_relay_whitelist_from_trusted_policy(trusted_limits):
    """Relay name must be in the TRUSTED whitelist, not the repo example."""
    payload = _run_cli(
        {"FIRMWARELOOP_BENCH_CONFIG": trusted_limits},
        "relay", "--instrument", "relay1", "--name", "SENSOR_OPEN", "--state", "on",
    )
    # SENSOR_OPEN is in the repo example but NOT in the trusted bench policy
    assert payload["ok"] is False
    assert payload["error_class"] == "SAFETY_LIMIT", payload