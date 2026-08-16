[![English](https://img.shields.io/badge/English-blue)](README.en.md)
[![简体中文](https://img.shields.io/badge/简体中文-blue)](README.md)

# SkillSelector

macOS 原生应用，管理本机的 Agent Skill：浏览、搜索、复制、移动、删除、创建链接。它只做这些——不是市场，不是安装器，里面也没有 AI。

![主窗口（简体中文）](screenshots/main-zh.png)

![设置（简体中文）](screenshots/settings-zh.png)

## 它能做什么

主界面是三栏浏览器：侧边栏按范围和 Agent 分组，中间是可搜索、可排序的 Skill 列表，右侧显示选中 Skill 的详情——简介、frontmatter、渲染后的 Markdown 文档、关联的 Agents 和安装位置。搜索时普通词同时匹配名称、描述和路径；给词加上 `name:`、`desc:`、`path:`、`agent:` 前缀就只搜对应字段，比如 `agent:cursor path:.agents`。

文件操作就是日常那几样：复制、移动（目标可以是任意文件夹）、创建软链接、删除。删除只进回收站，整个应用里没有永久删除的路径。

另外：

- 首次启动会引导你授权主目录（沙盒应用拿不到静默权限），之后启动自动扫描；也可以只添加项目文件夹
- SKILL.md 只读：在 Finder 里显示，或用默认编辑器打开
- 标题栏可切换亮色 / 深色，或跟随系统
- 界面为英文和简体中文，跟随系统语言

## 支持的 Agent

内置 16 个：Claude Code、Codex、Qoder、CodeBuddy、OpenCode、Cursor、Kilo Code、Cline、Roo Code、Windsurf、Gemini CLI、GitHub Copilot、Amp、Tabnine、Letta、OpenHands。

Roo Code 属于旧版兼容，只在检测到已有 Skill 或在设置里手动启用时才显示。任何本地 Skill 目录都可以登记为自定义 Agent。

## 隐私

离线运行。没有遥测、崩溃报告、文件监视器，也不捆绑模型。索引只存元数据（路径、归属 Agent、简介等），不复制 Skill 内容；目录访问走安全作用域书签，扫描范围限于注册表声明的固定路径。

## 安装

需要 macOS 14 Sonoma 或更高，Universal 2（Apple Silicon 和 Intel）。

1. 从 [GitHub Releases](https://github.com/BlackArt40/SkillSelector/releases) 下载 `.dmg` 和同名的 `.sha256`
2. 校验完整性（两个文件放同一目录）：

   ```zsh
   shasum -a 256 -c SkillSelector-1.1.0.dmg.sha256
   ```

   输出必须是 `SkillSelector-1.1.0.dmg: OK`。不是就别装。

3. 挂载 `.dmg`，把 `SkillSelector.app` 拖进 Applications
4. 右键点击应用 → 打开 → 确认打开

Gatekeeper 会拦截未公证的应用，这是预期行为。如果右键菜单里没有「打开」，前往系统设置 → 隐私与安全性，点 SkillSelector 旁边的「仍然打开」。

## 关于签名

发布版是 ad-hoc 签名（`codesign --sign -`）：没有 Apple 开发者证书，也没有公证。实际含义：

- App Sandbox 已启用，声明的权限都在 [`Packaging/SkillSelector.entitlements`](Packaging/SkillSelector.entitlements) 里
- 签名可以发现应用包在签名之后被改动
- 它证明不了发布者——任何人都能生成 ad-hoc 签名。只从本仓库的 Releases 下载，并核对 `.sha256`
- Gatekeeper 首次启动会拦截，需要按上面的步骤手动放行

不放心就从源码自建，走的是同一条打包脚本。

## 从源码构建

```zsh
swift build
zsh Scripts/package-dmg.sh 1.1.0
```

产物：`dist/SkillSelector.app`、`dist/SkillSelector.dmg`、`dist/SkillSelector-1.1.0.dmg` 和对应的 `.sha256`。

第三方依赖只有 Yams（frontmatter 解析）。测试用 `swift test`，CI 在每个 PR 和 push 上都会跑。

## 版本

`MAJOR.MINOR.PATCH`：小改动升 PATCH（1.0.1 → 1.0.2），实质性功能升 MINOR（1.1.0），重设计升 MAJOR（2.0.0）。

## 许可证

Apache 2.0，见 [LICENSE](LICENSE)。
