[![English](https://img.shields.io/badge/English-blue)](README.en.md)
[![简体中文](https://img.shields.io/badge/简体中文-blue)](README.md)

# SkillSelector

macOS 原生应用，管理本机 Agent Skill。浏览、搜索、复制、移动、删除、链接本地 Skill。不是市场，不是安装器，不是 AI 工具。

## 功能

- **三栏浏览器**：左侧按范围与 Agent 分组（全部 / 全局 / 目录 / Agents），中间为 Skill 列表（搜索、排序），右侧为详情（简介、frontmatter、渲染后的 Markdown 文档、关联 Agents、位置）
- **搜索与排序**：按名称、简介、路径搜索；默认顺序 / 名称 / 路径排序
- **文件操作**：复制、移动、创建软链接、移到回收站。复制与移动可指向**任意目标文件夹**（经文件夹选择器授权）；创建链接与删除限于已授权的 Skill 根目录。删除只走回收站，绝不永久删除
- **Skill 文档**：以系统 Markdown 解析器渲染正文（标题、列表、代码块、链接白名单），frontmatter 由 Yams 解析，嵌套 YAML 不再误报
- **深色模式**：标题栏一键切换亮色 / 深色，随系统或手动指定
- **目录授权**：授权主目录或添加项目文件夹，通过安全作用域书签访问，仅扫描白名单内的固定路径
- **自定义 Agent**：将任意本地 Skill 目录登记为自定义 Agent

## 支持的 Agent

Claude Code、Codex、Qoder、CodeBuddy、OpenCode、Cursor、Kilo Code、Cline、Roo Code、Windsurf、Gemini CLI、GitHub Copilot、Amp、Tabnine、Letta、OpenHands。Roo Code 仅在检测到或手动启用时显示。可自定义 Agent 指向任意本地 Skill 目录。

## 隐私

离线运行。只存储索引元数据（路径、归属 Agent、层级、简介、来源）和安全作用域书签，**不复制 Skill 内容**。无遥测、无崩溃报告、无捆绑模型、无文件监视器。SKILL.md 只读，仅在 Finder 显示或默认编辑器打开。

## 截图

![主窗口（简体中文）](screenshots/main-zh.png)

![设置（简体中文）](screenshots/settings-zh.png)

## 系统要求

- macOS 14 Sonoma 或更高
- Universal 2（Apple Silicon + Intel）
- 英文和简体中文

## 构建

```zsh
swift build
zsh Scripts/package-dmg.sh 1.1.0
```

输出 `dist/SkillSelector.app`、`dist/SkillSelector.dmg`、`dist/SkillSelector-1.1.0.dmg` 和对应的 `.sha256`。

## 安装

1. 从 [GitHub Releases](https://github.com/BlackArt40/SkillSelector/releases) 下载 `.dmg` 和同名的 `.sha256`
2. 校验完整性（把两个文件放在同一目录）：

   ```zsh
   shasum -a 256 -c SkillSelector-1.1.0.dmg.sha256
   ```

   输出必须是 `SkillSelector-1.1.0.dmg: OK`。不是就别装。

3. 挂载 `.dmg`，拖拽 `SkillSelector.app` 到 Applications
4. 右键点击应用 → **打开** → 确认 **打开**

macOS Gatekeeper 默认阻止未公证应用。如果右键菜单没有"打开"选项，前往系统设置 → 隐私与安全性 → 点击 SkillSelector 旁边的"仍然打开"。

## 签名说明

发布版使用 **ad-hoc 签名**（`codesign --sign -`）：**没有 Apple 开发者证书，也没有经过公证**。请清楚它能与不能保证什么：

- ✅ 启用了 App Sandbox，权限声明见 [`Packaging/SkillSelector.entitlements`](Packaging/SkillSelector.entitlements)
- ✅ 签名可检测应用包在签名后是否被改动
- ❌ **无法证明发布者身份** —— ad-hoc 签名任何人都能生成。请只从本仓库的 GitHub Releases 下载，并核对 `.sha256`
- ❌ 未经 Apple 公证，Gatekeeper 首次启动会拦截，需要按上面第 4 步手动放行

不接受这个前提就从源码自建（见「构建」），产物与发布版走的是同一条打包脚本。

## 版本

版本号遵循 `MAJOR.MINOR.PATCH`。非大版本更改只递增 PATCH（1.0.1 → 1.0.2）；实质性功能变化递增 MINOR（1.1.0）；大版本重设计递增 MAJOR（2.0.0）。

## 许可证

Apache 2.0。见 [LICENSE](LICENSE)。
