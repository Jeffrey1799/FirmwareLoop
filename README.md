# FirmwareLoop

> 面向 AI Agent 的固件开发与实验室自动化平台（开源版）。
> 目标不是"AI 帮工程师写代码"，而是**让 AI 基于真实硬件产生的观测数据参与开发、调试、测试与回归验证**。

![Windows](https://img.shields.io/badge/windows-10%20%7C%2011-blue)
![PowerShell](https://img.shields.io/badge/powershell-7+-4E8B8B)
![Python](https://img.shields.io/badge/python-3.10%2B-3776AB)
[![CI](https://github.com/Jeffrey1799/FirmwareLoop/actions/workflows/ci.yml/badge.svg)](https://github.com/Jeffrey1799/FirmwareLoop/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

FirmwareLoop 把固件工程的完整闭环交给 AI Agent 编排：**理解工程 → 修改 → 编译 → 烧录 → 复位 → UART/CAN/Debug → 逻辑分析仪/示波器测量 → 自动测试 → PASS/FAIL → 失败分析 → 再修改 → 重新验证**。

核心原则：**优先复用现成开源/官方能力，不构建大而全的自研 Firmware Lab MCP**。所有工具是薄适配层，任何环节失败都返回结构化 JSON + 统一 Error Class（`BUILD_ERROR` / `SAFETY_LIMIT` / `TARGET_MISMATCH` …），证据自动落盘——判定功能正确必须同时有 **Build Evidence + Runtime Evidence + Measurement Evidence + Assertion**，禁止只看 `exit code == 0`。

## 架构

```
┌────────────────────────────────────────────┐
│               AI Agent (Qoder / CLI)       │
│  Code / Planning / Diagnosis / Orchestration│
└────────────────────┬───────────────────────┘
         ┌───────────┼───────────────┐
         ▼           ▼               ▼
     Shell/CLI      MCP           pytest
         │           │               │
         ▼   ┌───────┴──────┐       ▼
       tools/  Agentic HIL  Saleae  HIL 测试
         │     │            │
         ▼     ▼            ▼
   Build  Flash UART CAN    Logic
   Adapter Reset Debug      Analyzer
         │
         └─────────┬───────────────┐
                   ▼               ▼
                  DUT         PyVISA / SCPI
                               Scope / PSU / DMM / AWG
```

细节见 [AI_DEV_GUIDE.md](AI_DEV_GUIDE.md)（Agent 强制规则，设计约束由此衍生；原始内部需求文档不随仓库发布）。

## 特性

- **Build 适配**：自动探测 CMake / Make / Keil / IAR / PlatformIO 等已有构建系统，只做包装不重造；输出结构化 `firmware-build-result/v1`（含 file/line/col 诊断）
- **pytest HIL**：12 项开箱测试（boot / UART / 协议 / 电源 / PWM / 逻辑分析），无硬件自动 skip，产物 JUnit + `firmware-hil-result/v1` + evidence
- **逻辑分析**：`capture → decode → assert` 全链路（SPI / UART / I2C），Saleae MCP 或 sigrok fallback
- **仪器层**：PyVISA/SCPI，每一次写入都受 `lab/limits.yaml` 安全限制保护，超限返回 `SAFETY_LIMIT`（`raw_scpi` 刻意未实现）
- **硬件门（Agentic HIL）**：probe → 身份校验 → 动作；目标不符立即 STOP；CAN TX 默认需人工授权；Mass Erase / OTP / RDP 等永久禁止
- **仿真模式**：无硬件也能完整验收——模拟 DUT 是真实编译产物（stdio 即 UART），仪器/逻辑分析有确定性 simulator 后端
- **审计闭环**：每次运行保存 run_id / git commit / modified files / artifact sha256 / uart.log / measurements / 报告

## 快速开始（Windows 10/11 + PowerShell 7 + Python 3.10+）

```powershell
# 1. 环境体检（JSON）
.\tools\doctor.ps1 -Json

# 2. 构建示例固件（CMake + Ninja + MinGW，-Clean 强制全量重编）
.\tools\build.ps1 -Configuration Debug -Clean -Json

# 3. HIL 测试（默认 simulator：用刚编译的固件产物体模拟 DUT）
.\tools\test.ps1 -Json

# 4. 仪器测量（可离线；写操作受 limits.yaml 保护）
.\.venv\Scripts\python.exe .\tools\instrument_cli.py scope measure-frequency --instrument scope1

# 5. 一键最终验收场景（Spec §33：build→flash→reset→UART→logic→scope→pytest→报告）
.\tools\acceptance-scenario.ps1 -Json
```

预期：doctor `ok:true`；build 产出 `artifacts/build/firmware.{elf,map,bin}`；
test **12/12 PASS** 并生成 `artifacts/runs/<run_id>/`（summary.json / pytest.xml /
uart.log / measurements.json / final-report.json）。

## 与同类项目定位

| | FirmwareLoop | pytest-embedded | PlatformIO Test | Labgrid |
|---|---|---|---|---|
| 编排主体 | AI Agent | pytest | pytest | 资源调度 |
| 测量证据 | 逻辑分析 + VISA 仪器 | 串口/日志 | 基础 | 弱 |
| 安全策略 | limits.yaml + 权限模型 | 无 | 无 | 弱 |
| 迭代闭环 | build→测→改→重测（≤3 次） | 无 | 部分 | 无 |

## 双层 MCP 架构与接入模式

FirmwareLoop 提供开箱即用的**双层 MCP 架构**：
1. **上层工作流 MCP (`firmwareloop`)**：面向工程构建（Keil/CMake/Make 等 7 大后端）、pytest 12项自动化 HIL 测试、安全测量与全链路验收。
2. **下层硬件驱动 MCP (`agentic-hil`)**：面向物理探针（ST-LINK / J-Link）、JTAG/SWD 固件刷写、芯片复位、串口会话与符号级断点调试。

---

### 接入模式一：免克隆即时运行（推荐，需安装 `uv`）

无需手动 `git clone`，在任意电脑、任意单片机工程目录下，直接配置 Agent 通过 `uvx` 即时运行：

* **Claude Code CLI 注册**：
  ```bash
  claude mcp add firmwareloop -- uvx --from git+https://github.com/Jeffrey1799/FirmwareLoop.git firmwareloop
  claude mcp add agentic-hil -- uvx agentic-hil mcp-stdio
  ```

* **Qoder IDE / Cursor / Antigravity（项目 `.mcp.json` 配置）**：
  ```json
  {
    "mcpServers": {
      "firmwareloop": {
        "command": "uvx",
        "args": [
          "--from", "git+https://github.com/Jeffrey1799/FirmwareLoop.git",
          "firmwareloop"
        ]
      },
      "agentic-hil": {
        "command": "uvx",
        "args": ["agentic-hil", "mcp-stdio"]
      }
    }
  }
  ```

---

### 接入模式二：本地全局共享模式（克隆一次，离线可用）

1. **克隆与环境初始化**：
   ```powershell
   git clone https://github.com/Jeffrey1799/FirmwareLoop.git D:\Tools\FirmwareLoop
   cd D:\Tools\FirmwareLoop
   uv pip install -e .
   ```
2. **全局注册到各大 Agent**：
   * **Claude Code CLI**：
     ```bash
     claude mcp add firmwareloop -- "D:\Tools\FirmwareLoop\.venv\Scripts\firmwareloop.exe"
     claude mcp add agentic-hil -- "D:\Tools\FirmwareLoop\.venv\Scripts\agentic-hil.exe" mcp-stdio
     ```
   * **Qoder IDE**：
     ```bash
     qoder.cmd mcp add firmwareloop -- "D:\Tools\FirmwareLoop\.venv\Scripts\firmwareloop.exe"
     qoder.cmd mcp add agentic-hil -- "D:\Tools\FirmwareLoop\.venv\Scripts\agentic-hil.exe" mcp-stdio
     ```

---

### 3. 在任意工程中纯对话开发
在你的任意单片机工程目录下启动 Agent，直接通过自然语言交互：
* “*帮我将当前工程设为 Keil5 编译，目标芯片是 STM32F103C8T6，串口为 COM5*” → Agent 自动调用 `fw_configure_lab`
* “*扫描已连接的 ST-LINK / J-Link 调试器*” → Agent 自动调用 `fw_scan_hardware`
* “*编译当前 Keil 工程并刷入板子，复位后读取串口输出*” → Agent 自动闭环调用 `fw_build`、`fw_flash`、`fw_reset`

## 目录结构

```
├── tools/            fw_mcp_server / setup-agent-mcp / doctor / build / test /
│                     flash / reset / can / logic_* / instrument_cli / acceptance-scenario
├── tests/            unit/ (mcp_server) / hil/ / plans/ / safety/ / backend/
├── lab/              lab.example.yaml / limits.example.yaml / protocol-decode.yaml
├── test-plans/       smoke.yaml / real-smoke.yaml / regression.yaml
├── demo-firmware/    示例固件（CMake；宿主编译模拟 MCU，闭环验证载体）
├── demo-make/        示例固件（Make；构建测试载体）
├── docs/             DEPENDENCY_MATRIX / REUSE_PLAN / V0.0.2_GAP_VERIFICATION
├── pyproject.toml    标准 Python 包配置与 CLI 入口声明 (v0.0.5)
├── .mcp.example.json 双层 MCP 配置模板（firmwareloop + agentic-hil）
├── CLAUDE.md         Claude Code CLI 指南
└── AI_DEV_GUIDE.md   AGENT 强制规则
```

## 能力验证状态（v0.0.5）

> 状态定义：`Implemented`（已实现）/ `Simulator Validated`（模拟验证）/
> `Real Hardware Validated`（真机验证）/ `Experimental` / `Not Implemented`

| 能力 | 状态 |
|---|---|
| 双层 MCP 服务（12 个工作流与硬件工具） | ✅ Implemented + Protocol Validated（28/28 测试通过） |
| uvx 免克隆即时运行（Zero-Clone Mode） | ✅ Implemented + PEP 517/621 Validated |
| Build：keil (UV4.exe) / cmake / make / platformio / iar / zephyr / esp-idf | ✅ Implemented + Multi-backend Validated |
| pytest HIL（12 项，simulator） | ✅ Implemented + Simulator Validated |
| pytest HIL（real UART） | ⚠️ Implemented（Agentic HIL 插件已就绪）→ Real Hardware Validated 待 DUT |
| Agentic HIL MCP（42 硬件工具） | ✅ Implemented + discovery 验证 → 真机待 DUT |
| 逻辑分析 capture/decode/assert（I2C/SPI/UART） | ✅ Simulator Validated → Real Hardware Validated 待 LA |
| VISA 仪器（simulator） | ✅ Simulator Validated → Real Hardware Validated 待仪器 |
| Safety Policy（limits.yaml） | ✅ Implemented（simulator 校验）→ 外置权威配置 |
| 自动修复闭环（M6 载体） | ✅ Simulator Validated → Real Hardware Validated 待 DUT |

## 里程碑状态

| 里程碑 | 状态 |
|---|---|
| M0 Doctor / M1 Build / M3 pytest HIL / M4 Logic / M5 Instruments | ✅ 已达成（含 CI 无硬件绿） |
| M2 真实 DUT | 🟡 环境就绪（Agentic HIL 已集成，42 MCP 工具已 discovery），接真实硬件后验收 |
| M6 自动修复闭环 | ✅ 仿真链路验证（缺陷注入 → 观测捕获 → 结构化失败报告） |

## 接入真实硬件

1. `Copy-Item lab\lab.example.yaml lab\lab.yaml`，填入 **COM 口 / 目标身份 / 探针序列号 / 仪器 resource**（真实值永不入库）
2. `agentic-hil adopt-hardware` 载入探针（CLI 已含于 venv）
3. `.\tools\doctor.ps1 -Json` 复核
4. `probe_target` 确认目标身份后，`.\tools\acceptance-scenario.ps1 -Hardware agentic-hil -Json`

## 贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。版本记录见 [CHANGELOG.md](CHANGELOG.md)，安全相关见 [SECURITY.md](SECURITY.md)。

## License

[MIT](LICENSE) © Jeffrey1799。第三方组件（Agentic HIL / Logic 2 / PyVISA / pytest / CMake / Ninja / MinGW）归各自作者所有；本项目只做薄适配层。