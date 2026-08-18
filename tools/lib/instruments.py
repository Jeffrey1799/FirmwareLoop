#!/usr/bin/env python3
"""
tools/lib/instruments.py - thin instrument layer (GAP-006, v0.0.2).

Single shared module for instrument_cli.py AND pytest fixtures. Scope is
deliberately narrow: open / identify / query / normalize / timeout / close /
error mapping. NOT a framework - no device registry, no orchestration.

Backends:
  visa     - PyVISA + SCPI (real hardware only; never synthesized)
  simulator - deterministic synthetic values for offline/CI (explicitly marked)

Rules (GAP-007): backend=visa must never fabricate data. A query the device
cannot answer raises InstrumentError('CAPABILITY_NOT_SUPPORTED', ...).
"""

from __future__ import annotations

import time

ERROR_CLASSES = (
    "INSTRUMENT_NOT_FOUND",
    "INSTRUMENT_TIMEOUT",
    "CAPABILITY_NOT_SUPPORTED",
    "HARDWARE_VALIDATION_FAILED",
    "CONFIG_ERROR",
)


class InstrumentError(Exception):
    """Structured instrument error carrying a FirmwareLoop error class."""

    def __init__(self, error_class: str, message: str, detail=None):
        if error_class not in ERROR_CLASSES:
            raise ValueError(f"unknown instrument error class: {error_class}")
        super().__init__(message)
        self.error_class = error_class
        self.message = message
        self.detail = detail

    def to_dict(self) -> dict:
        body = {"ok": False, "error_class": self.error_class, "error": self.message}
        if self.detail:
            body["detail"] = self.detail
        return body


# ---------------------------------------------------------------- clients
DEFAULT_SIM = {
    "frequency": 20000.0, "duty": 50.0, "vpp": 3.3, "rms": 1.65,
    "rise_time": 5.0e-9, "voltage": 3.3, "current": 0.035, "power": 0.1155,
    "resistance": 1000.0,
}


class SimulatorClient:
    """Synthetic backend (offline/CI). Measurements come from the lab config's
    simulated_measurements table (falling back to deterministic defaults);
    NEVER used for real evidence."""

    def __init__(self, inst: dict, table: dict | None = None):
        self.inst = inst
        self.table = {**DEFAULT_SIM, **(table or {})}
        self._closed = False

    def identify(self) -> str:
        return f"simulated {self.inst.get('name', 'instrument')} (backend=simulator)"

    def query(self, scpi: str) -> str:
        # map a measurement key from the SCPI string if possible
        key = None
        for token in ("FREQuency", "VPP", "PDUTy", "VRMS", "RTIMe", "VOLT", "CURR", "POW", "RES"):
            if token.upper() in scpi.upper():
                key = {"FREQUENCY": "frequency", "VPP": "vpp", "PDUTY": "duty",
                       "VRMS": "rms", "RTIME": "rise_time", "VOLT": "voltage",
                       "CURR": "current", "POW": "power", "RES": "resistance"}[token.upper()]
                break
        if key and key in self.table:
            return str(self.table[key])
        raise InstrumentError("CAPABILITY_NOT_SUPPORTED",
                              f"simulator has no synthetic value for SCPI '{scpi}'")

    def write(self, scpi: str) -> None:
        pass  # simulator accepts writes (audited by the caller's safety policy)

    def close(self) -> None:
        self._closed = True


class VisaClient:
    """PyVISA + SCPI. Real data only (GAP-007)."""

    def __init__(self, inst: dict, timeout_ms: int = 5000):
        try:
            import pyvisa
        except ImportError as exc:  # pragma: no cover
            raise InstrumentError("INSTRUMENT_NOT_FOUND",
                                  "pyvisa is not installed; use backend=simulator for dry runs") from exc
        self.rm = pyvisa.ResourceManager()
        resource = inst.get("resource")
        if not resource:
            raise InstrumentError("CONFIG_ERROR",
                                  "instrument has no 'resource' entry in lab config")
        try:
            self.inst = self.rm.open_resource(resource)
            self.inst.timeout = timeout_ms
        except Exception as exc:  # noqa: BLE001
            try:
                self.rm.close()
            except Exception:  # noqa: BLE001
                pass
            raise InstrumentError("INSTRUMENT_TIMEOUT",
                                  f"cannot open resource '{resource}': {exc}") from exc

    def identify(self) -> str:
        try:
            return str(self.inst.query("*IDN?")).strip('"').strip()
        except Exception as exc:  # noqa: BLE001
            raise InstrumentError("INSTRUMENT_TIMEOUT", f"*IDN? failed: {exc}") from exc

    def query(self, scpi: str) -> str:
        try:
            return str(self.inst.query(scpi)).strip()
        except Exception as exc:  # noqa: BLE001
            raise InstrumentError("INSTRUMENT_TIMEOUT", f"SCPI '{scpi}' failed: {exc}") from exc

    def write(self, scpi: str) -> None:
        try:
            self.inst.write(scpi)
        except Exception as exc:  # noqa: BLE001
            raise InstrumentError("INSTRUMENT_TIMEOUT", f"SCPI write '{scpi}' failed: {exc}") from exc

    def close(self) -> None:
        try:
            self.inst.close()
            self.rm.close()
        except Exception:  # noqa: BLE001
            pass


# ---------------------------------------------------------------- factory + helpers
def open_instrument(inst: dict, table: dict | None = None, timeout_ms: int = 5000):
    """Open a client for an instrument config entry."""
    backend = (inst or {}).get("backend", "simulator")
    if backend == "visa":
        return VisaClient(inst, timeout_ms)
    if backend == "simulator":
        return SimulatorClient(inst, table)
    raise InstrumentError("CONFIG_ERROR", f"unknown instrument backend: {backend}")


def query_measurement(client, scpi: str):
    """Query + normalize a scalar measurement (float)."""
    raw = client.query(scpi)
    try:
        return float(raw)
    except (TypeError, ValueError) as exc:
        raise InstrumentError("HARDWARE_VALIDATION_FAILED",
                              f"cannot normalize '{raw}' as a number", detail=scpi) from exc


def identify(client) -> str:
    return client.identify()


def close(client) -> None:
    try:
        client.close()
    except Exception:  # noqa: BLE001
        pass


def map_exception(exc: Exception) -> InstrumentError:
    """Wrap a raw exception into a structured instrument error (error mapping)."""
    if isinstance(exc, InstrumentError):
        return exc
    return InstrumentError("INSTRUMENT_TIMEOUT", f"instrument operation failed: {exc}")


def now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")