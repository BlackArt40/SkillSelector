# SkillSelector 架构文档

## 技术栈

- Swift 6.3、SwiftUI、SwiftData、Foundation、AppKit、Security、OSLog
- 仅 Apple 系统框架 — 无第三方 Swift 包
- macOS 14 Sonoma 最低部署目标
- Universal 2 构建（Apple Silicon + Intel）
- Ad-hoc 签名，App Sandbox
- Apache License 2.0

## 项目结构

单个 Swift Package 中的两个 target：

```
Sources/
├── SkillSelector/              # SwiftUI 应用（可执行 target）
│   ├── AppModel.swift          # 主 observable 模型（760 行）
│   ├── DocumentManager.swift   # 文档加载、Finder 显示、默认编辑器
│   ├── Browser/
│   │   ├── BrowserSidebar.swift
│   │   ├── SkillListView.swift
│   │   ├── SkillDetailView.swift
│   │   ├── MarkdownDocumentView.swift
│   │   ├── MarkdownRenderer.swift  # Markdown → AttributedString 渲染
│   │   ├── SkillRow.swift
│   │   └── DescriptionEditor.swift
│   ├── Settings/
│   │   └── SettingsView.swift
│   ├── Resources/
│   │   ├── en.lproj/Localizable.strings
│   │   └── zh-Hans.lproj/Localizable.strings
│   └── ...
│
└── SkillSelectorCore/          # 领域逻辑库
    ├── Domain/
    │   ├── AgentDefinition.swift
    │   ├── SkillQuery.swift
    │   ├── DescriptionResolver.swift
    │   ├── SkillInstallation.swift
    │   └── URLContainment.swift    # URL.isContained(in:) 扩展
    ├── Registry/
    │   ├── AgentRegistry.swift
    │   ├── BuiltInAgentRegistry.swift
    │   └── AgentDefinitionStore.swift
    ├── Scanning/
    │   ├── SkillScanner.swift
    │   ├── IndexRefresher.swift
    │   └── FrontmatterParser.swift
    ├── Persistence/
    │   ├── SkillIndex.swift
    │   ├── SkillRecord.swift
    │   └── AuthorizedRootRecord.swift
    ├── Permissions/
    │   └── BookmarkStore.swift
    ├── Operations/
    │   ├── SkillFileOperator.swift
    │   └── FileOperationPlan.swift
    ├── Commands/
    │   └── ExternalCommandRunner.swift
    ├── Documents/
    │   ├── SkillDocumentReader.swift
    │   └── DocumentLoadIdentity.swift
    ├── Updates/
    │   ├── SkillUpdater.swift
    │   ├── SkillSource.swift
    │   ├── PackageDigest.swift
    │   └── PackageValidator.swift
    └── Diagnostics/
        ├── DiagnosticExporter.swift
        ├── DiagnosticLogging.swift
        └── Redactor.swift
```

## 关键模块

### AppModel（760 行）

主 observable 模型，协调所有功能：

- **刷新**：索引刷新、环境检查
- **授权**：目录授权、撤销、重命名
- **文件操作**：规划、执行、冲突处理
- **更新**：检查更新、应用更新
- **自定义 Agent**：创建、编辑、删除
- **诊断**：导出脱敏诊断信息

### DocumentManager（121 行）

文档操作职责：

- 异步加载 Skill 文档
- 在 Finder 中显示文档
- 用默认编辑器打开文档
- 解析文档访问权限（安全作用域书签）

### MarkdownRenderer（219 行）

Markdown 渲染职责：

- YAML frontmatter 剥离
- 标题（h1-h6）渲染
- 加粗、斜体、行内代码
- 无序/有序列表
- 代码块
- 表格（无边框，纯文本）
- 链接（含文件路径检测）

### SkillFileOperator（951 行）

安全文件操作：

- 复制、移动、删除、创建符号链接
- 名称冲突处理（保留两个、替换、取消）
- 所有删除使用 macOS 回收站
- 授权验证和路径覆盖检查

### ExternalCommandRunner（433 行）

外部进程执行：

- 使用 `posix_spawn` 而非 `Process`/`NSTask`
- 进程组管理（SIGTERM + SIGKILL）
- 输出限制和超时
- 无 Shell 命令字符串（防注入）

### SkillUpdater（672 行）

原子 Skill 更新：

- 下载到临时目录
- 验证 SKILL.md 和包结构
- 文件级变更摘要
- 原子替换（旧目录→回收站，新目录→目标）

## 数据流

```
用户授权目录
    ↓
IndexRefresher 扫描目录
    ↓
SkillScanner 解析 SKILL.md
    ↓
SkillIndex 持久化到 SwiftData
    ↓
AppModel 刷新 snapshots
    ↓
SkillQuery 按 scope 过滤
    ↓
BrowserSidebar / SkillListView / SkillDetailView 显示
```

## 权限流程

```
用户选择目录
    ↓
NSOpenPanel 返回 URL
    ↓
BookmarkStore 创建安全作用域书签
    ↓
AppModel 授权目录（.home / .project / .system）
    ↓
IndexRefresher 扫描该目录下的 Skill
    ↓
SkillRecord 持久化到 SwiftData
```

## 关键设计决策

1. **基于路径的 Skill 身份**：每个绝对安装路径一条记录，复制和符号链接保持独立
2. **无 Shell 命令字符串**：所有外部进程使用 `executableURL` + `arguments` 数组
3. **所有删除使用回收站**：从不永久删除
4. **SKILL.md 只读**：仅允许在 Finder 中显示或用默认编辑器打开
5. **URL 包含检查**：统一的 `URL.isContained(in:)` 扩展，替代 7 处重复代码
