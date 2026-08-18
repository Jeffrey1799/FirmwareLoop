---
name: fwloop-adapter
description: 帮助用户将企业自研或第三方 Debug 探针、固件烧录工具、芯片复位脚本、串口/CAN Log 抓取工具或私有协议分析器快速接入 FirmwareLoop。当用户说"接入自研/自定义工具"、"配置私有烧录器"、"使用我们公司的 debug 脚本"或提供 GUI 上位机时触发。
---

# FirmwareLoop 自定义工具接入 Skill (fwloop-adapter)

当用户希望将公司内部自研的烧录器、复位工具、串口抓包脚本或私有硬件调试工具接入 FirmwareLoop 时，遵循以下标准化工程流程与小白用户引导规范。

## 适用场景
1. 用户拥有专属的命令行烧录工具（如 `my_flasher.exe`、`custom_flash.py`、J-Link 内部批处理脚本）。
2. 用户拥有专用的串口/CAN 抓包与日志采集工具。
3. 用户拥有私有的板卡供电或复位控制上位机。
4. **用户只有带界面（GUI）的 exe 上位机软件，不知道如何接入自动化工作流。**

---

## 面对纯 GUI 上位机软件的专项引导流程（小白友好，先探查后求助）

如果用户告知 **“我们只有一个带界面的 exe 上位机软件（需要用鼠标点按钮选择文件、点击下载/抓包），没有命令行”**，Agent **严禁直接报错或直接让用户去找人**，必须按以下**由近及远、先探查本地现场后求助同事的 4 级阶梯流程**主动引导用户：

### 阶梯 1：先让用户提供上位机所在文件夹路径（最先执行，探查本地现有资源）
Agent 首先引导用户提供上位机所在的本地目录：
> “请把您这个上位机所在的文件夹路径（如 `D:\tools\NdtDebugTool-v1.0.19`）发给我，我先帮您扫描一下目录内部的资源。”
* **Agent 内部执行动作**：
  1. 扫描同目录下是否存在对应的命令行工具（如 `_cli.exe`、`_console.exe`）；
  2. 扫描同目录下是否有使用说明书（`shouce.md`、`readme.txt`、通信协议规范文档）；
  3. 扫描同目录下是否有底层通信动态库（如 `lib/USBIOX.DLL`、`FTD2XX.DLL`、`CH341.DLL`）或配置文件（`config.ini`）；
  4. 测试运行 `tool.exe --help`、`-h`、`-s` 探测是否存在隐藏的静默命令行开关。

### 阶梯 2：基于目录资源或引导用户提供协议/源码，Agent 编写 Python 脚本代打（无需改上位机）
如果阶梯 1 发现了底层通信库（如 `USBIOX.DLL`、`usb2io.dll`）或协议说明，或者用户能提供单片机端代码：
> “我在您的上位机目录下发现了底层通信库（如 `lib/USBIOX.DLL`）与使用手册。如果您能提供单片机端的 Bootloader 源码或通信协议，我可以直接为您编写一个纯 Python 脚本，直接与硬件通信完成烧录/抓包，完全不需要再打开那个界面软件！”
* **Agent 内部执行动作**：
  在 `lab/adapters/` 下编写 Python 驱动脚本（利用 `ctypes` 调用 DLL 或通过串口发包），直接实现标准 JSON 接口，彻底解决接入。

### 阶梯 3：如果本地资源完全不足（真正黑盒），再生成对接说明去找上位机开发同事
只有当阶梯 1 和 2 确认该上位机没有任何文档、没有任何底层库、没有协议且是纯黑盒 GUI 时，Agent 才生成《致上位机开发同事的技术说明函》：
> “我检查了上位机目录，发现它是一个纯黑盒界面程序，且缺少通信协议。您可以将以下需求直接转发给开发该上位机的同事，请他协助加几行命令行调用支持：”
```text
【需求对接】为上位机增加静默命令行调用支持（适配自动化 AI Agent）
Hi 同事，我们正在引入 FirmwareLoop 自动化工作流。为了能通过终端自动调用您的上位机执行烧录/抓包，需要您协助提供以下轻量支持（任选其一即可）：
1. 方案 A（推荐）：在现有上位机程序中，增加启动参数判断（例如 `tool.exe --cli --file <固件路径> --port <COM口>`），当传入这些参数时直接在后台静默执行核心烧录/抓包函数，无需弹出窗口；
2. 方案 B：直接编译一个对应的控制台版本（如 `tool_cli.exe`）；
3. 方案 C：如果方便，请分享一下上位机通信协议文档或底层通信动态库（DLL / Python SDK）。
执行要求：成功请 exit(0)，失败请 exit(1) 并将报错信息打印至 stdout 或写入 log 文件。感谢支持！
```

### 阶梯 4：最终兜底方案（UI 自动化 pywinauto 后台点击）
如果上位机同事也无法修改，且无法获取协议，Agent 基于 `pywinauto` 编写后台自动化脚本模拟点击按钮完成烧录/抓包。

---

## 引导用户与内部工具开发工程师的对接清单（Checklist）

