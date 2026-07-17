# SkillSelector

SkillSelector 是一个面向本机 Agent Skill 的轻量查看与修改工具。它聚焦于读取、理解和管理本地已有的 Skill，不承担 Agent 运行、Skill 市场或主动推荐安装职责。

## Language

**Skill**:
一种供 Agent 工具识别和执行的本地能力说明包，通常以 `SKILL.md` 作为入口文件，并可能包含脚本、模板、资源或参考文档。
_Avoid_: 插件, 扩展, 命令

**Skill 查看/修改器**:
SkillSelector 的产品定位：查看本机 Skill 的位置、来源、简介、内容和状态，并允许用户对本地 Skill 文件进行受控修改。
_Avoid_: Skill 市场, Agent 运行器, 自动推荐器

**联网补全**:
在用户授权或配置允许时，通过网络获取 Skill 简介、来源信息或版本信息，用于补全本地展示内容。
_Avoid_: 联网发现, 自动安装, 主动推荐

**最小识别信息**:
联网补全时默认允许发送的 Skill 信息，包括名称、入口文件的 frontmatter、标题、description、来源 URL 或包标识。完整 Skill 内容只有在用户显式选择时才可发送。
_Avoid_: 完整内容上传, 项目路径上传, 脚本上传

**Skill 发现范围**:
SkillSelector 默认扫描已知 Agent 的标准全局目录，以及用户当前选择项目内的标准项目级目录。它不默认进行全盘扫描。
_Avoid_: 全盘扫描, 任意目录爬取

**项目文件夹**:
用户在 SkillSelector 中显式添加的本地项目根目录，用于发现该项目内的项目级 Skill。
_Avoid_: 当前目录, 最近项目, 自动猜测项目

**目录授权**:
用户通过 macOS 目录面板授予 SkillSelector 访问主目录、项目文件夹或系统级 Skill 目录的权限。主目录授权只用于访问 Agent 类型注册表列出的固定白名单路径，不允许递归扫描其他个人文件。
_Avoid_: 全盘扫描, 白名单外访问, 静默提权

**Skill 来源**:
本地 Skill 可追溯的上游位置，例如 Git 仓库、插件缓存或明确的远程 URL。只有存在可识别来源的 Skill 才能进行自动更新检查。
_Avoid_: 猜测来源, 自动搜索来源

**Skill 更新**:
基于可识别 Skill 来源检查并拉取已有本地 Skill 的新版本。来源不可识别时，SkillSelector 不自动更新该 Skill。
_Avoid_: 自动安装, 重新发现, 在线替换

**Skill 文件操作**:
用户对本地 Skill 进行的文件级操作，包括复制、移动、删除和创建软链接。SkillSelector 不把编辑 `SKILL.md` 正文作为内置核心能力。
_Avoid_: 内置代码编辑, 内置 Markdown 编辑器

**安全删除**:
将本地 Skill 移入 macOS Trash，而不是直接永久删除。
_Avoid_: 永久删除, 静默删除

**结构性操作确认**:
复制、移动或创建软链接前向用户展示来源和目标，并等待用户确认。
_Avoid_: 静默移动, 自动软链接

**已有 Skill**:
扫描或用户选择目录中已经存在的本地 Skill。SkillSelector 首版只管理已有 Skill，不提供创建新 Skill 的能力。
_Avoid_: 新建 Skill, Skill 生成

**自定义简介**:
用户在 SkillSelector 中为本地 Skill 保存的展示说明，用于覆盖默认核心作用。自定义简介保存在 Skill 索引中，不修改 `SKILL.md`，并可随时清除以恢复默认来源。
_Avoid_: 修改 Skill 正文, 重写 SKILL.md, 丢失来源信息

**核心作用**:
SkillSelector 为每个 Skill 展示的主要用途说明，依次优先来自用户自定义简介、`SKILL.md` 的 description、可信元数据补全结果，最后来自标题或首段摘要。详情页同时标注当前来源。
_Avoid_: 无来源摘要, AI 改写, 隐藏原始说明

**可信元数据补全**:
SkillSelector 通过用户本机已有的 `gh`、npm Registry 只读命令和用户明确启用的 MCP 工具，提取远程 `SKILL.md`、官方清单、包简介或 README 中的原始说明。它不配置模型、不生成摘要，也不自动安装外部工具。
_Avoid_: AI 生成摘要, 自动安装工具, 任意命令执行, 网页抓取

**补全工具**:
用户本机已有、由 SkillSelector 检测或明确绑定的 `gh`、`npm` 可执行文件及 MCP Server。`gh` 认证由本机 CLI 管理；npm 仅允许 `search` 和 `view` 等只读查询；MCP Server 与工具必须由用户启用。
_Avoid_: Token 托管, `npm install`, `npx` 默认执行, 自动调用 MCP

**Skill 浏览器**:
SkillSelector 的主界面，由 Agent/目录筛选、Skill 列表和 Skill 详情组成，用于完成首版核心查看与管理流程。
_Avoid_: 多页面工作台, 设置向导, 开发 IDE

**Skill 索引**:
SkillSelector 保存的本地 Skill 元数据集合，包括路径、归属 Agent、层级、简介、来源、更新时间和用户自定义信息。Skill 索引不保存完整 Skill 内容。
_Avoid_: Skill 内容库, 文件备份

**更新策略**:
用户选择的 Skill 索引刷新方式，例如手动刷新或应用启动时自动刷新。
_Avoid_: 后台常驻同步, 实时监听

**Agent 类型**:
SkillSelector 支持的一类 Agent 工具，例如 Claude Code、Codex、Qoder、CodeBuddy 或 OpenCode。
_Avoid_: 平台, 提供商, 插件

**Agent 类型注册表**:
内置和用户配置的 Agent 类型定义集合，记录每类 Agent 的名称、标准 Skill 目录、项目级目录模式、入口文件名和来源识别能力。
_Avoid_: 硬编码 Agent 逻辑, 插件系统

**Skill 安装**:
由绝对安装路径唯一识别的一份本地 Skill。一个安装可以归属于多个 Agent；内容相同但路径不同的复制品仍是不同安装，软链接也作为独立安装并记录实际目标。
_Avoid_: 按名称合并, 按内容合并, 多 Agent 重复行
