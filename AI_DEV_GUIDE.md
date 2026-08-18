# AI Developer Guide — FirmwareLoop

本文档是 AI Coding Agent 在本仓库内的**强制执行规则**。任何硬件操作、构建、测试、修复闭环都必须遵守。读取本文件前：`tools/doctor.ps1 -Json` 确认环境。

---

## 0. Reuse Gate（v0.0.2 强制，Spec §2/§12/§16/§31）

任何新 Capability 开发前 **MUST** 走复用门，并先读：

```text
docs/DEPENDENCY_MATRIX.md
docs/REUSE_PLAN.md
```

```text
Configured MCP?  → 用
      ↓ NO
Official MCP?    → 用
      ↓ NO
Mature OSS MCP?  → 用
      ↓ NO
Official Vendor CLI / SDK / API? → 用
      ↓ NO
Mature CLI / Library?            → 用
      ↓ NO
Thin Adapter possible? (≤300 LOC) → 做薄适配
      ↓ NO
CAPABILITY_GAP → 必须人工批准后才可自研
```

硬规则：

- **Existing tool 不便/不熟/难配/需集成 ≠ 重写它的理由。**
- 无法联网验证可复用方案 → 返回 `DEPENDENCY_DISCOVERY_REQUIRED` 并停止，
  **禁止** "搜索失败 → 假设不存在 → 自己实现"。
- 禁止新增 MCP Server / Debugger Backend / Programmer Framework / Instrument
  Framework / Transport Framework（需人工批准）。
- Adapter 超 300 LOC 必须说明为什么现有工具不满足。
- Headless 执行禁止自写 MCP Client（用 Agentic HIL Test Reactor / pytest 插件）。
- `backend=visa` 下禁止合成数据；不支持 → `CAPABILITY_NOT_SUPPORTED`。

```text
允许：simulator backend → synthetic data
禁止：visa backend      → fake waveform / ok=true
```

---

## 1. 能力模型（Spec §5.1）

Agent 顶层只理解这些逻辑能力，不直接理解厂商工具：

```
build()  probe()  flash()  reset()  serial_read()  serial_write()
debug()  run_test()  logic_capture()  scope_measure()  power_measure()
```

不同项目只替换 backend。本仓库当前 backend：

| 能力 | 实现 | 备注 |
|---|---|---|
| build | `tools/build.ps1` | CMake/Ninja + minGW；统一 `firmware-build-result/v1` JSON |
| test | `tools/test.ps1` | pytest HIL → `firmware-hil-result/v1` + JUnit + evidence |
| flash | `tools/flash.ps1` | 占位；M2 接入 Agentic HIL / vendor CLI |
| instrument | `tools/instrument_cli.py` | PyVISA/SCPI；simulator 后端可离线验证 |
| doctor | `tools/doctor.ps1` | 环境体检，`firmware-doctor/v1` JSON |

## 2. 标准闭环（Spec §20 / §33）

接到修复任务时按此顺序执行，**最多 3 次代码迭代**：

```
read requirements → inspect source/tests → hypothesis → minimal edit
→ build → probe → flash → reset → smoke (UART boot banner)
→ pytest HIL → PASS? → report
              → NO → analyze structured evidence → next hypothesis → edit
```

硬性停止条件（命中即停，禁止自动继续）：

```yaml
agent_loop:
  max_code_iterations: 3
  max_flash_attempts_per_iteration: 2
  stop_on_hardware_mismatch: true   # target != expected_target 立即 STOP
  stop_on_permission_denied: true
  stop_on_safety_violation: true
```

## 3. 强制规则（Spec §21）

**MUST：**

- 修改前先读源码与被影响测试
- 最小修改，只动根因相关代码
- 先 Build 再 Flash；Flash 前校验 artifact 哈希与路径
- 确认目标身份（probe 后比对 expected_target，不符立即 STOP）
- 每个 HIL 运行都要保存 evidence（uart.log / measurements.json / 采集文件）
- 优先运行现有测试；失败时解析结构化错误（Error Class），不猜日志
- 修改 driver 时补/改对应测试
- 达到迭代上限即停止并输出报告

**MUST NOT：**

- 降低测试阈值、删除失败测试、注释 assertion 换取 PASS
- 用大量 sleep 掩盖同步问题
- 扩大自己的权限、修改 lab/limits.yaml 以放行被拒操作
- 写 OTP / Fuse / Option Bytes / RDP / Secure Boot / Mass Erase
- 永久关闭 watchdog / 安全检查
- 无限循环修复

