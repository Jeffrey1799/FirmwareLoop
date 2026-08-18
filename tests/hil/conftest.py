"""
HIL test harness core (FirmwareLoop).

Fixtures
--------
  lab_config : parsed lab config (lab/lab.yaml -> lab/lab.example.yaml -> env FW_LAB_CONFIG)
  dut        : device-under-test UART client
  scope      : measurement client (simulator or VISA-backed)
  psu        : power client (simulator or VISA-backed)
  evidence   : evidence writer (uart.log / measurements.json under FW_RUN_DIR)

Modes
-----
  simulator (default) : the DUT is the *real compiled artifact* from
      artifacts/build/firmware.elf run as a subprocess; "UART" is its
      stdio pipe. Lets the whole pipeline (build -> run -> assert -> evidence)
      be exercised without silicon. Skipped when the artifact is missing.
  serial : real COM port via pyserial (lab config dut.serial.port).
  none   : every hardware test is skipped with a clear reason.

Evidence (Spec 5.3/23): every interaction is appended to
  <FW_RUN_DIR>/uart.log and measurements to <FW_RUN_DIR>/measurements.json.
"""

from __future__ import annotations

import json
import os
import queue
import re
import subprocess
import sys
import threading
import time
import warnings

import pytest

try:
    import yaml
except ImportError:  # pragma: no cover
    yaml = None

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_ARTIFACT = os.path.join(REPO_ROOT, "artifacts", "build", "firmware.elf")


# --------------------------------------------------------------------------- config
def _load_lab_config() -> dict:
    candidates = [
        os.environ.get("FW_LAB_CONFIG"),
        os.path.join(REPO_ROOT, "lab", "lab.yaml"),
        os.path.join(REPO_ROOT, "lab", "lab.example.yaml"),
    ]
    for path in candidates:
        if path and os.path.isfile(path):
            try:
                if yaml is not None:
                    with open(path, "r", encoding="utf-8") as fh:
                        return yaml.safe_load(fh) or {}
                return json.load(open(path, encoding="utf-8"))  # fallback
            except Exception:
                continue
    return {}


def _run_dir() -> str:
    env = os.environ.get("FW_RUN_DIR")
    if env:
        return env
    return os.path.join(REPO_ROOT, "artifacts", "logs")


def _dut_gate(config: dict) -> str:
    """UART gate selection (GAP-005, v0.0.2):
      'agentic-hil'  - default real gate: pytest -> agentic_hil pytest plugin
                       -> policy/lease/audit (MCP-named service methods)
      'direct-serial' - DEBUG fallback only: pyserial straight to COM, bypasses
                       Agentic HIL policy. Default DISABLED; enabling emits
                       HARDWARE_GATE_BYPASSED.
      'simulator'    - compiled-artifact DUT (public CI / no hardware).
    """
    dut_cfg = (config.get("dut") or {}).get("uart") or {}
    gate = dut_cfg.get("gate", "simulator")
    if gate == "direct-serial":
        warnings.warn(
            "HARDWARE_GATE_BYPASSED: direct pyserial bypasses Agentic HIL "
            "policy/lease/audit (GAP-005). Debug fallback only - autonomous "
            "agents must use gate: agentic-hil.",
            RuntimeWarning,
            stacklevel=3,
        )
    return gate


def _dut_gate_configured(config: dict, gate: str) -> bool:
    dut_cfg = (config.get("dut") or {}).get("uart") or {}
    return dut_cfg.get("gate") == gate


