#!/usr/bin/env python3
"""
fw_mcp_server.py - FirmwareLoop High-Level Workflow MCP Server (v0.0.3).

Exposes high-level firmware engineering tools to AI Coding Agents (Antigravity CLI,
Claude Code CLI, Qoder IDE, Cursor) via the Model Context Protocol (JSON-RPC 2.0 stdio).

Tools provided:
  - fw_doctor: Environment & toolchain diagnostic (doctor.ps1)
  - fw_build: Multi-backend firmware compilation & diagnostics (build.ps1)
  - fw_run_hil_test: Hardware-in-the-loop pytest suite (test.ps1)
  - fw_acceptance_scenario: End-to-end acceptance scenario (acceptance-scenario.ps1)
  - fw_measure: Controlled PyVISA/SCPI instrument measurement (instrument_cli.py)
  - fw_logic_capture: Logic analyzer protocol capture (logic_capture.ps1)
  - fw_logic_decode: Logic analyzer protocol decoding & assertion (logic_decode.ps1)
  - fw_get_evidence: Read structured audit run evidence (artifacts/runs/)
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import traceback
from typing import Any, Dict, List, Optional

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PYTHON_EXE = sys.executable


def find_powershell() -> str:
    for candidate in ["pwsh", "powershell"]:
        path = shutil.which(candidate)
        if path:
            return path
    return "powershell.exe"


PWSH_EXE = find_powershell()


def run_process(cmd: List[str], timeout: int = 300) -> Dict[str, Any]:
    try:
        proc = subprocess.run(
            cmd,
            cwd=REPO_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
        )
        stdout_raw = proc.stdout.strip()
        stderr_raw = proc.stderr.strip()

        # Try to parse JSON from stdout
        parsed = None
        for line in reversed(stdout_raw.splitlines()):
            line_str = line.strip()
            if line_str.startswith("{") and line_str.endswith("}"):
                try:
                    parsed = json.loads(line_str)
                    break
                except Exception:
                    continue

        if parsed is None and stdout_raw.startswith("{") and stdout_raw.endswith("}"):
            try:
                parsed = json.loads(stdout_raw)
            except Exception:
                pass

        return {
            "exit_code": proc.returncode,
            "success": proc.returncode == 0,
            "stdout": stdout_raw,
            "stderr": stderr_raw,
            "data": parsed,
        }
    except subprocess.TimeoutExpired:
        return {
            "exit_code": -1,
            "success": False,
            "error_class": "TIMEOUT",
            "error": f"Command timed out after {timeout} seconds",
            "stdout": "",
            "stderr": "",
        }
    except Exception as e:
        return {
            "exit_code": -1,
            "success": False,
            "error_class": "EXECUTION_ERROR",
            "error": str(e),
            "traceback": traceback.format_exc(),
        }


# ===========================================================================
# Tool Implementations
# ===========================================================================

def handle_fw_doctor(args: Dict[str, Any]) -> Dict[str, Any]:
    script = os.path.join(REPO_ROOT, "tools", "doctor.ps1")
    cmd = [PWSH_EXE, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Json"]
    res = run_process(cmd, timeout=60)
    if res.get("data"):
        return res["data"]
    return res


def handle_fw_build(args: Dict[str, Any]) -> Dict[str, Any]:
    script = os.path.join(REPO_ROOT, "tools", "build.ps1")
    cmd = [PWSH_EXE, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Json"]

    backend = args.get("backend")
    if backend and backend != "auto":
        cmd.extend(["-Backend", backend])

    config = args.get("configuration", "Debug")
    if config:
        cmd.extend(["-Configuration", config])

    if args.get("clean", True):
        cmd.append("-Clean")

    source_dir = args.get("source_dir")
    if source_dir:
        cmd.extend(["-SourceDir", source_dir])

    if args.get("dry_run", False):
        cmd.append("-DryRun")

    timeout_ms = args.get("timeout_ms", 300000)
    res = run_process(cmd, timeout=int(timeout_ms / 1000) + 10)
    if res.get("data"):
        return res["data"]
    return res


def handle_fw_run_hil_test(args: Dict[str, Any]) -> Dict[str, Any]:
    script = os.path.join(REPO_ROOT, "tools", "test.ps1")
    cmd = [PWSH_EXE, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Json"]

    gate = args.get("gate", "simulator")
    if gate:
        cmd.extend(["-Gate", gate])

    test_filter = args.get("test_filter")
    if test_filter:
        cmd.extend(["-Filter", test_filter])

    res = run_process(cmd, timeout=120)
    if res.get("data"):
        return res["data"]
    return res


def handle_fw_acceptance_scenario(args: Dict[str, Any]) -> Dict[str, Any]:
    script = os.path.join(REPO_ROOT, "tools", "acceptance-scenario.ps1")
    cmd = [PWSH_EXE, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Json"]

    mode = args.get("mode", "simulator")
    if mode:
        cmd.extend(["-Mode", mode])

    hardware = args.get("hardware")
    if hardware:
        cmd.extend(["-Hardware", hardware])

    res = run_process(cmd, timeout=180)
    if res.get("data"):
        return res["data"]
    return res


def handle_fw_measure(args: Dict[str, Any]) -> Dict[str, Any]:
    cli_script = os.path.join(REPO_ROOT, "tools", "instrument_cli.py")
    instr_type = args.get("instrument_type", "scope")
    subcommand = args.get("command", "measure-frequency")
    instr_name = args.get("instrument_name", "scope1" if instr_type == "scope" else "psu1")
    channel = args.get("channel", "CH1")
    backend = args.get("backend", "simulator")

    cmd = [PYTHON_EXE, cli_script, instr_type, subcommand, "--instrument", instr_name, "--backend", backend]
    if instr_type == "scope" and channel:
        cmd.extend(["--channel", channel])

    res = run_process(cmd, timeout=30)
    if res.get("data"):
        return res["data"]
    return res


def handle_fw_logic_capture(args: Dict[str, Any]) -> Dict[str, Any]:
    script = os.path.join(REPO_ROOT, "tools", "logic_capture.ps1")
    cmd = [PWSH_EXE, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Json"]

    protocol = args.get("protocol", "spi")
    cmd.extend(["-Protocol", protocol])

    sample_rate = args.get("sample_rate")
    if sample_rate:
        cmd.extend(["-SampleRate", str(sample_rate)])

    duration_ms = args.get("duration_ms")
    if duration_ms:
        cmd.extend(["-DurationMs", str(duration_ms)])

    output_file = args.get("output_file")
    if output_file:
        cmd.extend(["-OutputFile", output_file])

    res = run_process(cmd, timeout=30)
    if res.get("data"):
        return res["data"]
    return res


def handle_fw_logic_decode(args: Dict[str, Any]) -> Dict[str, Any]:
    script = os.path.join(REPO_ROOT, "tools", "logic_decode.ps1")
    cmd = [PWSH_EXE, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Json"]

    capture_file = args.get("capture_file")
    if capture_file:
        cmd.extend(["-CaptureFile", capture_file])

    protocol = args.get("protocol", "spi")
    cmd.extend(["-Protocol", protocol])

    frequency = args.get("frequency_hz")
    if frequency:
        cmd.extend(["-FrequencyHz", str(frequency)])

    res = run_process(cmd, timeout=30)
    if res.get("data"):
        return res["data"]
    return res


def handle_fw_get_evidence(args: Dict[str, Any]) -> Dict[str, Any]:
    run_id = args.get("run_id", "latest")
    runs_dir = os.path.join(REPO_ROOT, "artifacts", "runs")

    if not os.path.exists(runs_dir):
        return {"ok": False, "error_class": "ARTIFACT_NOT_FOUND", "message": "artifacts/runs directory does not exist"}

    target_dir = None
    if run_id == "latest":
        entries = [os.path.join(runs_dir, d) for d in os.listdir(runs_dir) if os.path.isdir(os.path.join(runs_dir, d))]
        if not entries:
            return {"ok": False, "error_class": "ARTIFACT_NOT_FOUND", "message": "No runs found in artifacts/runs"}
        entries.sort(key=lambda x: os.path.getmtime(x), reverse=True)
        target_dir = entries[0]
        run_id = os.path.basename(target_dir)
    else:
        target_dir = os.path.join(runs_dir, run_id)

    if not os.path.exists(target_dir):
        return {"ok": False, "error_class": "ARTIFACT_NOT_FOUND", "message": f"Run {run_id} not found"}

    summary_file = os.path.join(target_dir, "summary.json")
    report_file = os.path.join(target_dir, "final-report.json")

    summary_data = None
    if os.path.exists(summary_file):
        try:
            with open(summary_file, "r", encoding="utf-8") as f:
                summary_data = json.load(f)
        except Exception:
            pass

    report_data = None
    if os.path.exists(report_file):
        try:
            with open(report_file, "r", encoding="utf-8") as f:
                report_data = json.load(f)
        except Exception:
            pass

    files = os.listdir(target_dir)
    return {
        "ok": True,
        "run_id": run_id,
        "directory": target_dir,
        "files": files,
        "summary": summary_data,
        "final_report": report_data,
    }


# ===========================================================================
# Tool Definitions & Schemas
# ===========================================================================

TOOLS_REGISTRY = {
    "fw_doctor": {
        "description": "Run diagnostic check on environment, toolchains, Python modules, COM ports, and probe/instrument readiness.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "include_ports": {
                    "type": "boolean",
                    "description": "Whether to query active COM ports on the host",
                    "default": True,
                }
            },
            "additionalProperties": False,
        },
        "handler": handle_fw_doctor,
    },
    "fw_build": {
        "description": "Compile firmware using the repository's build system (CMake, Make, Keil, IAR, PlatformIO, Zephyr, ESP-IDF). Returns structured artifact SHA256 and compiler diagnostics (file, line, col, message).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "backend": {
                    "type": "string",
                    "enum": ["auto", "cmake", "make", "platformio", "keil", "iar", "zephyr", "esp-idf"],
                    "description": "Build system backend (defaults to auto detection)",
                    "default": "auto",
                },
                "configuration": {
                    "type": "string",
                    "enum": ["Debug", "Release"],
                    "description": "Build configuration",
                    "default": "Debug",
                },
                "clean": {
                    "type": "boolean",
                    "description": "Perform full clean rebuild before compiling",
                    "default": True,
                },
                "source_dir": {
                    "type": "string",
                    "description": "Custom source directory (optional)",
                },
                "dry_run": {
                    "type": "boolean",
                    "description": "Only construct and return the build command without executing",
                    "default": False,
                },
            },
            "additionalProperties": False,
        },
        "handler": handle_fw_build,
    },
    "fw_run_hil_test": {
        "description": "Execute pytest hardware-in-the-loop (HIL) automated test suite (boot, UART, protocol, power, signal, logic analyzer). Returns structured JUnit & evidence.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "gate": {
                    "type": "string",
                    "enum": ["simulator", "agentic-hil", "direct-serial"],
                    "description": "UART/Hardware gate mode",
                    "default": "simulator",
                },
                "test_filter": {
                    "type": "string",
                    "description": "pytest filter expression (-k filter)",
                },
            },
            "additionalProperties": False,
        },
        "handler": handle_fw_run_hil_test,
    },
    "fw_acceptance_scenario": {
        "description": "Execute complete end-to-end acceptance scenario (Build -> Flash -> Reset -> UART Observation -> Logic Analyzer -> Scope -> pytest -> Final Report).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "mode": {
                    "type": "string",
                    "enum": ["simulator", "real"],
                    "description": "Execution mode (simulator for host CI/offline, real for physical bench)",
                    "default": "simulator",
                },
                "hardware": {
                    "type": "string",
                    "enum": ["agentic-hil"],
                    "description": "Hardware adapter when running in real mode",
                    "default": "agentic-hil",
                },
            },
            "additionalProperties": False,
        },
        "handler": handle_fw_acceptance_scenario,
    },
    "fw_measure": {
        "description": "Perform controlled, safe physical or simulated instrument measurements (Scope, PSU, DMM, AWG) via PyVISA/SCPI, enforced by safety limits.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "instrument_type": {
                    "type": "string",
                    "enum": ["scope", "psu", "dmm"],
                    "description": "Category of instrument",
                    "default": "scope",
                },
                "command": {
                    "type": "string",
                    "enum": [
                        "measure-frequency",
                        "measure-duty",
                        "measure-vpp",
                        "measure-rms",
                        "measure-rise-time",
                        "measure-voltage",
                        "measure-current",
                        "measure-power",
                        "measure-resistance",
                    ],
                    "description": "Measurement command",
                    "default": "measure-frequency",
                },
                "instrument_name": {
                    "type": "string",
                    "description": "Instrument identifier configured in lab.yaml (e.g., scope1, psu1)",
                    "default": "scope1",
                },
                "channel": {
                    "type": "string",
                    "description": "Scope channel (CH1, CH2, etc.)",
                    "default": "CH1",
                },
                "backend": {
                    "type": "string",
                    "enum": ["simulator", "visa"],
                    "description": "Driver backend (simulator or real VISA)",
                    "default": "simulator",
                },
            },
            "required": ["instrument_type", "command"],
            "additionalProperties": False,
        },
        "handler": handle_fw_measure,
    },
    "fw_logic_capture": {
        "description": "Capture digital protocol waveforms (SPI / UART / I2C) via Saleae / sigrok or deterministic simulator.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "protocol": {
                    "type": "string",
                    "enum": ["spi", "uart", "i2c"],
                    "description": "Target communication protocol",
                    "default": "spi",
                },
                "sample_rate": {
                    "type": "integer",
                    "description": "Sample rate in Hz",
                    "default": 10000000,
                },
                "duration_ms": {
                    "type": "integer",
                    "description": "Capture duration in milliseconds",
                    "default": 50,
                },
                "output_file": {
                    "type": "string",
                    "description": "Path to save raw capture file (optional)",
                },
            },
            "additionalProperties": False,
        },
        "handler": handle_fw_logic_capture,
    },
    "fw_logic_decode": {
        "description": "Decode captured digital waveforms into protocol packets/frames and verify assertions.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "capture_file": {
                    "type": "string",
                    "description": "Path to capture file (defaults to latest capture in artifacts/captures/)",
                },
                "protocol": {
                    "type": "string",
                    "enum": ["spi", "uart", "i2c"],
                    "description": "Protocol decoder",
                    "default": "spi",
                },
                "frequency_hz": {
                    "type": "integer",
                    "description": "Clock frequency for decoding (Hz)",
                    "default": 1000000,
                },
            },
            "additionalProperties": False,
        },
        "handler": handle_fw_logic_decode,
    },
    "fw_get_evidence": {
        "description": "Retrieve audit evidence, summary, and artifacts from recent test and acceptance runs.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "run_id": {
                    "type": "string",
                    "description": "Specific run ID or 'latest' for the most recent run",
                    "default": "latest",
                }
            },
            "additionalProperties": False,
        },
        "handler": handle_fw_get_evidence,
    },
}


# ===========================================================================
# JSON-RPC 2.0 MCP Protocol Processor
# ===========================================================================

def build_tools_list() -> List[Dict[str, Any]]:
    tools = []
    for name, info in TOOLS_REGISTRY.items():
        tools.append({
            "name": name,
            "description": info["description"],
            "inputSchema": info["inputSchema"],
        })
    return tools


def process_request(req: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    req_id = req.get("id")
    method = req.get("method")
    params = req.get("params", {})

    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {
                    "tools": {
                        "listChanged": False
                    }
                },
                "serverInfo": {
                    "name": "firmwareloop",
                    "version": "0.0.3"
                }
            }
        }

    if method == "notifications/initialized":
        return None

    if method == "ping":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {}
        }

    if method == "tools/list":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "tools": build_tools_list()
            }
        }

    if method == "tools/call":
        tool_name = params.get("name")
        arguments = params.get("arguments", {})

        if tool_name not in TOOLS_REGISTRY:
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {
                    "code": -32601,
                    "message": f"Tool '{tool_name}' not found"
                }
            }

        handler = TOOLS_REGISTRY[tool_name]["handler"]
        try:
            result_data = handler(arguments)
            result_text = json.dumps(result_data, ensure_ascii=False, indent=2)
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "content": [
                        {
                            "type": "text",
                            "text": result_text
                        }
                    ],
                    "isError": not result_data.get("ok", result_data.get("success", True))
                }
            }
        except Exception as e:
            err_body = {
                "ok": False,
                "error_class": "TOOL_EXECUTION_EXCEPTION",
                "error": str(e),
                "traceback": traceback.format_exc()
            }
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "content": [
                        {
                            "type": "text",
                            "text": json.dumps(err_body, ensure_ascii=False, indent=2)
                        }
                    ],
                    "isError": True
                }
            }

    # Unknown method
    if req_id is not None:
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {
                "code": -32601,
                "message": f"Method '{method}' not implemented"
            }
        }
    return None


def main() -> None:
    # Set stdin/stdout to utf-8 unbuffered
    if sys.platform == "win32":
        import msvcrt
        msvcrt.setmode(sys.stdin.fileno(), os.O_BINARY)
        msvcrt.setmode(sys.stdout.fileno(), os.O_BINARY)

    reader = sys.stdin.buffer
    writer = sys.stdout.buffer

    while True:
        line = reader.readline()
        if not line:
            break

        line_str = line.decode("utf-8", errors="replace").strip()
        if not line_str:
            continue

        try:
            req = json.loads(line_str)
        except Exception:
            continue

        res = process_request(req)
        if res is not None:
            res_bytes = (json.dumps(res, ensure_ascii=False) + "\n").encode("utf-8")
            writer.write(res_bytes)
            writer.flush()


if __name__ == "__main__":
    main()
