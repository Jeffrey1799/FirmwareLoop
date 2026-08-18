# Security Policy

FirmwareLoop 的工具链**刻意禁止**以下操作（任何变更不得放宽）：

- Mass Erase、OTP / Fuse / Option Bytes 写入、设置 RDP
- 修改 Secure Boot、生产锁、签名密钥
- 无限制 Raw SCPI / Raw Debugger Shell
- 无界电压/电流输出

以上由 `lab/limits.yaml`（Safety Limit 校验）+ Agentic HIL 权限模型 +
`AI_DEV_GUIDE.md` 强制规则共同执行；`tools/instrument_cli.py` 未实现
`raw_scpi` 命令。

## 安全报告

发现漏洞或安全相关问题，请**不要**公开 issue。通过 GitHub 的
Security Advisory 页面上报，或邮件联系仓库维护者（邮件地址见 commit 作者信息）。
请在报告中说明：影响面（工具/风险操作）、复现条件、建议修复。

## 自检清单（维护者发布前）

- [ ] `lab/limits.yaml` 未被放宽（`max_voltage_v` / `max_current_a` / 白名单）
- [ ] agentic-hil 配置中 `allow_raw_debugger_commands` 与 `allow_mass_erase` 为 false
- [ ] 项目中无真实 COM 口 / 探针序列号 / IP / 密钥（搜索 `port:` / `serial:`）
- [ ] CI 流水线在最小权限 runner 上运行（默认 ubuntu-latest 无硬件拓扑）