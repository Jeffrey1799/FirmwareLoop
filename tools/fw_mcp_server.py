#!/usr/bin/env python3
"""
fw_mcp_server.py - FirmwareLoop High-Level Workflow & Device MCP Server (v0.0.8).

Exposes high-level firmware engineering and hardware management tools to AI Coding
Agents (Antigravity CLI, Claude Code CLI, Qoder IDE, Cursor) via the Model Context
Protocol (JSON-RPC 2.0 stdio).

Tools provided:
  - fw_doctor: Environment & toolchain diagnostic (doctor.ps1)
  - fw_build: Multi-backend firmware compilation & diagnostics (build.ps1)
  - fw_flash: Flash firmware image to target MCU (flash.ps1 / agentic-hil)
  - fw_reset: Reset physical or simulated target MCU (reset.ps1)
  - fw_run_hil_test: Hardware-in-the-loop pytest suite (test.ps1)
  - fw_acceptance_scenario: End-to-end acceptance scenario (acceptance-scenario.ps1)
  - fw_measure: Controlled PyVISA/SCPI instrument measurement (instrument_cli.py)
  - fw_logic_capture: Logic analyzer protocol capture (logic_capture.ps1)
  - fw_logic_decode: Logic analyzer protocol decoding & assertion (logic_decode.ps1)
  - fw_get_evidence: Read structured audit run evidence (artifacts/runs/)
  - fw_configure_lab: Interactively configure project, build backend, chip & ports (lab.yaml)
  - fw_scan_hardware: Auto-detect connected ST-LINK / J-Link probes, MCU targets & COM ports
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import traceback
from typing import Any, Dict, List, Optional

try:
    import yaml
except ImportError:
    yaml = None

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PYTHON_EXE = sys.executable
AHIL_EXE = os.path.join(REPO_ROOT, ".venv", "Scripts", "agentic-hil.exe")
PYOCD_EXE = os.path.join(REPO_ROOT, ".venv", "Scripts", "pyocd.exe")


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


def handle_fw_flash(args: Dict[str, Any]) -> Dict[str, Any]:
    script = os.path.join(REPO_ROOT, "tools", "flash.ps1")
    backend = args.get("backend", "simulator")
    artifact = args.get("artifact_path", "artifacts/build/firmware.elf")

    cmd = [
        PWSH_EXE, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", script, "-Backend", backend, "-Artifact", artifact, "-Json"
    ]
    res = run_process(cmd, timeout=120)
    if res.get("data"):
        return res["data"]
    return res


def handle_fw_reset(args: Dict[str, Any]) -> Dict[str, Any]:
    script = os.path.join(REPO_ROOT, "tools", "reset.ps1")
    backend = args.get("backend", "simulator")
    expected = args.get("expected_target")

    cmd = [
        PWSH_EXE, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", script, "-Backend", backend, "-Json"
    ]
    if expected:
        cmd.extend(["-ExpectedTarget", expected])

    res = run_process(cmd, timeout=30)
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
        target_dir = max(entries, key=os.path.getmtime)
    else:
        candidate = os.path.join(runs_dir, run_id)
        if os.path.exists(candidate):
            target_dir = candidate
        else:
            return {"ok": False, "error_class": "ARTIFACT_NOT_FOUND", "message": f"Run '{run_id}' not found"}

    summary_file = os.path.join(target_dir, "summary.json")
    summary_data = None
    if os.path.exists(summary_file):
        try:
            with open(summary_file, "r", encoding="utf-8") as f:
                summary_data = json.load(f)
        except Exception:
            pass

    report_file = os.path.join(target_dir, "final-report.json")
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
        "run_id": os.path.basename(target_dir),
        "directory": target_dir,
        "files": files,
        "summary": summary_data,
        "final_report": report_data,
    }


def handle_fw_init_project(args: Dict[str, Any]) -> Dict[str, Any]:
    """Scaffold multi-agent instruction files (AGENTS.md, CLAUDE.md, GEMINI.md), lab.yaml, and .mcp.json."""
    target_dir = args.get("target_dir", ".")
    target_dir = os.path.abspath(target_dir)
    os.makedirs(target_dir, exist_ok=True)
    target_chip = args.get("target_chip", "STM32F103C8")
    build_backend = args.get("build_backend", "keil")
    overwrite = args.get("overwrite", False)

    created_files = []

    # 1. AGENTS.md
    agents_path = os.path.join(target_dir, "AGENTS.md")
    agents_content = """# AGENTS.md — Firmware Engineering & Lab Automation Guidelines