## 4. 错误处理（Spec §22）

所有工具输出统一 Error Class，Agent 据此决策：

```
BUILD_ERROR  ARTIFACT_NOT_FOUND  PROBE_NOT_FOUND  TARGET_MISMATCH
FLASH_ERROR  FLASH_VERIFY_ERROR  RESET_ERROR
UART_TIMEOUT UART_BUSY  CAN_ERROR  DEBUGGER_ERROR  LOGIC_CAPTURE_ERROR
INSTRUMENT_NOT_FOUND  INSTRUMENT_TIMEOUT  MEASUREMENT_OUT_OF_RANGE
TEST_FAILED  PERMISSION_DENIED  SAFETY_LIMIT  CONFIG_ERROR  UNKNOWN_ERROR
```

典型处置：`BUILD_ERROR` → 读 diagnostics 修源码；`ARTIFACT_NOT_FOUND` → 先 build；
`TARGET_MISMATCH` → 停；`SAFETY_LIMIT` → 停，报告请求与限制；`PERMISSION_DENIED` → 停。

## 5. 证据驱动（Spec §5.3）

**禁止**仅凭 `exit code == 0` 判定功能正确。功能成立的证据链：

```
Build Evidence  +  Runtime Evidence  +  Measurement Evidence  +  Assertion
(artifacts/build/*.elf 的构建输出)   (boot banner / UART 观测)  (scope/psu 结构化测量)  (pytest assert)
```

## 6. 仪器安全（Spec §17）

任何对仪器的 **写操作** 走流水线：

```
request → read lab/limits.yaml → validate → allowed? NO → SAFETY_LIMIT（停止）
                                        → YES → execute
```

- 禁止修改 limits 后重试同一操作
- `raw_scpi` 默认不存在、禁止实现/调用
- relay 名必须在 `limits.yaml relay.allowed` 白名单内
- PSU 输出受 `max_voltage_v` / `max_current_a` / `allow_output_toggle` 约束

## 7. 权限模型（Spec §24）

| 自动允许 | 需确认 | 永久禁止 |
|---|---|---|
| build probe uart_rx can_rx 寄存器/内存读 logic capture scope/psu 测量 pytest 报告读 | flash reset uart_tx can_tx 断电/上电 relay psu/awg 输出 | mass erase OTP/fuse/option bytes/RDP/secure boot 签名密钥 raw debugger raw scpi 无界电压/电流 |

遇到需确认操作：先请求人类授权；被拒或超时按 PERMISSION_DENIED 停止。

## 8. 工具速查

```powershell
# 环境体检（JSON）
.\tools\doctor.ps1 -Json

# 构建（JSON；-Clean 强制全量重编；失败带 diagnostics）
.\tools\build.ps1 -Configuration Debug -Clean -Json

# HIL 测试（JSON；产出 artifacts/runs/<run_id>/ summary.xml/pytest.xml/uart.log/measurements.json）
.\tools\test.ps1 -Json

# 仪器测量（JSON；simulator 后端离线可测；写操作受 limits 保护）
.\.venv\Scripts\python.exe .\tools\instrument_cli.py scope measure-frequency --instrument scope1
.\.venv\Scripts\python.exe .\tools\instrument_cli.py psu measure-current --instrument psu1

# Flash（占位；未配置 backend 时 CONFIG_ERROR）
.\tools\flash.ps1 -Backend openocd -Json
```

## 9. 配置与真实值

真实 COM 口、探针序列号、仪器 IP、夹具 ID、密钥**永不入库**：
配置写 `lab/lab.yaml`（gitignored，从 `lab/lab.example.yaml` 复制）。
接入真实硬件步骤：`lab/lab.yaml` 填 dut.uart.port / target 身份 / instrument resource →
`doctor.ps1` 复核 → 先 probe 验证身份再 flash →
`test.ps1` 跑 HIL（serial 模式）。

## 10. 验收场景（Spec §33，M6 目标）

`SPI Flash 读 JEDEC ID 偶尔失败` 的完整修复流程即最终验收：
源码 → build → probe → flash → reset → UART → logic analyzer → scope →
pytest → diagnosis → fix → retest → 报告（root cause / changes / build /
artifact / uart evidence / logic evidence / scope measurements / test result / risks）。