# AGENTS.md

## 项目

SkillSelector 是 macOS 14 SwiftUI 应用，管理本地 Agent Skill。不是 Agent 运行器、市场、安装器、推荐系统、代码编辑器或 AI 摘要器。

## 技术栈

- Swift 6.3、SwiftUI、SwiftData、Foundation、AppKit、Security、OSLog
- 仅 Apple 系统框架，无第三方包
- macOS 14 Sonoma 最低部署
- Universal 2（Apple Silicon + Intel）
- Ad-hoc 签名，App Sandbox
- Apache License 2.0

## 构建和测试

```bash
swift build
swift test
swift test --filter SmokeTests
swift test --filter AgentRegistryTests
```

MVP 计划：`docs/superpowers/plans/2026-07-17-skillselector-mvp.md`

## 架构

两个 target 的 Swift Package：
- `SkillSelector` — SwiftUI 应用
- `SkillSelectorCore` — 领域逻辑库

关键模块：`AppModel`、`DocumentManager`、`MarkdownRenderer`、`SkillFileOperator`、`URLContainment`

## 约束

- **Skill 身份基于路径**：每条安装路径一条记录，复制是独立记录
- **无 Shell 命令字符串**：外部进程用 `executableURL` + `arguments`
- **删除只用回收站**：从不永久删除
- **无遥测、无 AI、无市场、无代码编辑器、无文件监视器**
- **无第三方包**：仅 Apple 框架
- **中英文本地化**：路径字符串和 Agent 名称不翻译
- **SKILL.md 只读**：仅 Finder 显示或默认编辑器打开

## 文档

- 产品规格：`docs/product-spec.md`
- 架构：`docs/architecture.md`
- Agent Skill 调研：`docs/agent-skill-support-research.md`
- 测试计划：`docs/test-plan.md`
- 发布指南：`docs/releasing.md`

## .gitignore

排除：`.agents/`、`.claude/`、`.codex/`、`.opencode/`、`.qoder/`、`.codebuddy/`、`.skills/`、`.worktrees/`、`.build/`、`.mimocode/`

## 提交规范

`feat:`、`fix:`、`build:`、`test:`、`docs:`