This repository is configured with **FirmwareLoop (`fwloop`)** for AI Agent-driven firmware development, building, flashing, and hardware-in-the-loop (HIL) testing.

## Dual-Tier MCP Tools Available
- **Upper-Tier (`fwloop`)**:
  - `fw_doctor()`: Check compiler, Python, COM ports, and probe connectivity.
  - `fw_configure_lab(project_name, build_backend, target_chip, uart_port)`: Interactively configure project settings in `lab/lab.yaml`.
  - `fw_scan_hardware(adopt=false)`: Scan connected ST-LINK / J-Link / CMSIS-DAP probes and COM ports.
  - `fw_build(backend="auto", configuration="Debug", clean=true)`: Build firmware across Keil5, CMake, Make, IAR, PlatformIO, etc.
  - `fw_flash(backend="auto", artifact_path)`: Flash compiled firmware image into target MCU via ST-LINK or J-Link.
  - `fw_reset(backend="auto")`: Hardware/software reset target MCU.
  - `fw_run_hil_test()`: Run pytest automated hardware-in-the-loop test suite.
  - `fw_measure(instrument_type, command)`: Safe PyVISA instrument measurement.
  - `fw_logic_capture(protocol="i2c|spi|uart")` / `fw_logic_decode()`: Logic analyzer protocol capture & decode.
  - `fw_get_evidence()`: Retrieve audit run artifacts and test evidence.
  - `fw_init_project()`: Scaffold multi-agent instruction files and lab configurations.

- **Lower-Tier (`agentic-hil`)**:
  - `probe_target()`, `flash_firmware()`, `reset_target()`, `com_session_*()`, `debug_*()`.

## Core Agent Rules & Principles
1. **Real-Hardware-First & Zero Fake Results**: Never fake, simulate, or mock results during real firmware development. If toolchains (Keil5/GCC), debug probes (ST-LINK/J-Link), target MCU, or instruments are missing or disconnected, immediately fail closed with explicit error classes (`TOOLCHAIN_NOT_FOUND`, `PROBE_NOT_FOUND`, `TARGET_UNREACHABLE`) and actionable setup guidance for the user. Never claim success on incomplete conditions!
2. **Evidence-Driven**: Never judge success by `exit code == 0` alone. Inspect Build Evidence + Runtime Evidence + Measurement Evidence + Assertion.
3. **Safety First**: Never bypass `lab/limits.yaml` safety boundaries.
4. **Iteration Limit**: Maximum 3 automated fix attempts before requesting human guidance.
"""
    if not os.path.exists(agents_path) or overwrite:
        with open(agents_path, "w", encoding="utf-8") as fh:
            fh.write(agents_content)
        created_files.append("AGENTS.md")

    # 2. CLAUDE.md
    claude_path = os.path.join(target_dir, "CLAUDE.md")
    claude_content = f"# CLAUDE.md — Claude Code Guidelines\n\n{agents_content}"
    if not os.path.exists(claude_path) or overwrite:
        with open(claude_path, "w", encoding="utf-8") as fh:
            fh.write(claude_content)
        created_files.append("CLAUDE.md")

    # 3. GEMINI.md
    gemini_path = os.path.join(target_dir, "GEMINI.md")
    gemini_content = "# GEMINI.md — Antigravity Agent Guidelines\n\nSee `AGENTS.md` for full project guidelines and Dual-Tier MCP tools.\n"
    if not os.path.exists(gemini_path) or overwrite:
        with open(gemini_path, "w", encoding="utf-8") as fh:
            fh.write(gemini_content)
        created_files.append("GEMINI.md")

    # 4. lab/lab.yaml
    lab_dir = os.path.join(target_dir, "lab")
    os.makedirs(lab_dir, exist_ok=True)
    lab_yaml_path = os.path.join(lab_dir, "lab.yaml")
    lab_yaml_content = f"""# FirmwareLoop Project & Hardware Bench Configuration
