# FirmwareLoop (`fwloop`)

> **面向 AI Agent 的嵌入式固件开发、硬件在环测试（HIL）与实验室自动化 MCP 工具集。**
> 赋能 Claude Code、Qoder、Antigravity、Cursor 等 AI 智能体直接操作物理硬件，打通从代码编译、探针烧录、芯片复位到串口交互、逻辑分析仪抓包与示波器测量的完整开发闭环。

![Windows](https://img.shields.io/badge/windows-10%20%7C%2011-blue)
![PowerShell](https://img.shields.io/badge/powershell-7+-4E8B8B)
![Python](https://img.shields.io/badge/python-3.10%2B-3776AB)
[![PyPI](https://img.shields.io/pypi/v/firmwareloop.svg)](https://pypi.org/project/firmwareloop/)
[![CI](https://github.com/Jeffrey1799/FirmwareLoop/actions/workflows/ci.yml/badge.svg)](https://github.com/Jeffrey1799/FirmwareLoop/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## 为什么需要 FirmwareLoop？（定位与作用）

传统的 AI 编程助手（LLM）通常只能停留在**“纯软件文本生成”**阶段。在单片机与嵌入式领域，AI 面临严重的断层：**看不到编译报错行列、无法操作物理烧录器、读取不到串口输出，更无法测量真实的电信号与总线波形**。

**FirmwareLoop 作为一个标准的 Model Context Protocol (MCP) 服务器，充当了 AI Agent 与物理硬件之间的桥梁**：
* **赋予 AI 动手能力**：让 Agent 自主调用 Keil5 / CMake 编译固件，并通过 ST-LINK / J-Link / DAPLink 烧录到目标 MCU 并硬件复位。
* **赋予 AI 观测能力**：让 Agent 能够监听 UART 串口会话、捕获并解码 I2C/SPI 总线数据，甚至读取示波器与程控电源的真实物理量。
* **软硬件自动排障闭环**：当硬件运行异常时，Agent 基于捕获到的真实证据（编译器诊断、I2C NACK、串口 Panic、示波器异常电压）自动定位并修改 C/C++ 源码，重新烧录验证，直到测试全绿。

---

## 核心功能与 MCP 工具矩阵

FirmwareLoop 为 AI Agent 暴露了开箱即用的 MCP 工具，涵盖 5 大核心领域：

| 领域 | 核心 MCP 工具 | 功能说明 |
|---|---|---|
| **构建与体检** | `fw_doctor` <br> `fw_build` | 环境工具链诊断；自动调度 Keil MDK 5 (`UV4.exe`)、CMake、Make、PlatformIO 等编译固件并提取精确定位到行列的诊断日志。 |
| **硬件与探针** | `fw_scan_hardware` <br> `fw_flash` <br> `fw_reset` | 自动扫描连接的 ST-LINK / J-Link / DAPLink 探针与串口；直连 SWD 接口执行固件烧录与芯片硬件复位。 |
| **总线与协议** | `fw_logic_capture` <br> `fw_logic_decode` | 驱动逻辑分析仪（Saleae / Sigrok）捕获数字信号；自动解码并断言 I2C 地址/ACK、SPI 帧与串口数据完整性。 |
| **测试与测量** | `fw_run_hil_test` <br> `fw_measure` <br> `fw_acceptance_scenario` | 一键运行 12 项 pytest 自动化硬件在环测试；安全读取 PyVISA 示波器（频率/Vpp）与程控电源（电流/电压）。 |
| **工程与脚手架** | `fw_init_project` <br> `fw_configure_lab` <br> `fw_get_evidence` | 一键生成 `AGENTS.md` / `CLAUDE.md` / `GEMINI.md` 多 Agent 指南；自然语言修改芯片型号与台架配置；提取全链路审计证据。 |

---

## 核心设计原则

1. **真实硬件优先与零伪造原则（Real-Hardware-First & Zero-Fake）**：
   开发过程中，若探针未插、MCU 未上电、COM 串口占用或编译器缺失，系统**严格抛出明确异常（Fail-Closed）并输出可操作的排查与安装指引**，绝不伪造假成功数据。
2. **安全沙盒保护（Safety Gate）**：
   所有物理仪器写操作强制受 [`lab/limits.yaml`](lab/limits.example.yaml) 限制，永久禁止超压超流与擦除安全密钥。
3. **全电脑全局通用（Zero Config per Project）**：
   通过 `uv tool install firmwareloop` 全局安装一次，所有 STM32 / Keil 项目均可直接由 Agent 唤起使用。

---

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

---

## 极速起步（3 步搞定）

无论你使用 **Google Antigravity**、**Claude Code**、**Qoder** 还是 **Cursor**，只需以下 3 步即可开始 AI 驱动的单片机自动化开发：

### 第一步：全局安装核心 CLI 工具

从 PyPI 官方源安装（全电脑仅需执行一次）：

```bash
uv tool install firmwareloop
uv tool install agentic-hil
```

---

### 第二步：全局注册到各大 AI Agent

按你日常使用的 Agent 执行对应的注册命令（全电脑仅需配置一次）：

1. **Google Antigravity / Gemini CLI（全自动配置，推荐）**：
```bash
fwloop setup
```
> **说明**：该命令会自动将双层 MCP 写入 Antigravity 全局配置（`~/.gemini/config/mcp_config.json`），并全自动将全套技能包同步到全局 Skill 目录。

2. **Claude Code CLI**：
```bash
claude mcp add --scope user fwloop -- fwloop
claude mcp add --scope user agentic-hil -- agentic-hil mcp-stdio
```

3. **Qoder IDE**：
```bash
qoder.cmd mcp add --global fwloop -- fwloop
```

4. **Cursor / 其他 IDE**（在工程根目录的 `.mcp.json` 中并联配置）：
```json
{
  "mcpServers": {
    "fwloop": {
      "command": "fwloop"
    },
    "agentic-hil": {
      "command": "agentic-hil",
      "args": ["mcp-stdio"]
    }
  }
}
```

---

### 第三步：在你的单片机工程中开启自动化

进入你的任意单片机工程根目录（如 STM32 Keil / CMake / IAR / PlatformIO 项目）：

1. 一键生成智能体规范、MCP 描述与台架模板：
```bash
fwloop init
```

2. 接入真实硬件（配置串口与探针）：
根据提示打开工程目录下的 `lab/lab.yaml`，填入你的串口号（如 `COM5`）、目标芯片型号（如 `STM32F103C8`）与编译器类型（如 `keil` 或 `cmake`）。

3. 打开 AI Agent 对话框，直接用自然语言调度：
- “*执行 `fw_doctor()` 检查我的硬件和编译器连接状态*”
- “*帮我编译当前单片机代码，并刷入开发板运行*”
- “*运行 HIL 自动化测试，抓取串口 Log 并验证开机状态*”

---

### 核心命令职责速查

| 命令 | 适用级别 | 核心作用 | 使用时机 |
|---|---|---|---|
| **`fwloop setup`** | **系统全局级** | 给各大 Agent（Antigravity / Claude Code）配置全局 MCP 与同步技能包 | **全电脑只需跑 1 次** |
| **`fwloop init`** | **工程项目级** | 在当前单片机代码目录下生成 `AGENTS.md`、`GEMINI.md`、`CLAUDE.md` 与台架配置 | **每个新单片机项目跑 1 次** |
| **`fwloop doctor`** | **环境诊断** | 检查编译器（Keil/GCC）、Python 环境、串口与探针连接健康度 | 随时排查环境时使用 |
| **`fwloop update`** | **自动更新** | 一键自动拉取最新代码并热重载依赖 | 升级工具版本时使用 |

---

### 进阶：免克隆即时运行模式（Zero-Clone Mode）

如果不想使用全局安装，也可配置 Agent 通过 `uvx` 临时拉取即时运行：

1. Claude Code CLI 注册：
```bash
claude mcp add fwloop -- uvx firmwareloop
claude mcp add agentic-hil -- uvx agentic-hil mcp-stdio
```

2. 工程 `.mcp.json` 配置：
```json
{
  "mcpServers": {
    "fwloop": {
      "command": "uvx",
      "args": ["firmwareloop"]
    },
    "agentic-hil": {
      "command": "uvx",
      "args": ["agentic-hil", "mcp-stdio"]
    }
  }
}
```

---

### 接入模式三：源码二次开发模式（本地 Git 克隆）

适合需要修改 FirmwareLoop 源码或离线开发的用户：

1. 克隆与环境初始化：
```powershell
git clone https://github.com/Jeffrey1799/FirmwareLoop.git D:\Tools\FirmwareLoop
cd D:\Tools\FirmwareLoop
uv pip install -e .
```

2. 注册到 Claude Code：
```bash
claude mcp add fwloop -- "D:\Tools\FirmwareLoop\.venv\Scripts\fwloop.exe"
claude mcp add agentic-hil -- "D:\Tools\FirmwareLoop\.venv\Scripts\agentic-hil.exe" mcp-stdio
```

---

### 常用 CLI 终端命令

本项目支持名称兼容，`fwloop` 与 `firmwareloop` 完全等价：

1. 在任意单片机工程根目录下一键初始化多 Agent 规范（AGENTS.md, CLAUDE.md, GEMINI.md）与台架配置：
```bash
fwloop init
```

2. 自动检查并更新至最新版本（自动拉取最新代码并热重载依赖）：
```bash
fwloop update
```

3. 环境健康体检与依赖诊断：
```bash
fwloop doctor
```

4. 查看或生成各大 Agent MCP 注册指令：
```bash
fwloop setup
```

5. 查看当前版本：
```bash
fwloop version
```

---

### 卸载与清理

如果需要从系统中卸载 FirmwareLoop：

1. 一键卸载全局 CLI 工具（干净彻底，不残留垃圾文件）：
```bash
uv tool uninstall firmwareloop
uv tool uninstall agentic-hil
```

2. 从 Claude Code 中移除全局 MCP 注册：
```bash
claude mcp remove --scope user fwloop
claude mcp remove --scope user agentic-hil
```

---

### 在任意工程中纯对话开发

在你的任意单片机工程目录下启动 Agent，直接通过自然语言交互：
* “*帮我将当前单片机工程初始化为 FirmwareLoop 项目*” → Agent 自动调用 `fw_init_project` 生成 `AGENTS.md`、`CLAUDE.md`、`GEMINI.md` 与 `lab/lab.yaml`
* “*帮我将当前工程设为 Keil5 编译，目标芯片是 STM32F103C8T6，串口为 COM5*” → Agent 自动调用 `fw_configure_lab`
* “*扫描已连接的 ST-LINK / J-Link 调试器*” → Agent 自动调用 `fw_scan_hardware`
* “*编译当前 Keil 工程并刷入板子，复位后读取串口输出*” → Agent 自动闭环调用 `fw_build`、`fw_flash`、`fw_reset`

---

## 特性

- **多 Agent 规范体系**：自动生成 `AGENTS.md`、`CLAUDE.md`、`GEMINI.md` 与 `skills/firmwareloop/SKILL.md`，支持主流 Agent 无缝协同
- **Build 适配**：自动探测 Keil (UV4.exe) / CMake / Make / IAR / PlatformIO 等已有构建系统，只做包装不重造；输出结构化 `firmware-build-result/v1`（含 file/line/col 诊断）
- **pytest HIL**：12 项开箱测试（boot / UART / 协议 / 电源 / PWM / 逻辑分析），无硬件自动 skip，产物 JUnit + `firmware-hil-result/v1` + evidence
- **逻辑分析**：`capture → decode → assert` 全链路（I2C / SPI / UART），Saleae MCP 或 sigrok fallback
- **仪器层**：PyVISA/SCPI，每一次写入都受 `lab/limits.yaml` 安全限制保护，超限返回 `SAFETY_LIMIT`（`raw_scpi` 刻意未实现）
- **硬件门（Agentic HIL）**：probe → 身份校验 → 动作；目标不符立即 STOP；CAN TX 默认需人工授权；Mass Erase / OTP / RDP 等永久禁止
- **仿真模式**：无硬件也能完整验收——模拟 DUT 是真实编译产物（stdio 即 UART），仪器/逻辑分析有确定性 simulator 后端
- **审计闭环**：每次运行保存 run_id / git commit / modified files / artifact sha256 / uart.log / measurements / 报告

---

## 与同类项目定位

| | FirmwareLoop | pytest-embedded | PlatformIO Test | Labgrid |
|---|---|---|---|---|
| 编排主体 | AI Agent | pytest | pytest | 资源调度 |
| 测量证据 | 逻辑分析 + VISA 仪器 | 串口/日志 | 基础 | 弱 |
| 安全策略 | limits.yaml + 权限模型 | 无 | 无 | 弱 |
| 迭代闭环 | build→测→改→重测（<=3 次） | 无 | 部分 | 无 |

---

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
├── pyproject.toml    标准 Python 包配置与 CLI 入口声明 (v0.0.10)
├── .mcp.example.json 双层 MCP 配置模板（firmwareloop + agentic-hil）
├── AGENTS.md         通用智能体规范（Antigravity / Qoder / Cursor 等）
├── CLAUDE.md         Claude Code CLI 指南
├── GEMINI.md         Antigravity / Gemini CLI 指南
└── AI_DEV_GUIDE.md   AGENT 强制规则
```

---

## 能力验证状态（v0.0.10）

> 状态定义：`Implemented`（已实现）/ `Simulator Validated`（模拟验证）/
> `Real Hardware Validated`（真机验证）/ `Experimental` / `Not Implemented`

| 能力 | 状态 |
|---|---|
| 双层 MCP 服务（13 个工作流与硬件工具） | Implemented + Protocol Validated（31/31 测试通过） |
| 一键多 Agent 脚手架（fwloop init / fw_init_project） | Implemented + Multi-Agent Validated |
| 自定义/私有调试工具接入 Skill（fwloop-adapter） | Implemented + Multi-Skill Validated |
| 一键终端更新（fwloop update） | Implemented + Auto-updater Validated |
| uvx 免克隆即时运行（Zero-Clone Mode） | Implemented + PEP 517/621 Validated |
| Build：keil (UV4.exe) / cmake / make / platformio / iar / zephyr / esp-idf | Implemented + Multi-backend Validated |
| pytest HIL（12 项，simulator） | Implemented + Simulator Validated |
| pytest HIL（real UART） | Implemented（Agentic HIL 插件已就绪）-> Real Hardware Validated 待 DUT |
| Agentic HIL MCP（42 硬件工具） | Implemented + discovery 验证 -> 真机待 DUT |
| 逻辑分析 capture/decode/assert（I2C/SPI/UART） | Simulator Validated -> Real Hardware Validated 待 LA |
| VISA 仪器（simulator） | Simulator Validated -> Real Hardware Validated 待仪器 |
| Safety Policy（limits.yaml） | Implemented（simulator 校验）-> 外置权威配置 |
| 自动修复闭环（M6 载体） | Simulator Validated -> Real Hardware Validated 待 DUT |

---

## 接入真实硬件

1. `Copy-Item lab\lab.example.yaml lab\lab.yaml`，填入 **COM 口 / 目标身份 / 探针序列号 / 仪器 resource**（真实值永不入库）
2. `agentic-hil adopt-hardware` 载入探针（CLI 已含于 venv）
3. `.\tools\doctor.ps1 -Json` 复核
4. `probe_target` 确认目标身份后，`.\tools\acceptance-scenario.ps1 -Hardware agentic-hil -Json`

---

## 贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。版本记录见 [CHANGELOG.md](CHANGELOG.md)，安全相关见 [SECURITY.md](SECURITY.md)。

---

## License

[MIT](LICENSE) © Jeffrey1799。第三方组件（Agentic HIL / Logic 2 / PyVISA / pytest / CMake / Ninja / MinGW）归各自作者所有；本项目只做薄适配层。