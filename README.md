[![English](https://img.shields.io/badge/English-blue)](README.en.md)
[![简体中文](https://img.shields.io/badge/简体中文-blue)](README.md)

<div align="center">

# SkillSelector

**macOS 原生的 Agent Skill 管理面板：浏览、检索、体检 —— 全程只读**

[![CI](https://github.com/BlackArt40/SkillSelector/actions/workflows/ci.yml/badge.svg)](https://github.com/BlackArt40/SkillSelector/actions/workflows/ci.yml)
![Platform](https://img.shields.io/badge/platform-macOS%2012%2B-black)
![Arch](https://img.shields.io/badge/arch-Universal%202-blue)
[![Release](https://img.shields.io/github/v/release/BlackArt40/SkillSelector)](https://github.com/BlackArt40/SkillSelector/releases)
[![License](https://img.shields.io/badge/license-Apache%202.0-green)](LICENSE)

![主窗口（简体中文）](screenshots/main-zh.png)

</div>

SkillSelector 把散落在各个编码 Agent（Claude Code、Codex、Cursor 等）里的 Agent Skill 汇总成一个本地看板：统一浏览、跨 Agent 搜索、检查重复与符号链接、验证 MCP 配置、只读逛 Skill 市场。它**不是安装器**——应用内没有 AI、不做遥测，也绝不改动你的 Skill 文件；复制、移动、删除交给 Finder。

## ✨ 功能

### 浏览与检索

- **三栏浏览器**——侧边栏按范围与 Agent 分组，中间是可搜索、可排序的 Skill 列表，右侧详情展示简介、frontmatter、渲染后的 Markdown、关联 Agents 与安装位置；中列宽度可拖拽调整
- **字段化搜索**——普通词匹配名称 / 简介 / 已索引正文；`name:`、`desc:`、`path:`、`agent:`、`body:` 前缀只搜对应字段（如 `agent:cursor path:.agents`）。重复、MCP、规则、符号链接各页都有列内搜索栏
- **导航历史**——⌘[ / ⌘] 或菜单「前往」前进后退，⌘F 聚焦搜索框；切换侧边栏、打开详情、每次搜索各记一步历史，顶栏左侧随时回退
- **亮暗主题**——顶栏一键切换，或跟随系统
- **本地化**——英文与简体中文，跟随系统语言；Agent 行显示品牌图标，无图标的显示首字母徽章

### 重复 · 链接 · 规则

- **重复 Skill**——按 SKILL.md 正文的内容指纹，把散落各 Agent 的相同副本分组；可整组标记「已忽略」，重启后保持
- **近似重复与副本对比**——MinHash 相似度指纹找出近似组；两个副本可并排对比 frontmatter、正文与子文件差异
- **符号链接**——列出所有软链接安装（源 → 目标），目标失效时高亮警告
- **规则文件**——列出 Agent 的指示文件：`CLAUDE.md`、`AGENTS.md`、`.cursorrules`，含 `.cursor/rules`、`.claude/rules`、`.roo/rules` 等目录源与 `GEMINI.md` 层级；详情渲染 Markdown，同样只读

### MCP 检测

- 自动识别 Agent 配置里的 MCP 服务器：Codex 的 TOML、Cursor / Claude 等的 JSON、项目 `.mcp.json`
- 点「检测」执行真实的 MCP initialize 握手——stdio 服务器启动判活后回收，http/sse 发初始化请求；只读、按需触发、绝不常驻

### Skill 市场

- 按需抓取 7 个核实过的 GitHub 仓库（Anthropic 官方与 Superpowers、Vercel 等社区集合，约 680 个 Skill），按仓库分组浏览、可按来源筛选，每个 Skill 带简介与文档
- 「导入市场」可添加自定义仓库（`owner/repo` 或链接）
- 只读逛：在 GitHub 打开、复制链接、或复制 `npx skills add …` 交给生态 CLI 安装

### 诊断

- 健康报告可在应用内直接查看（与导出同样的脱敏），也可导出 JSON
- 每次「刷新」的变更历史（新增 / 修改 / 移除了哪些）保留在本地，随时回看

### 导入与授权

- 不强制授权：首次启动可直接浏览空状态，之后启动自动扫描；也可只添加项目文件夹——导入只扫描该目录，Skill 列表立即出现，不等全量扫描
- 「系统目录」导入后常驻侧栏，导入前行尾有 + 号一键导入；「全部 Skill」「全局 Skill」「重复」「符号链接」「Agents」始终可见
- 授权失效的目录出现在顶部横幅与「需要重新授权」，点一下即可重新授权

## 📸 截图

| 重复 Skill | MCP 检测 |
| --- | --- |
| ![重复 Skill（简体中文）](screenshots/duplicates-zh.png) | ![MCP 检测（简体中文）](screenshots/mcp-zh.png) |

| 规则文件 | 市场 |
| --- | --- |
| ![规则文件（简体中文）](screenshots/rules-zh.png) | ![市场（简体中文）](screenshots/catalog-zh.png) |

| Agent 编辑器 | 设置 |
| --- | --- |
| ![自定义 Agent 编辑器（简体中文）](screenshots/agent-editor-zh.png) | ![设置（简体中文）](screenshots/settings-zh.png) |

**诊断查看器**

![诊断查看器（简体中文）](screenshots/diagnostics-zh.png)

## 🤖 支持的 Agent

内置 19 个：Claude Code、Codex、Qoder、CodeBuddy、OpenCode、Cursor、Kilo Code、Cline、Roo Code、Windsurf、Gemini CLI、GitHub Copilot、Amp、Tabnine、Letta、OpenHands、Goose、Kiro、Factory Droid。

- **Roo Code** 属旧版兼容：仅在检测到已有 Skill 或在设置中手动启用时显示
- 任何本地 Skill 目录都可登记为**自定义 Agent**

## 🔐 隐私

- 本机功能完全离线运行：无遥测、无崩溃上报、无文件监视器，不捆绑任何模型
- 唯一的外联是「市场」按需抓取声明的 GitHub 来源——仅在打开该区或点刷新时请求，不轮询、不落盘
- 简介翻译是可选的云端功能：配置你自己的 API 密钥（加密保存于本机）后启用，请求只发往你选择的服务商；未配置密钥时绝不发起，应用不内置任何密钥
- 索引只存元数据（路径、归属 Agent、简介等），不复制 Skill 内容
- 目录访问走 App Sandbox 安全作用域书签，扫描范围限于注册表声明的固定路径

## 📦 安装

系统要求：macOS 12 Monterey 及更高，Universal 2（Apple Silicon 与 Intel）。

1. 从 [GitHub Releases](https://github.com/BlackArt40/SkillSelector/releases) 下载 `.dmg` 与同名的 `.sha256`。通用版适合所有 Mac；也可按机型选更小的单架构包——Apple Silicon 选 `-arm64`，Intel 选 `-x86_64`
2. 校验完整性（两个文件放同一目录）：

   ```zsh
   shasum -a 256 -c SkillSelector-1.02.dmg.sha256
   ```

   输出必须是 `SkillSelector-1.02.dmg: OK`，不是就别装。

3. 挂载 `.dmg`，把 `SkillSelector.app` 拖进「应用程序」
4. 右键点击应用 → 打开 → 确认打开

> [!NOTE]
> Gatekeeper 会拦截未公证的应用，这是预期行为。右键菜单里没有「打开」时，前往系统设置 → 隐私与安全性，点 SkillSelector 旁边的「仍然打开」。

> [!WARNING]
> 从旧版 2.x 升级后首次启动为全新状态：索引自动重建，需重新授权各目录，重复忽略标记清零。

简介翻译为可选云端功能：在设置中配置你自己的 API 密钥后可用，未配置时应用不发起任何翻译请求。

## 🔏 关于签名

发布版是 ad-hoc 签名（`codesign --sign -`）：没有 Apple 开发者证书，也未公证。

- App Sandbox 已启用，声明的权限都在 [`Packaging/SkillSelector.entitlements`](Packaging/SkillSelector.entitlements) 里
- 签名可以发现应用包在签名之后被改动
- 它证明不了发布者——任何人都能生成 ad-hoc 签名。只从本仓库的 Releases 下载，并核对 `.sha256`
- Gatekeeper 首次启动会拦截，按上面的步骤手动放行

不放心就从源码自建，走的是同一条打包脚本。

## 🛠 从源码构建

```zsh
git clone https://github.com/BlackArt40/SkillSelector.git
cd SkillSelector
swift build
zsh Scripts/package-dmg.sh 1.02
```

产物：`dist/SkillSelector.app`（通用 2）与 `dist/SkillSelector-arm64.app`、`dist/SkillSelector-x86_64.app`，三个 DMG（`SkillSelector.dmg`、`SkillSelector-1.02.dmg` 及两份单架构）和对应的 `.sha256`。

- 测试：`swift test`，CI 在每个 PR 和 push 上都会跑；macOS 12 Intel 主机用 `zsh Scripts/local-build.sh`
- 第三方依赖只有 Yams（frontmatter 解析）、GRDB（本地索引）和 MarkdownUI（Markdown 渲染）

## 🗂 项目结构

```
Sources/SkillSelectorCore/     逻辑库：领域模型、扫描器、持久化、权限、注册表、诊断
Sources/SkillSelector/         SwiftUI 应用：三栏浏览器、设置、设计 token
Tests/SkillSelectorCoreTests/  XCTest（含文档漂移与 L10n 对齐守卫）
Scripts/                       打包脚本（App 与 DMG）
Packaging/                     沙箱 entitlements
```

## 🤝 参与贡献

欢迎 Issue 与 PR。提交信息遵循 Conventional Commits；新增用户可见文案需同时补齐英文与简体中文资源文件（两侧 key 集合必须一致）。

## 📄 许可证

Apache 2.0，见 [LICENSE](LICENSE)。
