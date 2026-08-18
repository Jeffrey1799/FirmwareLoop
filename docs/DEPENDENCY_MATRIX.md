# FirmwareLoop Dependency Matrix

> v0.0.2 Phase 0（Gap Verification）产物。状态分类（Spec §3）：
> `READY` / `REUSE_EXISTING` / `THIN_ADAPTER_REQUIRED` / `MISSING_DEPENDENCY` /
> `CAPABILITY_GAP` / `NOT_REQUIRED`
>
> 验证方式：**本地 discovery 优先**（已安装版本、MCP tools/list、CLI --help），
> 官方文档仅作交叉确认。更新日期：2026-08-17。

## 1. 已安装依赖实况（本机验证）

| 依赖 | 版本 | 验证命令 | 状态 |
|---|---|---|---|
| PowerShell | 7.6.5 | `$PSVersionTable` | READY |
| Python | 3.11.15 | `python --version` | READY |
| Git | 2.54.0 | `git --version` | READY |
| CMake | 4.3.2 | `cmake --version` | READY |
| Ninja | 1.13.2 | `ninja --version` | READY |
| GCC (MinGW-w64) | 16.1.0 | `gcc --version` | READY |
| pytest | 9.1.1 | `pytest --version` | READY |
| PyVISA | 1.16.2 | `python -c "import pyvisa"` | READY |
| PyVISA-py | 0.8.1 | `pip list` | READY |
| pyserial | 3.5 | `python -c "import serial"` | READY |
| pyYAML | 6.0.3 | `python -c "import yaml"` | READY |
| pyOCD | 0.45.1 | `pyocd --version` | READY |
| **Agentic HIL** | **0.14.0** | `agentic-hil --version` | READY |
| sigrok-cli | 未安装 | `Get-Command sigrok-cli` | MISSING_DEPENDENCY |
| Saleae Logic 2 | 未安装（无硬件） | MCP 端口 10530 探测 | MISSING_DEPENDENCY |
| VISA 物理仪器 | 未连接 | `instrument list`（simulator） | MISSING_DEPENDENCY |
| 真实 DUT / 调试器 | 未连接 | `debugger-probes`（not_supported） | MISSING_DEPENDENCY |

## 2. Capability → 首选复用资源（Spec §3 表格 + 验证）

| Capability | Preferred Existing Resource | 本地验证 | 状态 |
|---|---|---|---|
| AI Agent | Qoder | 规格文档（docs.qoder.com/cli/mcp-servers） | REUSE_EXISTING |
| MCP Orchestration | Qoder MCP | — | REUSE_EXISTING |
| Hardware Gate | Agentic HIL | 0.14.0 已装；MCP stdio 握手 + tools/list **42 工具**已 discovery | REUSE_EXISTING |
| HIL Headless | Agentic HIL Test Reactor | `agentic-hil test-reactor --help`（--test-config/--wait-s/--detach）；`test-schema` 输出完整 JSON Schema（v2/v3/v4） | REUSE_EXISTING |
| pytest HIL | Agentic HIL pytest 插件 | **pytest11 entry point `agentic_hil` 已注册**（`pytest --trace-config` 确认 0.14.0） | REUSE_EXISTING |
| Assertions | pytest | 9.1.1 | REUSE_EXISTING |
| Saleae Logic（Agent） | Saleae 官方 MCP | docs.saleae.com/mcp/；无硬件未连 | REUSE_EXISTING（待硬件） |
| Saleae Headless | Saleae Automation API | docs.saleae.com/automation/；无硬件未连 | REUSE_EXISTING（待硬件） |
| Generic Logic fallback | sigrok-cli | **未安装** | MISSING_DEPENDENCY |
| Scope/PSU/DMM | PyVISA + Vendor SCPI | pyvisa 1.16.2 + pyvisa-py 0.8.1；simulator 后端可用 | THIN_ADAPTER_REQUIRED |
| ARM Debug | OpenOCD / pyOCD | pyocd 0.45.1 已装；openocd 未装 | THIN_ADAPTER_REQUIRED |
| CMake | cmake | 4.3.2 | READY |
| Make | GNU Make | **未装**（CI ubuntu 可 apt） | MISSING_DEPENDENCY |
| Keil | UV4 CLI | 未装 | MISSING_DEPENDENCY |
| IAR | IarBuild | 未装 | MISSING_DEPENDENCY |
| PlatformIO | pio | 未装 | MISSING_DEPENDENCY |
| Zephyr | west | 未装 | MISSING_DEPENDENCY |
| ESP-IDF | idf.py | 未装 | MISSING_DEPENDENCY |
| Vendor Programmer | Vendor CLI | 无目标设备 | NOT_REQUIRED（当前） |
| UART（pytest 默认） | agentic_hil pytest 插件 | 插件已注册（见上） | REUSE_EXISTING |
| UART（Debug fallback） | pyserial direct | 3.5（默认禁用，GAP-005） | THIN_ADAPTER_REQUIRED |

## 3. 明确禁止自研（Spec §1/§31）

| 禁止项 | 复用对象 |
|---|---|
| 新 Firmware Lab MCP | Agentic HIL MCP / Saleae MCP |
| 自研 Serial Stack | pyserial / Agentic HIL com_* |
| 自研 GDB/OpenOCD Client | pyOCD / OpenOCD / Agentic HIL debug_* |
| 自研 VISA/SCPI Framework | PyVISA |
| 自研 Logic Analyzer Framework | Saleae MCP / Automation / sigrok-cli |
| 自研 Build System | cmake/make/west/idf.py/pio/UV4/IarBuild |
| 自研 Test Framework | pytest + agentic_hil 插件 |
| 自研 MCU Programmer | Agentic HIL flash / vendor CLI |

## 4. 未决依赖（Release Gate 前必须决定）

- [ ] sigrok-cli 是否纳入 v0.0.2（无 LA 硬件时仅文档化）
- [ ] Keil/IAR/PlatformIO/Zephyr/ESP-IDF 的 CI 覆盖采用 fake executable 策略（Spec §27）
- [ ] 真实 VISA 仪器型号（决定 Profile 编写范围，Spec §21）
- [ ] 真实 DUT/调试器（决定 Agentic HIL adopt-hardware 的对象）