# FirmwareLoop v0.0.2 Reuse Plan

> Phase 0 产物。每个 Gap 的复用决策：**用哪个现成资源、禁止做什么、薄适配
> 层边界**。原则（Spec §31.6/31.8）：MCP > 官方 API/CLI > 成熟库 > 薄 Adapter；
> Adapter >300 LOC 必须说明理由。

## GAP-002 — Build Backend Dispatch

- **复用**：cmake / ninja / make / west / idf.py / pio / UV4 / IarBuild 官方 CLI（已有参考链接 Spec §17）
- **禁止**：实现解析 Keil 工程文件、重写 Zephyr/ESP-IDF 构建
- **薄适配**：`tools/build.ps1` 统一入口 + backend switch；`tools/lib/backends/`（PowerShell 函数模块）只做命令构造与输出解析；Artifact Manifest 归一（ELF/AXF/OUT/HEX/BIN）
- **CI**：cmake/make（apt 装 make）真跑；platformio 装 pio 跑 `pio run -d demo`；keil/iar/zephyr/esp-idf 用 fake executable 验证命令构造与 parser（Spec §27）

## GAP-003/004/005 — Agentic HIL 三连

- **复用（Agent Lane）**：Agentic HIL MCP tools（已 discovery 42 个：probe_target / flash_firmware / reset_target / com_session_* / can_* / debug_* / test_reactor_* / project_config_*）。**禁止**猜 CLI：`agentic-hil flash ...` 不存在（0.14.0 CLI 无 flash 子命令，已验证）——`flash.ps1` 的 agentic-hil 分支必须改为：simulator / vendor fallback / operator 提示走 MCP
- **复用（Headless Lane）**：`agentic-hil test-reactor --test-config <plan>`（本地已验 --test-config/--wait-s/--detach 参数）与 **pytest 插件 `agentic_hil`（pytest11 entry point 已注册）**
- **配置格式**：`agentic-hil test-schema` 输出权威 JSON Schema（version 2/3/4，`device:` 逻辑路由键）——GAP-004 的 `test-plans/real-smoke.yaml` 与 `.agentic-hil/testconfig.yaml` 依据它生成，**只出现逻辑设备名**（dut / dut_uart）
- **禁止**：为 Headless 自写 MCP client；pytest 默认直连 pyserial（保留为 `direct-serial` Debug fallback，默认 disabled + HARDWARE_GATE_BYPASSED 警告）

## GAP-006/007 — VISA 仪器

- **复用**：PyVISA 1.16.2（本地已装，backends: pyvisa-py 0.8.1 / NI-VISA 可选）
- **薄模块**：`tools/lib/instruments.py`（open/identify/query/normalize/timeout/close/error mapping，目标 <300 LOC），instrument_cli.py 与 pytest fixtures 都调用它
- **禁止伪造**：`backend=visa` 下任何合成波形 → `CAPABILITY_NOT_SUPPORTED`（当前 instrument_cli.py capture-waveform 硬编码 `0.00001,3.3` 且 ok=true —— **确认违规，GAP-007 必修**）
- **Profile**：按仪器官方 Programming Manual 编写（如 rigol-ds1000z）；`*IDN?` 无匹配 profile → CAPABILITY_NOT_SUPPORTED

## GAP-008 — 逻辑分析

- **Agent Lane**：Saleae 官方 MCP（docs.saleae.com/mcp/）
- **Headless Lane**：Saleae Automation API（docs.saleae.com/automation/）；fallback sigrok-cli（**当前未安装** → MISSING_DEPENDENCY，v0.0.2 若无硬件仅文档化）
- **统一证据**：`logic-capture-result/v1`（backend / real_hardware / capture / metadata）
- **禁止**：为 Headless 新建 MCP client

## GAP-009 — 安全策略外置

- **复用**：Windows `%APPDATA%\FirmwareLoop\benches\<bench-id>\limits.yaml`（authoritative）；环境变量 `FIRMWARELOOP_BENCH_CONFIG` 覆盖
- **仓库只留** `lab/limits.example.yaml`；`lab/limits.yaml` 移出跟踪
- **Fail Closed**：real hardware write + 无 authoritative config → PERMISSION_DENIED / CONFIG_ERROR，禁止 fallback 到 example
- **Tamper Test**：workspace 改 limits 不影响 trusted 配置（max 5V，repo 改 50V，请求 12V → REJECT）

## GAP-010 — Qoder MCP 机器配置

- **复用**：`agentic-hil mcp-config`（生成项目 .mcp.json）与 `agentic-hil agent-install`（用户级 MCP 注册）
- **仓库提交** `.mcp.example.json`；`.mcp.json` 移出跟踪（gitignore）
- `tools/check-qoder-mcp.ps1`：detect → verify → register → verify connection（≤300 LOC，不建配置框架）

## GAP-011/013 — 验证元数据与 Error Model

- 复用现有 JSON Result 管道；schema 增加 `execution_mode` / `simulated` / `hardware_validated`
- Error Class 增加：CAPABILITY_NOT_SUPPORTED / DEPENDENCY_DISCOVERY_REQUIRED / HARDWARE_GATE_BYPASSED / REAL_HARDWARE_REQUIRED / HARDWARE_VALIDATION_FAILED（fw.psm1 + instruments.py 两处注册）

## 明确不做（CAPABILITY_GAP → Human Approval 才允许）

| 候选 | 决策 | 理由 |
|---|---|---|
| 自研 Firmware Lab MCP | 禁止 | 违反 Spec §1；Agentic HIL + Saleae MCP 已覆盖 |
| 自研 MCP Client（headless） | 禁止 | test-reactor / pytest 插件已覆盖 |
| 自研 SCPI 框架 | 禁止 | PyVISA 已覆盖 |
| 自研波形合成（visa backend） | 禁止 | Spec §13 GAP-007 硬规则 |