# AGENTS.md — Firmware Engineering & Lab Automation Guidelines

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
5. **Permanent Prohibitions**: Never write OTP, Fuse, Option Bytes, RDP, Secure Boot keys, or Mass Erase.