schema: "firmwareloop-lab-config/v1"

project:
  name: "{os.path.basename(target_dir)}"
  target_chip: "{target_chip}"
  build_backend: "{build_backend}"
  source_dir: "."

hardware:
  debugger_probe: "stlink"
  probe_serial: "auto"
  uart:
    port: "COM3"
    baudrate: 115200
  power_supply:
    default_voltage: 3.3
"""
    if not os.path.exists(lab_yaml_path) or overwrite:
        with open(lab_yaml_path, "w", encoding="utf-8") as fh:
            fh.write(lab_yaml_content)
        created_files.append("lab/lab.yaml")

    # 5. .mcp.json
    mcp_json_path = os.path.join(target_dir, ".mcp.json")
    mcp_json_content = """{
  "mcpServers": {
    "fwloop": {
      "command": "fwloop"
    },
    "agentic-hil": {
      "command": "agentic-hil",
      "args": ["mcp-stdio"]
    }
  }
}
"""
    if not os.path.exists(mcp_json_path) or overwrite:
        with open(mcp_json_path, "w", encoding="utf-8") as fh:
            fh.write(mcp_json_content)
        created_files.append(".mcp.json")

    # 6. skills/firmwareloop/SKILL.md
    skill_dir = os.path.join(target_dir, "skills", "firmwareloop")
    os.makedirs(skill_dir, exist_ok=True)
    skill_path = os.path.join(skill_dir, "SKILL.md")
    skill_content = """---
name: firmwareloop
description: FirmwareLoop workflow skill for orchestrating firmware builds (Keil/CMake/Make/etc.), probe detection (ST-LINK/J-Link), interactive lab configuration, pytest HIL testing, I2C/SPI logic analyzer captures, PyVISA instrument measurements, and end-to-end hardware acceptance.
---

# FirmwareLoop Skill

Use this skill when developing, building, testing, or diagnosing embedded firmware within the FirmwareLoop repository.

## Capabilities & Tools

### Upper-Tier MCP Tools (`firmwareloop`)
- `fw_doctor`: Run environmental health check.
- `fw_configure_lab`: Interactively configure or update project parameters, target chip (e.g. STM32F103C8), build backend (e.g. keil), source directory, COM port, and debugger probe in `lab/lab.yaml`.
- `fw_scan_hardware`: Scan and identify attached hardware debuggers (ST-LINK, J-Link, CMSIS-DAP) and COM ports.
- `fw_build`: Compile firmware across 7 backends (Keil, CMake, Make, IAR, PlatformIO, Zephyr, ESP-IDF).
- `fw_flash`: Flash compiled firmware image into target MCU.
- `fw_reset`: Hardware or software reset of the target MCU.
- `fw_run_hil_test`: Run 12-item pytest HIL automated testing.
- `fw_acceptance_scenario`: Execute end-to-end acceptance scenario.
- `fw_measure`: Query PyVISA/SCPI instrument readings (frequency, duty cycle, Vpp, voltage, current).
- `fw_logic_capture` / `fw_logic_decode`: Digital protocol capture and verification (I2C, SPI, UART).
- `fw_get_evidence`: Retrieve audit run artifacts and reports.
- `fw_init_project`: Scaffold multi-agent instruction files and lab configurations.

