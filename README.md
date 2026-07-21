[![English](https://img.shields.io/badge/English-blue)](README.en.md)
[![简体中文](https://img.shields.io/badge/简体中文-blue)](README.md)

# SkillSelector

macOS 原生应用，管理本地 Agent Skill。浏览、复制、移动、删除、链接、更新 Skill。不是市场，不是安装器，不是 AI 工具。

## 截图

| 主界面 | 设置界面 |
|:---:|:---:|
| ![主界面](screenshots/main-zh.png) | ![设置界面](screenshots/settings-zh.png) |

## 系统要求

- macOS 14 Sonoma 或更高
- Universal 2（Apple Silicon + Intel）
- 英文和简体中文

## 支持的 Agent

Claude Code、Codex、Qoder、CodeBuddy、OpenCode、Cursor、Kilo Code、Cline、Roo Code、Windsurf、Gemini CLI、GitHub Copilot。Roo Code 仅在检测到或手动启用时显示。可自定义 Agent 指向任意本地 Skill 目录。

## 隐私

离线运行。只存储索引记录和安全作用域书签，不复制 Skill 内容。无遥测、无崩溃报告、无捆绑模型。

文件操作限于已授权的 Skill 根目录。删除走回收站。

## 构建

```zsh
swift test
swift build
zsh Scripts/package-dmg.sh 0.1.0
zsh Tests/Packaging/package-smoke.sh 0.1.0
```

输出 `dist/SkillSelector.app`、`dist/SkillSelector.dmg` 和 `dist/SkillSelector-0.1.0.dmg`。

## 安装

1. 从 GitHub Releases 下载 `.dmg`
2. 拖拽 `SkillSelector.app` 到 Applications
3. 右键点击应用 → **打开** → 确认 **打开**

macOS Gatekeeper 默认阻止未签名应用。如果右键菜单没有"打开"选项，前往系统设置 → 隐私与安全性 → 点击 SkillSelector 旁边的"仍然打开"。

## 许可证

Apache 2.0。见 [LICENSE](LICENSE)。
