# FirmwareLoop — AI Coding Agent Guidelines

FirmwareLoop is an open-source firmware engineering and lab automation platform tailored for AI Agents.

## Dual-Tier MCP Architecture
When operating in this workspace with MCP enabled, you have access to two tiers of MCP tools:

1. **Upper-Tier Workflow MCP (`firmwareloop`)**:
   - `fw_doctor()`: Diagnostic environment check (compilers, python, COM ports, instruments).
   - `fw_build(backend="auto", configuration="Debug", clean=true)`: Compile firmware across 7 backends (CMake, Make, Keil, IAR, PlatformIO, Zephyr, ESP-IDF). Returns structured compiler diagnostics (file, line, col, message).
   - `fw_run_hil_test(gate="simulator")`: Run 12-item pytest hardware-in-the-loop test suite.
   - `fw_acceptance_scenario(mode="simulator")`: Full end-to-end acceptance run (Build -> Flash -> Reset -> UART -> Logic -> Scope -> pytest -> Report).
   - `fw_measure(instrument_type, command, instrument_name)`: Perform safe PyVISA/SCPI measurements (frequency, Vpp, voltage, current).
   - `fw_logic_capture()` / `fw_logic_decode()`: Logic analyzer protocol capture and decoding (SPI, UART, I2C).
   - `fw_get_evidence(run_id="latest")`: Retrieve run artifacts and execution evidence from `artifacts/runs/`.

2. **Lower-Tier Physical Hardware MCP (`agentic-hil`)**:
   - `probe_target()`, `flash_firmware()`, `reset_target()`, `com_session_*()`, `debug_*()`, `can_*()`.

## Core Agent Rules & Principles
1. **Evidence-Driven**: Never judge success by `exit code == 0` alone. Always inspect Build Evidence + Runtime Evidence + Measurement Evidence + Assertion.
2. **Safety First**: Never edit `lab/limits.yaml` to bypass safety checks. High-voltage/current operations outside bounds will result in `SAFETY_LIMIT`.
3. **Iteration Limit**: For automated bug fixing, maximum 3 code iterations. If still failing after 3 attempts, stop and generate a diagnostic report.
4. **Permanent Prohibitions**: Never write OTP, Fuse, Option Bytes, RDP, Secure Boot keys, or Mass Erase.
