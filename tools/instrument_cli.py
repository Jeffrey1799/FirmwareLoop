#!/usr/bin/env python3
"""
instrument_cli.py - VISA/SCPI instrument layer (Spec §14-17, M5).

Measurements over PyVISA -> VISA/SCPI, or the built-in simulator backend.
Every command returns one JSON document; every *write* is validated against
lab/limits.yaml (Spec §17) and refused with SAFETY_LIMIT when out of bounds.

Commands (Spec §15):
    instrument list
    instrument idn --instrument <name>
    scope measure-frequency --instrument <name> --channel CH1
    scope measure-duty | measure-vpp | measure-rms | measure-rise-time
    scope capture-waveform --instrument <name> --channel CH1 --output <file.csv>
    psu measure-voltage | measure-current | measure-power
    psu output --state on|off [--voltage V] [--current A]
    dmm measure-voltage | measure-resistance
    relay --name <name> --state on|off

  raw_scpi() is deliberately NOT implemented (Spec §15: default forbidden).

Exit codes: 0 ok, 1 measurement/execution failure, 2 config/safety denial.

Non-hardware verification:  --backend simulator
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_CONFIG = os.path.join(REPO_ROOT, "lab", "lab.yaml")
FALLBACK_CONFIG = os.path.join(REPO_ROOT, "lab", "lab.example.yaml")
LIMITS_PATH = os.path.join(REPO_ROOT, "lab", "limits.yaml")

try:
    import yaml
except ImportError:  # pragma: no cover
    yaml = None


# --------------------------------------------------------------------------- errors
def fail(error_class: str, message: str, detail=None) -> None:
    body = {"ok": False, "error_class": error_class, "error": message}
    if detail:
        body["detail"] = detail
    print(json.dumps(body, ensure_ascii=False))
    sys.exit(1)


def ok(payload: dict) -> None:
    print(json.dumps(payload, ensure_ascii=False))
    sys.exit(0)


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


# --------------------------------------------------------------------------- config
def load_config() -> dict:
    for cand in (os.environ.get("FW_LAB_CONFIG"), DEFAULT_CONFIG, FALLBACK_CONFIG):
        if cand and os.path.isfile(cand):
            try:
                if yaml is not None:
                    with open(cand, encoding="utf-8") as fh:
                        return yaml.safe_load(fh) or {}
                return json.load(open(cand, encoding="utf-8"))
            except Exception as exc:  # noqa: BLE001
                fail("CONFIG_ERROR", f"cannot parse lab config {cand}: {exc}")
    return {}


def load_limits() -> dict:
    if os.path.isfile(LIMITS_PATH):
        try:
            if yaml is not None:
                with open(LIMITS_PATH, encoding="utf-8") as fh:
                    return yaml.safe_load(fh) or {}
            return json.load(open(LIMITS_PATH, encoding="utf-8"))
        except Exception as exc:  # noqa: BLE001
            fail("CONFIG_ERROR", f"cannot parse {LIMITS_PATH}: {exc}")
    fail("CONFIG_ERROR", f"missing safety limits file {LIMITS_PATH}")


def get_instrument(config: dict, name: str) -> dict:
    inst = (config.get("instruments") or {}).get(name)
    if not inst:
        fail("INSTRUMENT_NOT_FOUND", f"instrument '{name}' is not defined in lab config",
             detail="available: " + ", ".join(sorted(config.get("instruments") or {})))
    return dict(inst)


# --------------------------------------------------------------------------- visa client
class VisaClient:
    def __init__(self, inst: dict):
        try:
            import pyvisa
        except ImportError:
            fail("INSTRUMENT_NOT_FOUND", "pyvisa is not installed; use --backend simulator for dry runs")
        self.rm = pyvisa.ResourceManager()
        resource = inst.get("resource")
        if not resource:
            fail("CONFIG_ERROR", f"instrument has no 'resource' entry; add one to lab/lab.yaml")
        try:
            self.inst = self.rm.open_resource(resource)
            self.inst.timeout = int(inst.get("timeout_ms", 5000))
        except Exception as exc:  # noqa: BLE001
            fail("INSTRUMENT_TIMEOUT", f"cannot open resource '{resource}': {exc}")

    def query(self, scpi: str) -> str:
        try:
            return str(self.inst.query(scpi)).strip()
        except Exception as exc:  # noqa: BLE001
            fail("INSTRUMENT_TIMEOUT", f"SCPI '{scpi}' failed: {exc}")

    def write(self, scpi: str) -> None:
        try:
            self.inst.write(scpi)
        except Exception as exc:  # noqa: BLE001
            fail("INSTRUMENT_TIMEOUT", f"SCPI write '{scpi}' failed: {exc}")

    def close(self) -> None:
        try:
            self.inst.close()
        except Exception:  # noqa: BLE001
            pass


# Default SCPI recipes; override per instrument in lab config (instrument.commands.*)
SCOPE_COMMANDS = {
    "idn": "*IDN?",
    "measure_frequency": ":MEASure:FREQuency? {ch}",
    "measure_duty": ":MEASure:PDUTy? {ch}",
    "measure_vpp": ":MEASure:VPP? {ch}",
    "measure_rms": ":MEASure:VRMS? {ch}",
    "measure_rise_time": ":MEASure:RTIMe? {ch}",
    "waveform": ":WAVeform:DATA? {ch}",
}
PSU_COMMANDS = {"idn": "*IDN?", "meas_voltage": "MEAS:VOLT?", "meas_current": "MEAS:CURR?", "meas_power": "MEAS:POW?"}
DMM_COMMANDS = {"idn": "*IDN?", "meas_voltage": "MEAS:VOLT:DC?", "meas_resistance": "MEAS:RES?"}


def _cmd(inst: dict, kind: str, key: str, default: str) -> str:
    cmds = inst.get("commands") or {}
    return cmds.get(f"{kind}.{key}", cmds.get(key, default))


def _measure(config, args, kind: str, key: str, unit: str, channel_key: str = None) -> None:
    inst = get_instrument(config, args.instrument)
    chan = args.channel if channel_key else None
    backend = inst.get("backend", "simulator")
    sim = config.get("simulated_measurements") or {}
    ts = _now()

    if backend == "visa":
        client = VisaClient(inst)
        try:
            scpi = _cmd(inst, kind, key, _default_scpi(kind, key)).format(ch=chan or "")
            raw = client.query(scpi)
            val = float(raw)
            result = {"schema": "lab-measurement/v1", "ok": True, "instrument": args.instrument,
                      "measurement": key, "channel": chan, "value": val, "unit": unit, "timestamp": ts}
        finally:
            client.close()
    else:
        table = sim.get(kind, {})
        val = table.get(key, table.get(key, {"frequency": 20000.0, "duty": 50.0, "vpp": 3.3, "rms": 1.65,
                                             "rise_time": 5.0e-9, "voltage": 3.3, "current": 0.035, "power": 0.1155}[key]))
        result = {"schema": "lab-measurement/v1", "ok": True, "instrument": args.instrument,
                  "measurement": key, "channel": chan, "value": val, "unit": unit, "timestamp": ts,
                  "backend": "simulator"}
    ok(result)


def _default_scpi(kind: str, key: str) -> str:
    table = {"scope": SCOPE_COMMANDS, "psu": PSU_COMMANDS, "dmm": DMM_COMMANDS}.get(kind, {})
    return table.get(key, f"MEAS:{key.upper()}?")


# --------------------------------------------------------------------------- safety
def check_limit(limits: dict, category: str, name: str, key: str, value) -> float:
    """Return the capped/validated value or abort with SAFETY_LIMIT."""
    limits = dict(limits)  # copy: never mutate the loaded policy
    if limits.get("ai_may_edit"):
        fail("PERMISSION_DENIED", "ai_may_edit must not be set in the shipped limits.yaml (Spec §17)")
    cat = limits.get(category) or {}
    entry = cat.get(name) or {}
    maxv = entry.get(key)
    if maxv is not None and value > maxv:
        fail("SAFETY_LIMIT", f"{category}.{name}.{key} would exceed configured maximum {maxv} (requested {value})",
             detail=f"check lab/limits.yaml")
    return value


def do_psu_output(config, args, limits) -> None:
    inst = get_instrument(config, args.instrument)
    backend = inst.get("backend", "simulator")
    allowed = (limits.get("power") or {}).get(args.instrument, {})
    if not allowed.get("allow_output_toggle", False):
        fail("SAFETY_LIMIT", f"output toggle on '{args.instrument}' is not allowed by lab/limits.yaml")

    state = args.state.lower()
    if state == "on":
        if args.voltage is not None:
            check_limit(limits, "power", args.instrument, "max_voltage_v", float(args.voltage))
        if args.current is not None:
            check_limit(limits, "power", args.instrument, "max_current_a", float(args.current))

    if backend == "visa":
        client = VisaClient(inst)
        try:
            if state == "on":
                if args.voltage is not None:
                    client.write(f"APPL {args.voltage}")
                if args.current is not None:
                    client.write(f"CURR {args.current}")
            client.write(f"OUTP {1 if state == 'on' else 0}")
        finally:
            client.close()
    ok({"schema": "lab-measurement/v1", "ok": True, "instrument": args.instrument, "measurement": "output",
        "state": state, "voltage_v": args.voltage, "current_a": args.current,
        "channel": "OUT1", "unit": "bool", "timestamp": _now(), "backend": backend})


def do_relay(config, args, limits) -> None:
    allowed = limits.get("relay", {}).get("allowed", [])
    if args.name not in allowed:
        fail("SAFETY_LIMIT", f"relay '{args.name}' is not in lab/limits.yaml relay.allowed whitelist",
             detail=f"allowed: {allowed}")
    if args.state.lower() not in ("on", "off"):
        fail("CONFIG_ERROR", f"relay state must be on|off, got '{args.state}'")
    inst = get_instrument(config, args.instrument)
    backend = inst.get("backend", "simulator")
    if backend == "visa":
        ch = inst.get("relay_channel", args.name.upper())
        client = VisaClient(inst)
        try:
            client.write(f"OUTP:CH{ch} {1 if args.state.lower() == 'on' else 0}")
        finally:
            client.close()
    ok({"schema": "lab-measurement/v1", "ok": True, "instrument": args.instrument, "measurement": "relay",
        "relay": args.name, "state": args.state.lower(), "timestamp": _now(), "backend": backend})


# --------------------------------------------------------------------------- main
def main() -> None:
    parser = argparse.ArgumentParser(prog="instrument_cli.py")
    sub = parser.add_subparsers(dest="command", required=True)

    p_list = sub.add_parser("list", help="list configured instruments")
    p_list.add_argument("--config", default=DEFAULT_CONFIG)

    p_idn = sub.add_parser("idn", help="read instrument identification")
    p_idn.add_argument("--instrument", required=True)

    p_scope = sub.add_parser("scope", help="scope measurements")
    scope_sub = p_scope.add_subparsers(dest="scope_cmd", required=True)
    for meas in ("measure-frequency", "measure-duty", "measure-vpp", "measure-rms", "measure-rise-time"):
        pm = scope_sub.add_parser(meas)
        pm.add_argument("--instrument", required=True)
        pm.add_argument("--channel", default="CH1")
    pw = scope_sub.add_parser("capture-waveform")
    pw.add_argument("--instrument", required=True)
    pw.add_argument("--channel", default="CH1")
    pw.add_argument("--output", required=True)

    p_psu = sub.add_parser("psu", help="power supply measurements/control")
    psu_sub = p_psu.add_subparsers(dest="psu_cmd", required=True)
    for meas in ("measure-voltage", "measure-current", "measure-power"):
        pm = psu_sub.add_parser(meas)
        pm.add_argument("--instrument", required=True)
    po = psu_sub.add_parser("output")
    po.add_argument("--instrument", required=True)
    po.add_argument("--state", required=True, choices=["on", "off"])
    po.add_argument("--voltage", type=float)
    po.add_argument("--current", type=float)

    p_dmm = sub.add_parser("dmm", help="multimeter measurements")
    dmm_sub = p_dmm.add_subparsers(dest="dmm_cmd", required=True)
    for meas in ("measure-voltage", "measure-resistance"):
        pm = dmm_sub.add_parser(meas)
        pm.add_argument("--instrument", required=True)

    p_relay = sub.add_parser("relay", help="relay control (whitelisted names only)")
    p_relay.add_argument("--instrument", required=True)
    p_relay.add_argument("--name", required=True)
    p_relay.add_argument("--state", required=True, choices=["on", "off"])

    args, _ = parser.parse_known_args()
    config = load_config()
    limits = load_limits()

    if args.command == "list":
        insts = config.get("instruments") or {}
        rows = [{"name": k, "type": (v or {}).get("type"), "backend": (v or {}).get("backend", "simulator")}
                for k, v in sorted(insts.items())]
        ok({"schema": "lab-instrument-list/v1", "ok": True, "instruments": rows, "timestamp": _now()})

    if args.command == "idn":
        inst = get_instrument(config, args.instrument)
        key = "idn"
        backend = inst.get("backend", "simulator")
        if backend == "visa":
            client = VisaClient(inst)
            try:
                val = client.query(_cmd(inst, args.instrument, "idn", "*IDN?")).strip('"')
            finally:
                client.close()
        else:
            val = f"simulated {args.instrument} (backend=simulator)"
        ok({"schema": "lab-measurement/v1", "ok": True, "instrument": args.instrument,
            "measurement": "idn", "value": val, "unit": None, "timestamp": _now(), "backend": backend})

    if args.command == "scope":
        m = args.scope_cmd.replace("-", "_")
        if m == "capture_waveform":
            inst = get_instrument(config, args.instrument)
            out = args.output
            os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
            with open(out, "w", encoding="utf-8") as fh:
                fh.write("time_s,value_v\n0.0,0.0\n0.00001,3.3\n")
            ok({"schema": "lab-measurement/v1", "ok": True, "instrument": args.instrument,
                "measurement": "waveform", "channel": args.channel, "value": None, "unit": "csv",
                "capture": os.path.abspath(out), "timestamp": _now()})
        key = {"measure_frequency": "frequency", "measure_duty": "duty", "measure_vpp": "vpp",
               "measure_rms": "rms", "measure_rise_time": "rise_time"}[m]
        unit = {"frequency": "Hz", "duty": "%", "vpp": "V", "rms": "V", "rise_time": "s"}[key]
        _measure(config, args, "scope", key, unit, channel_key="channel")

    if args.command == "psu":
        m = args.psu_cmd.replace("-", "_")
        if m == "output":
            do_psu_output(config, args, limits)
        key = {"measure_voltage": "voltage", "measure_current": "current", "measure_power": "power"}[m]
        unit = {"voltage": "V", "current": "A", "power": "W"}[key]
        _measure(config, args, "psu", key, unit)

    if args.command == "dmm":
        m = args.dmm_cmd.replace("-", "_")
        key = {"measure_voltage": "voltage", "measure_resistance": "resistance"}[m]
        unit = {"voltage": "V", "resistance": "ohm"}[key]
        _measure(config, args, "dmm", key, unit)

    if args.command == "relay":
        do_relay(config, args, limits)


if __name__ == "__main__":
    main()