## Mandatory Rules
1. **Real-Hardware-First & Zero Fake Data**: Never fake or mock hardware results. When compilers, debuggers, or MCU targets are missing, fail closed immediately and output explicit error diagnostics and user setup guidance.
2. **Max 3 Code Iterations**: Never loop infinitely fixing code.
3. **Fail Closed on Safety**: Never bypass `limits.yaml`.
4. **Verify Evidence**: Ensure all evidence is captured in `artifacts/runs/<run_id>/`.
"""
    if not os.path.exists(skill_path) or overwrite:
        with open(skill_path, "w", encoding="utf-8") as fh:
            fh.write(skill_content)
        created_files.append("skills/firmwareloop/SKILL.md")

    return {
        "ok": True,
        "target_dir": target_dir,
        "created_files": created_files,
        "message": f"Successfully initialized FirmwareLoop multi-agent files in {target_dir}"
    }


def handle_fw_configure_lab(args: Dict[str, Any]) -> Dict[str, Any]:
    lab_yaml_path = os.path.join(REPO_ROOT, "lab", "lab.yaml")
    example_yaml_path = os.path.join(REPO_ROOT, "lab", "lab.example.yaml")

    config: Dict[str, Any] = {}
    if os.path.exists(lab_yaml_path):
        try:
            if yaml:
                with open(lab_yaml_path, "r", encoding="utf-8") as f:
                    config = yaml.safe_load(f) or {}
            else:
                with open(lab_yaml_path, "r", encoding="utf-8") as f:
                    config = json.load(f) or {}
        except Exception:
            config = {}
    elif os.path.exists(example_yaml_path) and yaml:
        try:
            with open(example_yaml_path, "r", encoding="utf-8") as f:
                config = yaml.safe_load(f) or {}
        except Exception:
            config = {}

    if "project" not in config:
        config["project"] = {}
    if "dut" not in config:
        config["dut"] = {"uart": {}}
    if "hardware" not in config:
        config["hardware"] = {}

    updated = []

    if "project_name" in args and args["project_name"] is not None:
        config["project"]["name"] = args["project_name"]
        updated.append("project.name")

    if "build_backend" in args and args["build_backend"] is not None:
        config["project"]["build_backend"] = args["build_backend"]
        updated.append("project.build_backend")

    if "source_dir" in args and args["source_dir"] is not None:
        config["project"]["source_dir"] = args["source_dir"]
        updated.append("project.source_dir")

    if "target_chip" in args and args["target_chip"] is not None:
        config["project"]["target_chip"] = args["target_chip"]
        config["dut"]["expected_target"] = args["target_chip"]
        updated.append("project.target_chip")

    if "uart_port" in args and args["uart_port"] is not None:
        if "uart" not in config["dut"]:
            config["dut"]["uart"] = {}
        config["dut"]["uart"]["port"] = args["uart_port"]
        updated.append("dut.uart.port")

    if "uart_baudrate" in args and args["uart_baudrate"] is not None:
        if "uart" not in config["dut"]:
            config["dut"]["uart"] = {}
        config["dut"]["uart"]["baudrate"] = int(args["uart_baudrate"])
        updated.append("dut.uart.baudrate")

    if "debugger_backend" in args and args["debugger_backend"] is not None:
        config["hardware"]["debugger_backend"] = args["debugger_backend"]
        updated.append("hardware.debugger_backend")

    if "debugger_probe_id" in args and args["debugger_probe_id"] is not None:
        config["hardware"]["probe_id"] = args["debugger_probe_id"]
        updated.append("hardware.probe_id")

    os.makedirs(os.path.dirname(lab_yaml_path), exist_ok=True)
    if yaml:
        with open(lab_yaml_path, "w", encoding="utf-8") as f:
            yaml.dump(config, f, allow_unicode=True, default_flow_style=False)
    else:
        with open(lab_yaml_path, "w", encoding="utf-8") as f:
            json.dump(config, f, ensure_ascii=False, indent=2)

    return {
        "ok": True,
        "message": f"Successfully updated lab/lab.yaml ({len(updated)} fields modified)",
        "updated_fields": updated,
        "config_file": lab_yaml_path,
        "config": config,
    }


def handle_fw_scan_hardware(args: Dict[str, Any]) -> Dict[str, Any]:
    probes = []
    com_ports = []
    messages = []

    # 1. Probe detection via pyocd
    if os.path.exists(PYOCD_EXE):
        res = run_process([PYOCD_EXE, "list"], timeout=15)
        raw_output = res.get("stdout", "")
        if "No available debug probes" not in raw_output:
            for line in raw_output.splitlines():
                if line.strip() and not line.startswith("#") and not line.startswith("usage"):
                    probes.append({"raw": line.strip(), "source": "pyocd"})

    # 2. Probe & COM detection via agentic-hil
    if os.path.exists(AHIL_EXE):
        # COM Ports
        com_res = run_process([AHIL_EXE, "com-ports"], timeout=10)
        if com_res.get("data") and "ports" in com_res["data"]:
            for p in com_res["data"]["ports"]:
                com_ports.append(p)
        elif com_res.get("stdout"):
            for line in com_res["stdout"].splitlines():
                if line.strip():
                    com_ports.append({"raw": line.strip()})

        # Debugger Probes
        probe_res = run_process([AHIL_EXE, "debugger-probes"], timeout=15)
        if probe_res.get("stdout") and "No" not in probe_res["stdout"]:
            messages.append(probe_res["stdout"])

        # Auto adopt if requested
        if args.get("adopt", False):
            adopt_res = run_process([AHIL_EXE, "adopt-hardware"], timeout=20)
            messages.append(f"adopt-hardware: {adopt_res.get('stdout', '')}")

    return {
        "ok": True,
        "probes": probes,
        "probes_count": len(probes),
        "com_ports": com_ports,
        "com_ports_count": len(com_ports),
        "details": messages,
        "recommendation": (
            "No physical probes detected. Connect an ST-LINK or J-Link debugger and retry."
            if len(probes) == 0 else
            f"Detected {len(probes)} probe(s) and {len(com_ports)} COM port(s)."
        ),
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
    "fw_configure_lab": {
        "description": "Interactively configure or update project parameters, target chip (e.g. STM32F103C8), build backend (e.g. keil), source directory, COM port, and debugger probe in lab/lab.yaml.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_name": {
                    "type": "string",
                    "description": "Project identifier name",
                },
                "build_backend": {
                    "type": "string",
                    "enum": ["keil", "cmake", "make", "iar", "zephyr", "esp-idf", "platformio"],
                    "description": "Build toolchain backend",
                },
                "source_dir": {
                    "type": "string",
                    "description": "Source or project directory containing .uvprojx, Makefile, or CMakeLists.txt",
                },
                "target_chip": {
                    "type": "string",
                    "description": "Target MCU model (e.g. STM32F103C8, STM32F407ZG)",
                },
                "debugger_backend": {
                    "type": "string",
                    "enum": ["stlink", "jlink", "pyocd", "openocd", "daplink"],
                    "description": "Hardware debugger probe backend",
                },
                "debugger_probe_id": {
                    "type": "string",
                    "description": "Serial number or ID of the hardware probe",
                },
                "uart_port": {
                    "type": "string",
                    "description": "DUT serial communication COM port (e.g. COM5)",
                },
                "uart_baudrate": {
                    "type": "integer",
                    "description": "UART baud rate (e.g. 115200)",
                    "default": 115200,
                },
            },
            "additionalProperties": False,
        },
        "handler": handle_fw_configure_lab,
    },
    "fw_scan_hardware": {
        "description": "Scan and identify all attached hardware debuggers (ST-LINK, J-Link, CMSIS-DAP), target MCU identity, and active COM ports.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "adopt": {
                    "type": "boolean",
                    "description": "Whether to carry detected hardware parameters into configuration automatically",
                    "default": False,
                }
            },
            "additionalProperties": False,
        },
        "handler": handle_fw_scan_hardware,
    },
    "fw_build": {
        "description": "Compile firmware using the repository's build system (Keil, CMake, Make, IAR, PlatformIO, Zephyr, ESP-IDF). Returns structured artifact SHA256 and compiler diagnostics (file, line, col, message).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "backend": {
                    "type": "string",
                    "enum": ["auto", "keil", "cmake", "make", "platformio", "iar", "zephyr", "esp-idf"],
                    "description": "Build system backend (defaults to auto detection or lab.yaml)",
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
    "fw_flash": {
        "description": "Flash compiled firmware image (.elf / .hex / .bin / .axf) into target MCU via ST-LINK, J-Link, pyOCD, or simulator.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "backend": {
                    "type": "string",
                    "enum": ["simulator", "agentic-hil", "openocd", "stm32cubeprogrammer", "jlink"],
                    "description": "Flashing backend driver",
                    "default": "simulator",
                },
                "artifact_path": {
                    "type": "string",
                    "description": "Relative or absolute path to the binary artifact to flash",
                    "default": "artifacts/build/firmware.elf",
                },
            },
            "additionalProperties": False,
        },
        "handler": handle_fw_flash,
    },
    "fw_reset": {
        "description": "Reset physical or simulated target MCU via debug probe or hardware reset line.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "backend": {
                    "type": "string",
                    "enum": ["simulator", "agentic-hil", "openocd"],
                    "description": "Reset backend driver",
                    "default": "simulator",
                },
                "expected_target": {
                    "type": "string",
                    "description": "Expected MCU identity to verify before issuing reset",
                },
            },
            "additionalProperties": False,
        },
        "handler": handle_fw_reset,
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
        "description": "Capture digital protocol waveforms (I2C, SPI, UART) via Saleae / sigrok or deterministic simulator.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "protocol": {
                    "type": "string",
                    "enum": ["i2c", "spi", "uart"],
                    "description": "Target communication protocol (e.g. i2c, spi, uart)",
                    "default": "i2c",
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
        "description": "Decode captured digital waveforms into protocol packets/frames (I2C address/ACK, SPI bytes, UART data) and verify assertions.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "capture_file": {
                    "type": "string",
                    "description": "Path to capture file (defaults to latest capture in artifacts/captures/)",
                },
                "protocol": {
                    "type": "string",
                    "enum": ["i2c", "spi", "uart"],
                    "description": "Protocol decoder",
                    "default": "i2c",
                },
                "frequency_hz": {
                    "type": "integer",
                    "description": "Clock frequency for decoding (Hz)",
                    "default": 400000,
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
    "fw_init_project": {
        "description": "Scaffold multi-agent instruction files (AGENTS.md, CLAUDE.md, GEMINI.md), lab.yaml bench config, and .mcp.json in the current or specified firmware project directory.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "target_dir": {
                    "type": "string",
                    "description": "Directory path of the firmware project to initialize (defaults to current directory '.')",
                    "default": ".",
                },
                "target_chip": {
                    "type": "string",
                    "description": "Target MCU chip model (e.g. STM32F103C8, STM32F407ZG)",
                    "default": "STM32F103C8",
                },
                "build_backend": {
                    "type": "string",
                    "enum": ["keil", "cmake", "make", "platformio", "iar", "zephyr", "esp-idf"],
                    "description": "Build system backend",
                    "default": "keil",
                },
                "overwrite": {
                    "type": "boolean",
                    "description": "Whether to overwrite existing instruction files if present",
                    "default": False,
                },
            },
            "additionalProperties": False,
        },
        "handler": handle_fw_init_project,
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
                    "version": "0.0.8"
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


def handle_cli_update() -> int:
    """Handle `firmwareloop update` command."""
    print("============================================================")
    print("  FirmwareLoop Auto-Updater (v0.0.8)")
    print("============================================================")

    is_git_repo = os.path.exists(os.path.join(REPO_ROOT, ".git"))
    if is_git_repo:
        print(f"[*] Local Git repository detected at: {REPO_ROOT}")
        print("[*] Pulling latest updates from GitHub remote...")
        try:
            res_pull = subprocess.run(["git", "pull"], cwd=REPO_ROOT, text=True, capture_output=True)
            print(res_pull.stdout.strip() if res_pull.stdout else "")
            if res_pull.returncode != 0:
                print(f"[-] Git pull failed: {res_pull.stderr.strip()}")
                return 1
            print("[+] Git pull completed successfully.")
        except Exception as e:
            print(f"[-] Error executing git pull: {e}")
            return 1

        print("[*] Reinstalling & updating package dependencies...")
        uv_path = shutil.which("uv")
        if uv_path:
            cmd = [uv_path, "pip", "install", "-e", "."]
        else:
            cmd = [sys.executable, "-m", "pip", "install", "-e", "."]

        try:
            res_install = subprocess.run(cmd, cwd=REPO_ROOT, text=True, capture_output=True)
            if res_install.returncode == 0:
                print("[+] Dependencies and CLI entrypoints updated successfully.")
            else:
                print(f"[-] Dependency update warning: {res_install.stderr.strip()}")
        except Exception as e:
            print(f"[-] Error installing dependencies: {e}")

        print("============================================================")
        print("[+] FirmwareLoop is now up to date!")
        print("============================================================")
        return 0
    else:
        print("[*] Global / uv-managed installation detected.")
        uv_path = shutil.which("uv")
        if uv_path:
            print("[*] Refreshing uv cache for firmwareloop...")
            try:
                subprocess.run([uv_path, "cache", "clean", "firmwareloop"], capture_output=True)
                print("[+] uv cache refreshed! The next run will automatically fetch the latest release from GitHub.")
                return 0
            except Exception as e:
                print(f"[-] Error refreshing uv cache: {e}")
                return 1
        else:
            print("[*] Upgrading via pip...")
            res = subprocess.run([sys.executable, "-m", "pip", "install", "--upgrade", "firmwareloop"])
            return res.returncode


def handle_cli_doctor() -> int:
    """Handle `firmwareloop doctor` command."""
    print("[*] Running FirmwareLoop environment diagnostics...")
    cmd = [PWSH_EXE, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", os.path.join(REPO_ROOT, "tools", "doctor.ps1")]
    res = subprocess.run(cmd, cwd=REPO_ROOT)
    return res.returncode


def handle_cli_setup() -> int:
    """Handle `firmwareloop setup` command."""
    cmd = [PWSH_EXE, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", os.path.join(REPO_ROOT, "tools", "setup-agent-mcp.ps1")]
    res = subprocess.run(cmd, cwd=REPO_ROOT)
    return res.returncode


def handle_cli_init() -> int:
    """Handle `firmwareloop init` command."""
    print("============================================================")
    print("  FirmwareLoop Multi-Agent Project Initializer (v0.0.8)")
    print("============================================================")
    cwd = os.getcwd()
    print(f"[*] Initializing multi-agent guidelines & bench config in:\n    {cwd}\n")
    res = handle_fw_init_project({"target_dir": cwd, "overwrite": False})
    if res.get("ok"):
        for f in res.get("created_files", []):
            print(f"  [+] Created: {f}")
        if not res.get("created_files"):
            print("  [*] All agent instruction files (AGENTS.md, CLAUDE.md, GEMINI.md, lab.yaml, .mcp.json) already exist.")
        print("")
        print("============================================================")
        print("[+] Done! All AI Coding Agents (Claude Code, Qoder, Antigravity, Cursor) are now ready to operate in this repository.")
        print("============================================================")
        return 0
    else:
        print(f"[-] Initialization failed: {res.get('message')}")
        return 1


def print_cli_help() -> None:
    print("""FirmwareLoop (fwloop) — AI Agent Firmware Engineering & Lab Automation Platform (v0.0.8)