# --------------------------------------------------------------------------- evidence
class Evidence:
    """Appends every interaction to run-local files (Spec 5.3 evidence)."""

    def __init__(self, run_dir: str):
        self.run_dir = run_dir
        os.makedirs(run_dir, exist_ok=True)
        self.uart_path = os.path.join(run_dir, "uart.log")
        self.meas_path = os.path.join(run_dir, "measurements.json")
        self._measurements: list[dict] = []

    def uart(self, direction: str, data: str) -> None:
        line = f"[{time.strftime('%H:%M:%S')}] {direction}: {data}"
        with open(self.uart_path, "a", encoding="utf-8") as fh:
            fh.write(line.rstrip("\r\n") + "\n")

    def measurement(self, payload: dict) -> None:
        payload = dict(payload)
        payload["timestamp"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        self._measurements.append(payload)
        with open(self.meas_path, "w", encoding="utf-8") as fh:
            json.dump(self._measurements, fh, indent=2, ensure_ascii=False)

    def read_measurements(self) -> list[dict]:
        if os.path.isfile(self.meas_path):
            try:
                with open(self.meas_path, encoding="utf-8") as fh:
                    return json.load(fh)
            except Exception:
                return []
        return []


@pytest.fixture(scope="session")
def lab_config() -> dict:
    return _load_lab_config()


@pytest.fixture(scope="session")
def evidence() -> Evidence:
    return Evidence(_run_dir())


# --------------------------------------------------------------------------- DUT
class SimulatedDut:
    """Runs the compiled firmware artifact and treats stdio as the UART."""

    def __init__(self, exe: str, evidence: Evidence):
        self.exe = exe
        self.evidence = evidence
        self.proc: subprocess.Popen | None = None
        self._lines: queue.Queue[str] = queue.Queue()
        self._reader: threading.Thread | None = None
        self._stop = threading.Event()

    def _spawn(self) -> None:
        self._stop.clear()
        self.proc = subprocess.Popen(
            [self.exe],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=1,
        )
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()

    def _read_loop(self) -> None:
        assert self.proc and self.proc.stdout
        for raw in iter(self.proc.stdout.readline, b""):
            text = raw.decode("utf-8", errors="replace").rstrip("\r\n")
            if text:
                self._lines.put(text)
                self.evidence.uart("RX", text)
        self._stop.set()

    def reset(self, timeout: float = 6.0) -> None:
        """Restart the DUT process (power-cycle equivalent); consumes no banner."""
        if self.proc is not None:
            self.proc.kill()
            self.proc.wait(timeout=5)
        self._spawn()

    def boot(self, timeout: float = 6.0) -> None:
        """Reset then wait for the boot banner (reset + expect, Spec §11)."""
        self.reset(timeout=timeout)
        assert self.expect("Bootloader v1.0", timeout=timeout)
        assert self.expect("Application started", timeout=timeout)

    def write(self, text: str) -> None:
        assert self.proc and self.proc.stdin
        self.evidence.uart("TX", text)
        self.proc.stdin.write((text + "\n").encode("utf-8"))
        self.proc.stdin.flush()

    def expect(self, pattern: str, timeout: float = 5.0) -> str | None:
        """Return the first line matching `pattern` (regex search)."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                line = self._lines.get(timeout=deadline - time.monotonic())
            except queue.Empty:
                break
            if re.search(pattern, line):
                return line
        return None

    def command(self, cmd: str, timeout: float = 5.0) -> str | None:
        """Send a CLI command and return the single-line reply."""
        self.write(cmd)
        deadline = time.monotonic() + timeout
        reply = None
        while time.monotonic() < deadline:
            try:
                line = self._lines.get(timeout=deadline - time.monotonic())
            except queue.Empty:
                break
            if line.startswith(("Bootloader ", "Application ")):
                continue  # boot remnants
            reply = line
            break
        return reply


class AgenticHilDut:
    """Real DUT over the Agentic HIL pytest plugin (GAP-005).

    Uses the official service dispatch: service.call("com_session_start", {...})
    with the authoritative overall_success() verdict (agentic_hil.tools).
    reset() drives reset_target first, THEN opens the UART session.
    """

    def __init__(self, service, evidence: Evidence, port_id: str):
        from agentic_hil.tools import overall_success  # runtime import (official)

        self.svc = service
        self._success = overall_success
        self.evidence = evidence
        self.port_id = port_id
        self._buf = ""

    # -- helpers ------------------------------------------------------------
    def _call(self, name: str, arguments: dict | None = None) -> dict:
        """Dispatch a tool by name; raise on structural failure."""
        result = self.svc.call(name, arguments or {})
        if not isinstance(result, dict):
            raise RuntimeError(f"{name} returned non-object result: {result!r}")
        if not self._success(result):
            summary = result.get("summary") or result.get("error_type") or str(result)
            raise RuntimeError(f"{name} failed (overall_success=false): {summary}")
        return result

    @staticmethod
    def _text(result) -> str:
        """Extract text from a tool result (dict / list / str / None)."""
        if result is None:
            return ""
        if isinstance(result, str):
            return result
        if isinstance(result, dict):
            for key in ("text", "output", "value"):
                if result.get(key) is not None:
                    return str(result[key])
            return str(result)
        if isinstance(result, (list, tuple)):
            parts = []
            for item in result:
                if isinstance(item, dict):
                    parts.append(AgenticHilDut._text(item))
                else:
                    parts.append(str(item))
            return " ".join(parts)
        return str(result)

    # -- DUT lifecycle ------------------------------------------------------
    def reset(self, timeout: float = 6.0) -> None:
        """Real reset (reset_target mode=run), then open the UART session."""
        self._call("reset_target", {"mode": "run"})
        self._call("com_session_start", {"port_id": self.port_id, "clear_buffer": True})

    def boot(self, timeout: float = 6.0) -> None:
        self.reset(timeout=timeout)
        assert self.expect("Bootloader v1.0", timeout=timeout)
        assert self.expect("Application started", timeout=timeout)

    def write(self, text: str) -> None:
        self.evidence.uart("TX", text)
        self._call("com_write", {"port_id": self.port_id, "text": text + "\r\n"})

    def _read_chunk(self, wait_s: float) -> str:
        result = self._call("com_read", {
            "port_id": self.port_id, "max_bytes": 4096, "wait_timeout_s": max(0.1, wait_s),
        })
        return self._text(result)

    def expect(self, pattern: str, timeout: float = 5.0) -> str | None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                chunk = self._read_chunk(min(2.0, deadline - time.monotonic()))
            except RuntimeError:
                chunk = ""
            if chunk:
                self.evidence.uart("RX", chunk)
                self._buf += chunk
            if re.search(pattern, self._buf):
                return pattern
            if time.monotonic() >= deadline:
                break
        return None

    def command(self, cmd: str, timeout: float = 5.0) -> str | None:
        self.write(cmd)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                chunk = self._read_chunk(min(2.0, deadline - time.monotonic()))
            except RuntimeError:
                chunk = ""
            if chunk:
                self.evidence.uart("RX", chunk)
                self._buf += chunk
                m = re.search(r"(JEDEC [0-9A-F ]+|PWM [0-9]+|ERR|[A-Za-z0-9 -]{2,})", self._buf)
                if m:
                    reply = m.group(0)
                    if not reply.startswith(("Bootloader ", "Application ")):
                        return reply
        return None


class SerialDut:
    """Real COM port via pyserial (port/baud from lab config)."""

    def __init__(self, port: str, baud: int, evidence: Evidence):
        import serial  # deferred import: hardware mode

        self.ser = serial.Serial(port, baud, timeout=1)
        self.evidence = evidence

    def reset(self, timeout: float = 6.0) -> None:
        self.ser.reset_input_buffer()
        self.ser.reset_output_buffer()

    def boot(self, timeout: float = 6.0) -> None:
        self.reset(timeout=timeout)
        assert self.expect("Bootloader v1.0", timeout=timeout)
        assert self.expect("Application started", timeout=timeout)

    def write(self, text: str) -> None:
        self.evidence.uart("TX", text)
        self.ser.write((text + "\r\n").encode("ascii", errors="replace"))

    def expect(self, pattern: str, timeout: float = 5.0) -> str | None:
        buf = b""
        deadline = time.monotonic() + timeout
        rx = re.compile(pattern.encode("ascii", errors="ignore"), re.IGNORECASE)
        while time.monotonic() < deadline:
            chunk = self.ser.read(64)
            if chunk:
                buf += chunk
                text = buf.decode("ascii", errors="replace")
                if rx.search(text):
                    self.evidence.uart("RX", text)
                    return text
        self.evidence.uart("RX", buf.decode("ascii", errors="replace"))
        return None

    def command(self, cmd: str, timeout: float = 5.0) -> str | None:
        self.write(cmd)
        deadline = time.monotonic() + timeout
        buf = b""
        while time.monotonic() < deadline:
            chunk = self.ser.read(64)
            if not chunk:
                continue
            buf += chunk
            text = buf.decode("ascii", errors="replace")
            for m in re.finditer(r"(JEDEC [0-9A-F ]+|PWM [0-9]+|ERR|[A-Za-z0-9 -]{2,})", text):
                cand = m.group(0)
                if cand.startswith(("Bootloader ", "Application ")):
                    continue
                self.evidence.uart("RX", cand)
                return cand
        self.evidence.uart("RX", buf.decode("ascii", errors="replace"))
        return None


@pytest.fixture(scope="session")
def dut(lab_config: dict, evidence: Evidence, request):
    """DUT UART client, gated (GAP-005):
    - gate: agentic-hil   -> AgenticHilDut (policy/lease/audit preserved)
    - gate: direct-serial -> SerialDut (debug fallback; bypass warns)
    - default (simulator) -> SimulatedDut (compiled artifact, no hardware)
    """
    gate = _dut_gate(lab_config)

    if gate == "agentic-hil":
        try:
            from agentic_hil.tools import AgenticHILToolService  # noqa: F401
        except ImportError:
            pytest.skip("agentic_hil pytest plugin not installed; cannot use gate: agentic-hil")
        service = request.getfixturevalue("agentic_hil")
        port_id = ((lab_config.get("dut") or {}).get("uart") or {}).get("port_id", "dut_uart")
        return AgenticHilDut(service, evidence, port_id)

    if gate == "direct-serial":
        cfg = (lab_config.get("dut") or {}).get("uart") or {}
        try:
            return SerialDut(cfg["port"], int(cfg.get("baud", 115200)), evidence)
        except Exception as exc:  # noqa: BLE001
            pytest.skip(f"serial DUT unavailable: {exc}")

    if not os.path.isfile(DEFAULT_ARTIFACT):
        pytest.skip(
            f"no firmware artifact at {DEFAULT_ARTIFACT}; run tools/build.ps1 first"
        )
    return SimulatedDut(DEFAULT_ARTIFACT, evidence)


# --------------------------------------------------------------------------- instruments
class SimScope:
    """Simulated measurements modelled on the demo firmware signals."""

    def __init__(self, evidence: Evidence):
        self.evidence = evidence

    def _measure(self, name: str, channel: str, value: float, unit: str) -> float:
        self.evidence.measurement(
            {
                "schema": "lab-measurement/v1",
                "ok": True,
                "instrument": "scope1",
                "measurement": name,
                "channel": channel,
                "value": value,
                "unit": unit,
            }
        )
        return value

    def measure_frequency(self, channel: str = "CH1") -> float:
        return self._measure("frequency", channel, 20000.0, "Hz")

    def measure_vpp(self, channel: str = "CH1") -> float:
        return self._measure("vpp", channel, 3.30, "V")

    def measure_duty(self, channel: str = "CH1") -> float:
        return self._measure("duty", channel, 50.0, "%")

    def measure_rms(self, channel: str = "CH1") -> float:
        return self._measure("rms", channel, 1.65, "V")

    def measure_rise_time(self, channel: str = "CH1") -> float:
        return self._measure("rise_time", channel, 5.0e-9, "s")


class SimPsu:
    def __init__(self, evidence: Evidence):
        self.evidence = evidence

    def _measure(self, name: str, value: float, unit: str) -> float:
        self.evidence.measurement(
            {
                "schema": "lab-measurement/v1",
                "ok": True,
                "instrument": "psu1",
                "measurement": name,
                "channel": "OUT1",
                "value": value,
                "unit": unit,
            }
        )
        return value

    def measure_voltage(self) -> float:
        return self._measure("voltage", 3.3, "V")

    def measure_current(self) -> float:
        return self._measure("current", 0.035, "A")

    def measure_power(self) -> float:
        return self._measure("power", 0.1155, "W")


class VisaMeasurements:
    """Real measurements over tools/lib/instruments.py (GAP-006).

    A configured visa backend FAILS tests when the instrument is unreachable -
    never pytest.skip(), never synthetic data (GAP-007)."""

    def __init__(self, inst_cfg: dict, evidence: Evidence):
        sys.path.insert(0, os.path.join(REPO_ROOT, "tools", "lib"))
        from tools.lib import instruments  # deferred: only for real backends

        self._instruments = instruments
        self.inst_cfg = inst_cfg
        self.evidence = evidence
        self.client = instruments.open_instrument(inst_cfg, timeout_ms=int(inst_cfg.get("timeout_ms", 5000)))

    def _measure(self, name: str, channel: str, scpi: str, unit: str) -> float:
        val = self._instruments.query_measurement(self.client, scpi.format(ch=channel))
        self.evidence.measurement({
            "schema": "lab-measurement/v1", "ok": True,
            "instrument": self.inst_cfg.get("name", "scope1"),
            "measurement": name, "channel": channel, "value": val, "unit": unit,
            "execution_mode": "real", "simulated": False, "hardware_validated": True,
        })
        return val

    def _cmd(self, key: str, default: str) -> str:
        cmds = self.inst_cfg.get("commands") or {}
        return cmds.get(key, default)

    def measure_frequency(self, channel: str = "CH1") -> float:
        return self._measure("frequency", channel, self._cmd("measure_frequency", ":MEASure:FREQuency? {ch}"), "Hz")

    def measure_vpp(self, channel: str = "CH1") -> float:
        return self._measure("vpp", channel, self._cmd("measure_vpp", ":MEASure:VPP? {ch}"), "V")

    def measure_duty(self, channel: str = "CH1") -> float:
        return self._measure("duty", channel, self._cmd("measure_duty", ":MEASure:PDUTy? {ch}"), "%")

    def measure_rms(self, channel: str = "CH1") -> float:
        return self._measure("rms", channel, self._cmd("measure_rms", ":MEASure:VRMS? {ch}"), "V")

    def measure_rise_time(self, channel: str = "CH1") -> float:
        return self._measure("rise_time", channel, self._cmd("measure_rise_time", ":MEASure:RTIMe? {ch}"), "s")

    def measure_voltage(self) -> float:
        return self._measure("voltage", "OUT1", self._cmd("measure_voltage", "MEAS:VOLT?"), "V")

    def measure_current(self) -> float:
        return self._measure("current", "OUT1", self._cmd("measure_current", "MEAS:CURR?"), "A")

    def measure_power(self) -> float:
        return self._measure("power", "OUT1", self._cmd("measure_power", "MEAS:POW?"), "W")


@pytest.fixture(scope="session")
def scope(evidence: Evidence, lab_config: dict):
    inst_cfg = (lab_config.get("instruments") or {}).get("scope1") or {}
    if inst_cfg.get("backend") == "visa":
        return VisaMeasurements(inst_cfg, evidence)
    return SimScope(evidence)


@pytest.fixture(scope="session")
def psu(evidence: Evidence, lab_config: dict):
    inst_cfg = (lab_config.get("instruments") or {}).get("psu1") or {}
    if inst_cfg.get("backend") == "visa":
        return VisaMeasurements(inst_cfg, evidence)
    return SimPsu(evidence)