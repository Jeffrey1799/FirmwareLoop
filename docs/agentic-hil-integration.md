# Agentic HIL 集成记录（M2）

> 本文件按 Spec §32 的要求记录 **实际安装验证** 的 Agentic HIL 能力。
> 版本：当前 `.venv` 内 `agentic-hil`（2026-08 安装）。工具 schema 以本文件为准，
> 不依赖旧文档猜测参数（Spec §32 禁止）。

## 安装与初始化

```powershell
uv pip install --python .venv\Scripts\python.exe agentic-hil pyocd
.\.venv\Scripts\agentic-hil.exe init        # 生成项目配置（AppData 项目级）
.\.venv\Scripts\doctor.ps1 -Json            # 应显示 agentic_hil=ok
```

`init` 生成配置时授予全部权限，但 `allow_raw_debugger_commands` 与
`allow_mass_erase` 为 false（二者为 true 会使 flash 拒绝执行）—— 与 Spec §2
禁止清单一致。

## MCP 协议验证（已实测）

`.mcp.json` 使用 stdio 通道（无参数，按项目根 cwd 定位配置）：

```json
{
  "agentic-hil": {
    "type": "stdio",
    "command": ".venv\\Scripts\\agentic-hil.exe",
    "args": ["mcp-stdio"],
    "timeout": 120000
  }
}
```

JSON-RPC 握手与 `tools/list` 已验证（返回 42 个工具）。

## 工具清单（已 discovery 确认）与 Spec 能力映射

| Spec 能力 (§5.1) | Agentic HIL 工具 | 说明 |
|---|---|---|
| probe | `probe_target` / `debugger_probes_list` / `debugger_info` | 探测并校验目标身份（§9 identity verify） |
| flash | `flash_firmware` / `artifact_upload` | 仅允许 artifact 校验后的固件映像 |
| reset | `reset_target` | 复位 DUT |
| debug | `debug_start_session` / `debug_stop_session` / `debug_set_breakpoint` / `debug_list_breakpoints` / `debug_clear_breakpoints` / `debug_continue` / `debug_halt` / `debug_get_stop_reason` / `debug_symbol_info` / `debug_dump_symbol_ihex` | 寄存器/符号级调试（§SHOULD 能力） |
| serial_read/write | `com_session_start` / `com_session_stop` / `com_read` / `com_write` / `com_ports_list` | UART 会话模型（§11：session/read/write/expect） |
| CAN | `can_session_start` / `can_session_stop` / `can_send` / `can_read` / `can_buses_list` | CAN 会话模型（§12：session/send/read/filter 由会话参数表达） |
| test adapter | `test_reactor_run` / `test_reactor_status` / `test_reactor_stop` / `bench_run_start` / `bench_run_status` / `bench_run_stop` | pytest HIL 集成（§18）与 bench 编排 |
| 错误分类 | `classify_last_error` / `get_last_report` | 与 spec §22 Error Class 对齐 |
| 权限/审计 | `project_config_describe` / `project_config_set` / `project_config_reload_description` / `project_config_adopt_hardware` / `project_config_create` | 权限模型落地（§24），只能收窄不能放宽 |
| 恢复 | `hardware_recover` | 硬件卡死恢复（需 operator 声明） |

## 与本地工具的分工

- 优先走 Agentic HIL：probe / flash / reset / UART / CAN / debug / test adapter
- 本地 wrapper 仅作为 fallback（`tools/flash.ps1` / `tools/can.ps1` / `tools/reset.ps1`
  在 Agentic HIL 缺失时明确报 PROBE_NOT_FOUND / CONFIG_ERROR，不静默降级）

## 待接真实硬件

1. 连接调试器 + DUT 后：`agentic-hil adopt-hardware` 载入探针 ID / 后端 / COM
2. `agentic-hil doctor` 复核
3. `tools/doctor.ps1 -Json` 显示 debugger/COM 就绪
4. 先 `probe_target` 确认身份（与 `lab/lab.yaml` 的 expected_target 一致）再 flash
5. 真实 HIL：`test_reactor_run` 跑 pytest，或在 Qoder 内直接调用 MCP 工具