Usage:
  fwloop [command]   (or: firmwareloop [command])

Commands:
  init              Initialize multi-agent rules (AGENTS.md, CLAUDE.md, GEMINI.md) & lab.yaml in current project
  update            Check and update FirmwareLoop to the latest version
  doctor            Run environment & toolchain diagnostics
  setup             Print or generate AI Agent MCP registration commands
  version, -v       Show current version
  help, -h          Show this help message

Default behavior (no arguments):
  Starts the Model Context Protocol (MCP) JSON-RPC 2.0 stdio server.
""")


def main() -> None:
    args = sys.argv[1:]
    if args:
        cmd = args[0].lower().strip()
        if cmd in ["init", "scaffold"]:
            sys.exit(handle_cli_init())
        elif cmd in ["update", "upgrade"]:
            sys.exit(handle_cli_update())
        elif cmd in ["doctor", "check"]:
            sys.exit(handle_cli_doctor())
        elif cmd in ["setup", "register"]:
            sys.exit(handle_cli_setup())
        elif cmd in ["version", "-v", "--version"]:
            print("FirmwareLoop v0.0.8")
            sys.exit(0)
        elif cmd in ["help", "-h", "--help"]:
            print_cli_help()
            sys.exit(0)
        elif cmd in ["mcp", "mcp-stdio", "stdio"]:
            pass  # Fall through to stdio server loop

    # MCP stdio JSON-RPC loop
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

