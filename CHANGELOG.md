# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/) 与
[Semantic Versioning](https://semver.org/)。版本记录按日期倒序。

## [0.0.2] - Unreleased

v0.0.2 目标：从 Simulator-first PoC 推进为 Real-Hardware-first 的可验证固件
Agent 基础设施（Gap Analysis & Remediation）。

### Added

- **GAP-002 Build Backend Dispatch**：`tools/build.ps1` 真正支持 7 个 backend
  （cmake / make / platformio / keil / iar / zephyr / esp-idf），检测优先级
  `-Backend` > 项目配置 > 强标记（west.yml/sdkconfig/...）> 通用检测；
  Artifact Manifest `firmware-artifacts/v1`（ELF/AXF/OUT/HEX/BIN 原生位置收集）
- **Backend 命令测试**：`tools/test-backends.ps1`（7 项命令构造 + 4 项 fake
  executable 执行 + cmake 真构建；无需 Keil/IAR License）
- **demo-make**：GNU Make 最小固件工程（CI make backend 真跑载体）
- **GAP-003/004/005 Agentic HIL 三连**：flash.ps1 拒绝猜测 CLI（REAL_HARDWARE_REQUIRED）；
  `test-plans/real-smoke.yaml`（逻辑设备名，v4 格式，权威 schema 校验）；
  `acceptance-scenario.ps1 -Mode real` 由 test-reactor 驱动 flash/reset/UART；
  pytest UART 三 gate（agentic-hil 默认 / direct-serial 默认禁用 +
  HARDWARE_GATE_BYPASSED）
- **GAP-006 共享仪器层**：`tools/lib/instruments.py`（open/identify/query/
  normalize/timeout/close/error mapping，<250 LOC）；instrument_cli.py 与
  pytest fixtures 共用；visa 真测量不可达即失败（不 skip）
- **GAP-007 无假波形**：visa backend 波形 → CAPABILITY_NOT_SUPPORTED；
  simulator 数据显式标记 simulated/hardware_validated=false
- **GAP-009 安全策略外置**：权威 limits 在
  `%APPDATA%\FirmwareLoop\benches\<id>\limits.yaml` 或
  `FIRMWARELOOP_BENCH_CONFIG`；repo 只留 `lab/limits.example.yaml`；
  Fail Closed + Tamper Test（tests/safety 5 项）
- **GAP-010 Qoder MCP 机器配置**：`.mcp.example.json` 提交、`.mcp.json`
  gitignored；`tools/check-qoder-mcp.ps1`（detect/verify/register）
- **GAP-011/§24**：结果携带 execution_mode/simulated/hardware_validated；
  5 个新 Error Class（CAPABILITY_NOT_SUPPORTED 等）
- **§25 Evidence 布局**：runs/<id>/ 完整包含 summary/environment/dependencies/
  build/flash/hardware.json + uart.log + logic/ + instruments/ + pytest.xml +
  final-report.json/.md

### Changed

- 修正历史版本号：`[0.1.0]` → `[0.0.1]`（版本基线对齐）
- `AI_DEV_GUIDE.md` 增加 Reuse Gate 强制流程
- `lab/limits.yaml` → `lab/limits.example.yaml`（权威策略移出仓库）
- README 增加能力验证状态表（Implemented / Simulator Validated / ...）

## [0.0.1] - 2026-08-17

首个开源版本。按原始规格（Open Embedder Alternative v1 Spec）完成集成骨架与
全部软件里程碑（无硬件 CI 可全绿）。

### Added

- **M0 Doctor**：`tools/doctor.ps1`，环境体检输出 `firmware-doctor/v1`；集成
  Agentic HIL 的真实 COM 端口枚举
- **M1 Build**：`tools/build.ps1`，自动探测 CMake/Make/Keil/IAR 等构建系统，
  输出 `firmware-build-result/v1`（artifact sha256、结构化 diagnostics、日志）
- **M2 环境**：Agentic HIL 集成（venv 安装、`init` 项目配置、MCP stdio
  discovery 42 个工具）；`tools/flash.ps1` / `tools/reset.ps1` / `tools/can.ps1`
  （CAN TX 默认人工授权）
- **M3 pytest HIL**：`tools/test.ps1` + `tests/hil/`（boot/uart/protocol/
  power/signal/logic 共 12 项），输出 `firmware-hil-result/v1` + JUnit +
  evidence（uart.log / measurements.json / audit 含 modified files）
- **M4 Logic Analyzer**：`tools/logic_capture.ps1` + `tools/logic_decode.ps1`，
  SPI / UART / I2C 三协议 capture→decode→assert，sigrok fallback + 确定性
  simulator 波形
- **M5 Instruments**：`tools/instrument_cli.py`（PyVISA/SCPI + simulator），
  每次写入经 `lab/limits.yaml` 校验（SAFETY_LIMIT），`raw_scpi` 刻意未实现
- **M6 闭环演示**：`tools/acceptance-scenario.ps1` 一键复现最终验收场景，
  产出 `final-report.json`；缺陷注入→观测捕获→结构化失败报告已验证
- **CI**：GitHub Actions 无硬件全绿流水线（doctor→build→HIL→scenario）
- **文档**：AI_DEV_GUIDE.md（Agent 强制规则）、
  docs/agentic-hil-integration.md（42 个 MCP 工具映射）、README

### Changed

- 项目名统一为 **FirmwareLoop**（原名占位 Open Embedder Alternative）

## [未发布]

- 真实硬件验收记录（M2 完成态：probe/flash/reset/UART 实测）
- 真实 VISA 仪器 SCPI 覆写示例
- Saleae Logic 2 MCP 实测验证