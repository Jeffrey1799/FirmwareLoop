# Contributing to FirmwareLoop

欢迎贡献。项目规模刻意保持克制：**薄适配层，复用现成工具，不做大而全的自我实现**。提交前请阅读 [AI_DEV_GUIDE.md](AI_DEV_GUIDE.md)，它定义了 Agent 规则，也定义了工程的设计约束。

## 开发守则

1. 优先复用开源/官方能力（官方 MCP → 成熟开源 MCP → 已有 CLI/API → 薄 Adapter → 最后才自定义）
2. 不重新实现 Build System / OpenOCD / VISA / 逻辑分析仪软件 / MCU Programmer
3. 每个外部进程必须有超时；每个操作返回结构化 JSON（Error Class 见 AI_DEV_GUIDE）
4. 一切硬件写入遵守 `lab/limits.yaml` 安全策略；不得放宽限制换取 PASS
5. 不硬编码 COM 口 / 探针序列号 / 用户名 / IP
6. 新功能补测试：HIL 测试放 `tests/hil/`，可无硬件跑通（simulator 模式）

## 工作流

1. Fork 并创建特性分支（`feat/xxx` 或 `fix/xxx`）
2. 提交信息遵循 Conventional Commits：`feat: ...` / `fix: ...` / `docs: ...` / `chore: ...`
3. 本地验证必须全绿后再开 PR：

```bash
pwsh -NoProfile -File tools/doctor.ps1 -Json
pwsh -NoProfile -File tools/build.ps1 -Clean -Json
pwsh -NoProfile -File tools/test.ps1 -Json
pwsh -NoProfile -File tools/acceptance-scenario.ps1 -Json
```

4. PR 描述说明：改了什么 / 为什么 / 如何验证 / 对安全或证据链的影响

## 行为准则

- 不通过降低或删除测试换取绿色
- 不扩大权限、不修改 limits 放行被拒操作
- 涉及安全策略（limits.yaml / 权限模型）的改动需在 PR 中显式标注