# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/) 与
[Semantic Versioning](https://semver.org/)。版本记录按日期倒序。

## [0.0.6] - 2026-08-18

v0.0.6 目标：新增 `firmwareloop update` 一键终端更新命令与 CLI 调度器。

### Added

- **CLI 命令行调度器**：
  - `firmwareloop update`：终端一键拉取最新代码并热重载依赖与 entrypoints
  - `firmwareloop doctor`：直接在终端输出环境健康诊断
  - `firmwareloop setup`：输出或生成各大 Agent 的 MCP 注册指引
  - `firmwareloop version` / `--version`：查看当前版本号
  - `firmwareloop help`：查看 CLI 帮助信息
- **单元测试**：新增 CLI 命令测试用例，全量 29 项测试通过

## [0.0.5] - 2026-08-18

v0.0.5 目标：标准 Python 包打包与 CLI 入口点注册，支持 uvx 免克隆即时运行。

### Added

- **标准打包规范**：新增 `pyproject.toml`（遵循 PEP 517/621 标准），注册 `firmwareloop` 与 `fw-mcp` CLI 入口点
- **包模块化**：新增 `tools/__init__.py` 与 `tools/lib/__init__.py`
- **uvx 免克隆即时运行**：支持 `uvx --from git+https://github.com/Jeffrey1799/FirmwareLoop.git firmwareloop` 即拉即用
- **文档与示例**：更新 README.md 增加 uvx 免克隆一键配置示例

## [0.0.4] - 2026-08-18

v0.0.4 目标：交互式台架配置与硬件管理工具增强，实现零命令行干预的 Agent 对话式开发与调试。

### Added

- **交互式台架配置工具**：新增 `fw_configure_lab`，支持 Agent 在对话中直接读写 `lab/lab.yaml`（Keil/CMake 构建后端、STM32 芯片型号、串口 COM 与波特率）
- **硬件探针与串口扫描工具**：新增 `fw_scan_hardware`，自动探测 ST-LINK / J-Link 调试器、MCU 目标与活跃串口
- **固件烧录与芯片复位快捷入口**：新增 `fw_flash` 与 `fw_reset` 工具
- **I2C 协议测试增强**：`fw_logic_capture` 与 `fw_logic_decode` 原生支持 I2C 速率、地址及 ACK 断言
- **单元测试套件扩充**：`tests/unit/test_mcp_server.py` 扩充至 8 项测试，全量 28 项 pytest 测试 100% 通过

## [0.0.3] - 2026-08-18

v0.0.3 目标：面向 AI Coding Agent（Antigravity CLI、Claude Code CLI、Qoder IDE 等）建立标准双层 MCP 架构与服务化接口。

### Added

- **FirmwareLoop Workflow MCP Server**：`tools/fw_mcp_server.py`（原生 JSON-RPC 2.0 stdio MCP 实现，8 个高阶工程工具：`fw_doctor` / `fw_build` / `fw_run_hil_test` / `fw_acceptance_scenario` / `fw_measure` / `fw_logic_capture` / `fw_logic_decode` / `fw_get_evidence`）
- **多 Agent MCP 注册辅助脚本**：`tools/setup-agent-mcp.ps1`（检测并输出 Claude Code、Qoder、Antigravity/Cursor 注册命令及生成项目级 `.mcp.json`）
- **Agent 项目指南**：`CLAUDE.md` 与 Antigravity Skill 定义 `skills/firmwareloop/SKILL.md`
- **MCP 单元测试套件**：`tests/unit/test_mcp_server.py`（验证协议握手、工具发现、仿真测量与构建命令构造）
- **双层 MCP 配置模板**：`.mcp.example.json` 更新为 FirmwareLoop 上层 + Agentic HIL 下层双层协同架构

### Changed

- 增强了 MCP 工具调用的超时管理与结构化 JSON 证据提取

## [0.0.2] - 2026-08-17

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