当用户的自研工具缺少 CLI 接口、需要弹窗点击或行为不明确时，**Agent 应当主动提醒并引导用户，向负责开发该工具的内部工程师提供以下 5 大对接需求**：

1. **提供无界面的静默命令行接口（Headless / Non-Interactive CLI）**：
   - *说明*：Agent 无法通过屏幕点击 GUI 弹窗，工具必须支持纯命令行调用（如 `tool.exe --flash <固件路径> --chip <芯片型号>` 或提供 Python SDK/脚本），全程无需人工按键交互。
2. **严格规范退出码（Standard Exit Codes）**：
   - *说明*：如果工具报错了但退出码仍返回 0，Agent 会误判为成功。要求成功时必须 `exit(0)`，任何失败（探针未连、校验失败、超时）必须返回**非 0 退出码**（如 `exit(1)`）。
3. **标准输出与日志重定向（Stdout / Log File Export）**：
   - *说明*：Agent 需要根据工具打印的报错细节来排查代码。工具应将诊断信息输出到标准输出（stdout/stderr），或支持参数 `--log-file <path>` 导出文件。
4. **明确动态传参占位符（Parameter Mapping）**：
   - 约定工具接收的参数格式：固件路径（`{artifact_path}`）、芯片型号（`{target_chip}`）、串口号（`{uart_port}`）、波特率（`{baud}`）、探针序列号（`{probe_serial}`）。
5. **内置操作超时与复位机制（Timeout & Auto-Reset）**：
   - *说明*：工具在目标板卡无响应时需内置超时保护（防止进程死锁挂起 Agent）；烧录完成后建议支持可选的自动复位启动（如 `--reset` 参数）。

---

## 标准化接入流程

### 第一步：分析自研工具的接口特征
先查看或向用户确认该工具的调用方式：
1. **调用形式**：是可执行文件（`.exe`）、Python 脚本（`.py`）、PowerShell 脚本（`.ps1`）还是 C/C++ 动态链接库。
2. **入参要求**：
   - 固件烧录类：通常需要目标芯片型号（`{target_chip}`）、固件绝对路径（`{artifact_path}`）、探针序列号（`{probe_serial}`）。
   - 串口/日志类：通常需要 COM 端口号（`{uart_port}`）、波特率（`{baud}`）、日志输出文件（`{output_file}`）、抓取时长（`{duration_ms}`）。
3. **退出码与输出规范**：
   - 成功时返回退出码 `0`。
   - 失败时返回非 0 退出码，并在 stdout/stderr 打印具体错误原因。

### 第二步：选择接入模式并实施

#### 模式 A：配置驱动型（针对标准 CLI 工具，最推荐）
如果用户工具能够直接通过命令行参数完成任务：
1. 打开或创建 `lab/lab.yaml`。
2. 在 `custom_tools` 节点下配置命令模板（支持占位符 `{artifact_path}`, `{target_chip}`, `{uart_port}`, `{output_file}`）：
```yaml
custom_tools:
  flash:
    enabled: true
    command: "D:/MyTools/flasher.exe -c {target_chip} -f {artifact_path}"
    timeout_ms: 60000
  reset:
    enabled: true
    command: "D:/MyTools/reset_tool.exe -p {uart_port}"
    timeout_ms: 10000
  log_capture:
    enabled: true
    command: "python D:/MyTools/logger.py --port {uart_port} --out {output_file}"
    timeout_ms: 30000
```

#### 模式 B：脚本适配器型（针对复杂参数或前置处理）
如果自研工具有前置握手、环境依赖或格式转换要求：
1. 在 `lab/adapters/` 目录下创建轻量包装脚本（例如 `lab/adapters/flash_custom.py` 或 `lab/adapters/flash_custom.ps1`）。
2. 包装脚本负责：
   - 接收标准参数并调用内部自研工具；
   - 拦截并捕获原始日志，重定向落盘到 `artifacts/logs/`；
   - 输出统一的结构化 JSON（包含 `schema`, `ok`, `error_class`, `log`）。

#### 模式 C：并联 MCP 服务型（针对复杂常驻服务或 SDK）
如果自研工具本身是完整的服务：
在工程根目录的 `.mcp.json` 中并联注册自研 MCP 服务：
```json
{
  "mcpServers": {
    "fwloop": {
      "command": "uvx",
      "args": ["firmwareloop"]
    },
    "custom-debug-tool": {
      "command": "python",
      "args": ["D:/MyTools/company_mcp_server.py"]
    }
  }
}
```

### 第三步：真实物理联调验证（Dry-Run）
1. 严禁假跑！必须在真实连接硬件的前提下运行一次试运行。
2. 检查输出日志是否成功写入 `artifacts/logs/`。
3. 验证返回码与异常拦截机制（例如拔掉 USB 探针后，确认工具能正确报错并被 Agent 捕获）。

### 第四步：交付与提示
向用户展示配置位置，并说明后续在对话中可以直接使用自然语言调度：
- “*使用我们公司的烧录工具把固件刷入芯片*”
- “*启动自研抓包工具采集 5 秒串口日志*”
