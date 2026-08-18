"""Logic analyzer integration tests (Spec M4). Uses the sigrok-fallback /
simulator pipeline: tools/logic_capture.ps1 -> tools/logic_decode.ps1.

SPI  : command 0x9F must decode to a 3-byte response 0xEF 0x40 0x18.
UART : the demodulated payload must read "HIL" (8N1, 115200).

These run without Saleae hardware - the simulator backend generates a
deterministic waveform; the same scripts drive a real sigrok capture when
nodes are configured in lab/protocol-decode.yaml.
"""

import json
import os
import subprocess

import pytest

from conftest import REPO_ROOT, Evidence

TOOLS = os.path.join(REPO_ROOT, "tools")
PS = "pwsh"
USING_PS = None


def _run_ps(script: str, args: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(
        [PS, "-NoProfile", "-NonInteractive", "-File", os.path.join(TOOLS, script)] + args,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=120,
    )


def _last_json(text: str) -> dict:
    for line in reversed(text.strip().splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    raise AssertionError(f"no JSON object found in output: {text[:400]}")


def _ps_available() -> bool:
    global USING_PS
    if USING_PS is None:
        try:
            r = subprocess.run([PS, "-NoProfile", "-Command", "$PSVersionTable.PSVersion.ToString()"],
                               capture_output=True, text=True, timeout=30)
            USING_PS = r.returncode == 0
        except Exception:  # noqa: BLE001
            USING_PS = False
    return USING_PS


@pytest.fixture(scope="module")
def capture_dir(evidence: Evidence):
    """Run a capture + decode, return the capture directory."""
    if not _ps_available():
        pytest.skip("PowerShell not available; cannot run logic pipeline")
    os.makedirs(evidence.run_dir, exist_ok=True)
    cap_dir = os.path.join(evidence.run_dir, "captures")
    os.makedirs(cap_dir, exist_ok=True)

    r = _run_ps("logic_capture.ps1", ["-Protocol", "spi", "-Json"])
    payload = _last_json(r.stdout)
    assert payload.get("ok") is True, payload
    return os.path.dirname(payload["capture"])


def test_spi_jedec_decode(capture_dir, evidence: Evidence):
    """Decode the captured SPI transaction and assert the JEDEC response."""
    r = _run_ps("logic_decode.ps1", ["-Capture", capture_dir, "-Json"])
    payload = _last_json(r.stdout)
    assert payload.get("ok") is True, payload
    assert payload["protocol"] == "spi"
    # Spec §19 example: response bytes == 0xEF 0x40 0x18
    frames = payload["frames"]
    resp = [f for f in frames if f["type"] == "response"]
    assert len(resp) == 1, f"expected one response frame, got {frames}"
    assert resp[0]["bytes_hex"].replace(" ", "") == "0xEF0x400x18", resp[0]
    evidence.uart("LOGIC", f"SPI decode response: {resp[0]['bytes_hex']}")


def test_spi_jedec_assert(capture_dir):
    """The decode tool itself supports assertion (-Expect) - red-team check that
    a WRONG expectation is rejected with TEST_FAILED (evidence, not exit code)."""
    r = _run_ps("logic_decode.ps1", ["-Capture", capture_dir, "-Expect", "DEADBEEF", "-ExpectKind", "hex", "-Json"])
    payload = _last_json(r.stdout)
    assert payload.get("error_class") == "TEST_FAILED", payload
    assert payload.get("actual") == "9FEF4018", payload


def test_uart_payload_decode(evidence: Evidence):
    """UART capture decodes to the ASCII payload 'HIL' (115200 8N1)."""
    if not _ps_available():
        pytest.skip("PowerShell not available; cannot run logic pipeline")
    r = _run_ps("logic_capture.ps1", ["-Protocol", "uart", "-Json"])
    payload = _last_json(r.stdout)
    assert payload.get("ok") is True, payload
    d = _run_ps("logic_decode.ps1", ["-Capture", os.path.dirname(payload["capture"]), "-Json"])
    decoded = _last_json(d.stdout)
    assert decoded.get("ok") is True, decoded
    assert decoded["text"] == "HIL", decoded
    evidence.uart("LOGIC", f"UART decode payload: {decoded['text']}")