---
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

### Standard CLI Fallback (when MCP is not connected)
```powershell
.\tools\doctor.ps1 -Json
.\tools\build.ps1 -Configuration Debug -Clean -Json
.\tools\test.ps1 -Json
.\tools\acceptance-scenario.ps1 -Json
```

## Mandatory Rules
1. **Max 3 Code Iterations**: Never loop infinitely fixing code.
2. **Fail Closed on Safety**: Never bypass `limits.yaml`.
3. **Verify Evidence**: Ensure all evidence is captured in `artifacts/runs/<run_id>/`.
