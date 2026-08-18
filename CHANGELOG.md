# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/) 与
[Semantic Versioning](https://semver.org/)。版本记录按日期倒序。

## [0.0.12] - 2026-08-18

v0.0.12 目标：实现 `fwloop setup` 一键同时全自动配置 Google Antigravity、Claude Code 与 Qoder IDE 三大平台的全局 MCP 与 Skills。

### Added

- **三大 Agent 全局 MCP 一键全自动配置**：
  - Antigravity：自动向 `~/.gemini/config/mcp_config.json` 注入 `firmwareloop` 与 `agentic-hil`（UTF-8 No-BOM 格式）
  - Claude Code：严格遵循 Anthropic 官方规范自动向 `~/.claude.json` 的 `"mcpServers"` 注入 `fwloop` 与 `agentic-hil`
  - Qoder IDE：通过 `qoder.cmd --add-mcp` 自动注入全局 User Profile
  - 全局 Skills：自动同步 `firmwareloop` 与 `fwloop-adapter` 至 Antigravity 与 Claude Code 技能库
- **跨平台纯 Python 引擎优化**：
  - 在 `tools/fw_mcp_server.py` 内建原生配置引擎，消灭 Windows 命令行字符转义与 BOM 问题

## [0.0.11] - 2026-08-18

v0.0.11 目标：修复 `fwloop setup` 脚本在 PowerShell 严格模式与全局安装环境下的变量未定义和 `Parent` 属性解析异常。

### Fixed

- **PowerShell 严格模式与路径兼容性修复**：
  - 修复 `tools/common/fw.psm1` 中 `Get-FwRepoRoot` 在 `Set-StrictMode` 下访问 `PathInfo.Parent` 的报错，采用 `Split-Path -Parent` 递归与 `PSScriptRoot` 识别
  - 修复 `tools/setup-agent-mcp.ps1` 中旧变量 `$skillInstalled` 异常
  - 自适应全局安装模式（输出 `fwloop` 命令）与本地源码模式（输出绝对路径）

## [0.0.10] - 2026-08-18

v0.0.10 目标：打通 Google Antigravity / Gemini CLI 全局 MCP 自动注入，重构 README 为 3 步极速起步指南并建立核心命令职责速查体系。

### Added

- **Antigravity 全局 MCP 自动注入与管理**：
  - `tools/setup-agent-mcp.ps1` 与 `fwloop setup` 自动向 `~/.gemini/config/mcp_config.json` 注入 `firmwareloop` 与 `agentic-hil` 双层服务
  - 自动同步所有技能包至 Antigravity 全局技能库（`~/.gemini/antigravity-cli/skills/`）
- **README.md 极速起步深度重构**：
  - 重构为「极速起步（3 步搞定）」（全局安装 -> Agent 注册 -> 工程开启自动化）
  - 新增「核心命令职责速查表」，明确 `fwloop setup`（全局 1 次）与 `fwloop init`（每项目 1 次）的职责划分
  - 清理重复代码块，确保所有指令纯净可一键复制
- **测试与构建覆盖**：
  - 11 项单元测试 100% 通过，成功构建 wheel 与 sdist 发布包

## [0.0.9] - 2026-08-18

v0.0.9 目标：新增 `fwloop-adapter` 自定义/私有调试与烧录工具接入专属 Skill，支持纯 GUI 上位机 4 级阶梯引导与多 Agent 技能库全自动注入。

### Added

- **自定义工具与 GUI 上位机接入 Skill（fwloop-adapter）**：
  - 新增 `skills/fwloop-adapter/SKILL.md`，规范化 5 步接入流程与 3 种接入模式
  - 制定面向纯 GUI 上位机的小白友好 4 级阶梯引导流程（探查目录资源 -> Python 代码代打 -> 致开发同事技术说明函 -> UI 自动化兜底）
  - 梳理《向内部工具开发工程师对接的 5 大核心技术需求清单》（无界面 CLI、规范退出码、标准错误流、动态入参规范、超时复位）
- **台架配置模板与工具链参数扩展**：
  - `lab/lab.example.yaml` 增加 `custom_tools` 节点模板（flash / reset / log_capture）
  - `tools/flash.ps1` 与 `tools/reset.ps1` 增加 pyocd 与 jlink 参数校验
- **全局多 Agent 技能自动同步与脚手架集成**：
  - `tools/setup-agent-mcp.ps1` 自动同步所有技能包到 Antigravity 与 Claude Code 全局目录
  - `fwloop init` 脚手架自动在新工程生成 `skills/fwloop-adapter/SKILL.md`
- **README.md 深度重构**：
  - 移除所有 emoji，重构所有代码块为纯净可一键复制命令，增加「卸载与清理」章节
- **测试覆盖与构建**：
  - 11 项单元测试 100% 通过，成功构建 wheel 与 sdist 发布包

## [0.0.8] - 2026-08-18

v0.0.8 目标：新增多智能体项目脚手架 `fwloop init` 与跨 Agent 规范体系（AGENTS.md、CLAUDE.md、GEMINI.md）。

### Added

- **多 Agent 项目脚手架（Multi-Agent Scaffolding）**：
  - 新增 `fwloop init` CLI 指令与 `fw_init_project` MCP 工具，支持一键在任意工程下自动初始化通用智能体规则、台架配置与 MCP 描述
- **跨平台智能体规范体系**：
  - 生成 `AGENTS.md`（通用智能体规范）
  - 生成 `CLAUDE.md`（Claude Code CLI 规范）
  - 生成 `GEMINI.md`（Antigravity 规范）
  - 生成 `lab/lab.yaml` 台架配置与 `.mcp.json` 双层配置模板
- **单元测试扩充**：
  - 新增 `fw_init_project` 与 CLI `init` 单元测试，全量 31 项测试全部通过

## [0.0.7] - 2026-08-18

v0.0.7 目标：落实 Real-Hardware-First 与 Zero-Fake 真实开发铁律，全面升级 pyOCD / J-Link 物理探针直连驱动与严格异常阻断。

### Added

- **真实硬件直连驱动**：
  - `tools/flash.ps1` 增加 `pyocd`（ST-LINK / DAPLink）与 `jlink` 原生 SWD 固件烧录
  - `tools/reset.ps1` 增加 `pyocd` 与 `jlink` 真实硬件复位命令与看门狗
- **零伪造（Zero-Fake）铁律强制落地**：
  - 严禁在硬件/工具链不足时输出假成功结果，严格 Fail-Closed 并输出明确排查指引（`TOOLCHAIN_NOT_FOUND`, `PROBE_NOT_FOUND`, `TARGET_UNREACHABLE`）
  - 同步更新 `CLAUDE.md`、`skills/firmwareloop/SKILL.md` 与 `AI_DEV_GUIDE.md`

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