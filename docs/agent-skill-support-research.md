# Agent Skill 目录规则调研

> Compatibility paths document what each tool can read. SkillSelector sidebar classification is based on canonical directory ownership; compatibility entries do not create additional Agent associations.

> 基于各 Agent 官方文档或官方 GitHub 仓库，仅记录可确认信息，无法确认的字段标注"未确认"。
> 调研日期：2026-07-17

---

## Cursor

- **官方名称**：Cursor
- **官方文档 URL**：https://cursor.com/docs/skills
- **是否支持 Agent Skills**：是，遵循 [Agent Skills](https://agentskills.io) 开放标准
- **入口文件名**：`SKILL.md`
- **全局目录**：
  - `~/.agents/skills/`
  - `~/.cursor/skills/`
- **项目级目录**：
  - `.agents/skills/`
  - `.cursor/skills/`
- **是否区分全局与项目级**：是，项目级优先于全局
- **来源/更新识别方式**：未确认（文档未提及自动来源追踪）
- **备注**：
  - 兼容 Claude Code 和 Codex 目录：`.claude/skills/`、`.codex/skills/`、`~/.claude/skills/`、`~/.codex/skills/`
  - 支持嵌套子目录组织（monorepo 场景）
  - 支持从 GitHub 仓库安装 Skill
  - frontmatter 必填字段：`name`、`description`；可选字段：`paths`、`disable-model-invocation`、`metadata`
  - `name` 必须匹配父目录名，仅允许小写字母、数字和连字符

---

## Kilo Code

- **官方名称**：Kilo Code
- **官方文档 URL**：https://kilo.ai/docs/customize/skills
- **是否支持 Agent Skills**：是，遵循 [Agent Skills](https://agentskills.io) 开放标准
- **入口文件名**：`SKILL.md`
- **全局目录**：
  - `~/.kilo/skills/`
- **项目级目录**：
  - `.kilo/skills/`
- **是否区分全局与项目级**：是，项目级（`.kilo/skills/`）优先于全局（`~/.kilo/skills/`）
- **来源/更新识别方式**：
  - 支持 `skills.urls` 配置远程 Skill URL，需服务端提供 `index.json` 清单
  - 支持 `skills.paths` 配置额外本地路径
- **备注**：
  - 兼容目录：`.agents/skills/`（默认加载）、`.claude/skills/`（需启用兼容模式）
  - frontmatter 必填字段：`name`、`description`；可选字段：`license`、`compatibility`、`metadata`
  - `name` 必须匹配父目录名
  - 有 Marketplace 仓库：https://github.com/Kilo-Org/kilo-marketplace
  - 会话启动时扫描，`/reload` 可重新加载

---

## Cline

- **官方名称**：Cline
- **官方文档 URL**：https://docs.cline.bot/customization/skills
- **是否支持 Agent Skills**：是，遵循 Agent Skills 规范
- **入口文件名**：`SKILL.md`
- **全局目录**：
  - `~/.cline/skills/`（macOS/Linux）
  - `C:\Users\<username>\.cline\skills\`（Windows）
- **项目级目录**：
  - `.cline/skills/`
  - `.clinerules/skills/`（兼容）
  - `.claude/skills/`（兼容）
- **是否区分全局与项目级**：是，全局同名 Skill 优先于项目级
- **来源/更新识别方式**：未确认
- **备注**：
  - frontmatter 必填字段：`name`、`description`
  - `name` 必须匹配目录名
  - 支持通过 `/` 斜杠命令手动触发 Skill
  - 支持 `docs/`、`templates/`、`scripts/` 等子目录打包资源
  - 支持启用/禁用单个 Skill

---

## Roo Code

- **官方名称**：Roo Code
- **官方文档 URL**：https://docs.roocode.com/features/skills
- **是否支持 Agent Skills**：是，遵循 [Agent Skills](https://agentskills.io) 开放标准
- **入口文件名**：`SKILL.md`
- **全局目录**：
  - `~/.roo/skills/`（Roo 专属，高优先级）
  - `~/.agents/skills/`（跨 Agent 兼容）
  - 支持模式特定：`~/.roo/skills-{modeSlug}/`、`~/.agents/skills-{modeSlug}/`
- **项目级目录**：
  - `.roo/skills/`（Roo 专属，高优先级）
  - `.agents/skills/`（跨 Agent 兼容）
  - 支持模式特定：`.roo/skills-{modeSlug}/`、`.agents/skills-{modeSlug}/`
- **是否区分全局与项目级**：是，项目级优先于全局；`.roo/` 优先于 `.agents/`
- **来源/更新识别方式**：未确认
- **备注**：
  - 支持模式特定 Skill（`skills-code/`、`skills-architect/` 等）
  - 8 级优先级覆盖机制（项目 `.roo` 模式特定 > 项目 `.roo` 通用 > 项目 `.agents` 模式特定 > …）
  - frontmatter 必填字段：`name`、`description`；名称 1-64 字符
  - 支持符号链接（symlink）
  - 项目已关闭（2026-05-15），文档仍可参考

---

## Windsurf（Cascade）

- **官方名称**：Windsurf（Cascade）
- **官方文档 URL**：https://docs.devin.ai/desktop/cascade/skills
- **是否支持 Agent Skills**：是，遵循 [Agent Skills](https://agentskills.io) 开放标准
- **入口文件名**：`SKILL.md`
- **全局目录**：
  - `~/.codeium/windsurf/skills/`
- **项目级目录**：
  - `.windsurf/skills/`
- **是否区分全局与项目级**：是
- **来源/更新识别方式**：未确认
- **备注**：
  - 企业级系统目录：macOS `/Library/Application Support/Windsurf/skills/`、Linux `/etc/windsurf/skills/`、Windows `C:\ProgramData\Windsurf\skills\`
  - 兼容目录：`.agents/skills/`、`~/.agents/skills/`、`.claude/skills/`、`~/.claude/skills/`
  - 支持通过 UI 创建 Skill（Cascade 面板三点菜单 → Skills）
  - 支持 `@skill-name` 手动触发
  - frontmatter 必填字段：`name`、`description`

---

## Gemini CLI

- **官方名称**：Gemini CLI
- **官方文档 URL**：https://geminicli.com/docs/cli/skills/
- **是否支持 Agent Skills**：是，遵循 [Agent Skills](https://agentskills.io) 开放标准
- **入口文件名**：`SKILL.md`
- **全局目录**：
  - `~/.gemini/skills/`
  - `~/.agents/skills/`（别名，优先级高于 `.gemini/`）
- **项目级目录**：
  - `.gemini/skills/`
  - `.agents/skills/`（别名，优先级高于 `.gemini/`）
- **是否区分全局与项目级**：是，项目级（workspace）优先于全局（user）
- **来源/更新识别方式**：
  - 支持从 Git 仓库安装：`gemini skills install <url>`
  - 支持链接本地目录：`gemini skills link <path>`
  - 内置 extension skills（随扩展安装）
- **备注**：
  - 发现层级：内置 skills → extension skills → user skills → workspace skills
  - `.agents/skills/` 别名在同层级内优先于 `.gemini/skills/`
  - frontmatter 必填字段：`name`、`description`；`name` 应匹配目录名
  - 支持 `/skills list`、`/skills disable/enable`、`/skills reload` 管理命令
  - 激活时需用户确认（consent prompt）

---

## GitHub Copilot（VS Code）

- **官方名称**：GitHub Copilot（VS Code Agent Skills）
- **官方文档 URL**：https://code.visualstudio.com/docs/agent-customization/agent-skills
- **是否支持 Agent Skills**：是，遵循 [Agent Skills](https://agentskills.io) 开放标准
- **入口文件名**：`SKILL.md`
- **全局目录**：
  - `~/.copilot/skills/`
  - `~/.claude/skills/`（兼容）
  - `~/.agents/skills/`（兼容）
- **项目级目录**：
  - `.github/skills/`
  - `.claude/skills/`（兼容）
  - `.agents/skills/`（兼容）
- **是否区分全局与项目级**：是，Personal skills vs Project skills
- **来源/更新识别方式**：
  - 支持通过扩展（extension）贡献 Skill：`package.json` 中 `chatSkills` 字段
  - 社区仓库：https://github.com/github/awesome-copilot
  - 插件安装的 Skill 自动发现
- **备注**：
  - frontmatter 必填字段：`name`、`description`
  - 可选字段：`argument-hint`、`user-invocable`、`disable-model-invocation`、`context`（实验性 `fork` 模式）
  - `name` 必须匹配父目录名，仅允许小写字母、数字和连字符
  - 支持通过 `/skills` 斜杠命令触发
  - 支持 `/create-skill` AI 生成 Skill
  - 可配置额外项目级目录：`chat.agentSkillsLocations` 设置
  - 同时适用于 VS Code、Copilot CLI、Copilot cloud agent

---

## 跨 Agent 对比速查表

| 维度 | Cursor | Kilo Code | Cline | Roo Code | Windsurf | Gemini CLI | Copilot (VS Code) |
|------|--------|-----------|-------|----------|----------|------------|-------------------|
| 入口文件 | `SKILL.md` | `SKILL.md` | `SKILL.md` | `SKILL.md` | `SKILL.md` | `SKILL.md` | `SKILL.md` |
| 全局目录 | `~/.cursor/skills/` `~/.agents/skills/` | `~/.kilo/skills/` | `~/.cline/skills/` | `~/.roo/skills/` | `~/.codeium/windsurf/skills/` | `~/.gemini/skills/` | `~/.copilot/skills/` |
| 项目级目录 | `.cursor/skills/` `.agents/skills/` | `.kilo/skills/` | `.cline/skills/` | `.roo/skills/` | `.windsurf/skills/` | `.gemini/skills/` | `.github/skills/` |
| 兼容 `.agents/skills/` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 兼容 `.claude/skills/` | ✅ | ✅（需开启） | ✅ | ✅ | ✅（需开启） | ❌ | ✅ |
| 模式特定 Skill | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ |
| 远程 URL 支持 | ✅（GitHub） | ✅（`skills.urls`） | ❌ | ❌ | ❌ | ✅（`gemini skills install`） | ❌ |
| 扩展贡献 Skill | ❌ | ❌ | ❌ | ❌ | ❌ | ✅（extensions） | ✅（`chatSkills`） |
| 企业级系统目录 | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ |
