# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/) 与
[Semantic Versioning](https://semver.org/)。版本记录按日期倒序。

## [0.1.0] - 2026-08-17

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
- **M6 闭环演示**：`tools/acceptance-scenario.ps1` 一键复现 Spec §33 最终验收
  场景，产出 `final-report.json`；缺陷注入→观测捕获→结构化失败报告已验证
- **CI**：GitHub Actions 无硬件全绿流水线（doctor→build→HIL→scenario）
- **文档**：AI_DEV_GUIDE.md（Agent 强制规则）、
  docs/agentic-hil-integration.md（42 个 MCP 工具映射）、README

### Changed

- 项目名统一为 **FirmwareLoop**（原名占位 Open Embedder Alternative）

## [未发布]

- 真实硬件验收记录（M2 完成态：probe/flash/reset/UART 实测）
- 真实 VISA 仪器 SCPI 覆写示例
- Saleae Logic 2 MCP 实测验证