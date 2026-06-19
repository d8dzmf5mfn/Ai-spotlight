# AI Spotlight — UI 优化指南

> 给下一个 AI session 的交接文档。请在开始 UI 工作前完整阅读此文档。

---

## 一、当前 UI 架构总览

```
SearchWindowView (SwiftUI)
  ├── SearchField          — 搜索输入框
  ├── ResultListView       — 搜索结果列表
  │     └── ResultRowView  — 单行结果（icon + title + subtitle）
  ├── LLM 对话区           — AI 回答气泡 + tool trace
  └── 底部状态栏            — 结果数、loading 指示器

SettingsWindowController (AppKit)
  └── SettingsView (SwiftUI)
        ├── Provider 配置段
        ├── AI 模型选择
        ├── Connection Diagnostic
        └── Indexed Folders 管理

HotkeyService → SpotlightPanel (NSPanel, 非激活面板)
StatusBarController → NSStatusItem (✨ 图标菜单)
```

**关键文件路径：**

| 文件 | 作用 |
|---|---|
| `Sources/AISpotlight/UI/SearchWindowView.swift` | 搜索面板主视图 |
| `Sources/AISpotlight/UI/SearchField.swift` | 搜索输入框 |
| `Sources/AISpotlight/UI/ResultListView.swift` | 结果列表容器 |
| `Sources/AISpotlight/UI/ResultRowView.swift` | 单行结果展示 |
| `Sources/AISpotlight/Settings/SettingsView.swift` | 设置面板 |
| `Sources/AISpotlight/App/SpotlightPanel.swift` | 窗口控制器 (AppKit) |
| `Sources/AISpotlight/App/SettingsWindowController.swift` | 设置窗口控制器 (AppKit) |
| `Sources/AISpotlight/App/HotkeyService.swift` | 快捷键注册 |
| `Sources/AISpotlight/App/StatusBarController.swift` | 状态栏菜单 |
| `Sources/AISpotlight/App/AppState.swift` | 全局状态管理中心 |

---

## 二、❌ 不可修改项（架构硬约束）

### 2.1 窗口类型
- **必须使用 `NSPanel` + `.nonactivatingPanel`**
- 原因：按 ⌘+Space 弹出搜索面板时不能夺走当前应用的焦点
- 文件：`Sources/AISpotlight/App/SpotlightPanel.swift`
- `SpotlightPanel` 继承 `NSPanel`，配置了 `.nonactivatingPanel`、`.floating`、`.ignoresMouseEvents(false)` 等

### 2.2 状态管理
- **唯一状态源是 `AppState`**（`@ObservableObject`）
- `SearchWindowView` 通过 `@ObservedObject var state: AppState` 获取所有状态
- 不要创建第二个全局状态对象，也不要将状态分散到多个 ViewModel
- LLM 对话、搜索查询、工具调用状态全部在 AppState 中

### 2.3 搜索管道
- **UI 不能直接调 Provider，必须走完整管道：**
  ```
  SearchField → AppState.runSearch() → QueryInterpreter → SearchOrchestrator → Providers
  ```
- 不可绕开 `QueryInterpreter` 或 `SearchOrchestrator` 直接调 `FileSystemProvider.search()`

### 2.4 搜索面板生命周期
- **显示/隐藏由 AppState 控制**，不走 SwiftUI `.sheet()` 或新 Window Group
- `AppState.togglePanel()` → `SpotlightPanel.show()`/`hide()`
- 用户按 ⌘+Space → `HotkeyService` → `AppState.togglePanel()`
- 按 Escape → `AppState.hidePanel()`
- 选择结果按 Enter → `AppState.executeResult()` → 打开文件 → `hidePanel()`

### 2.5 Liquid Glass 设计语言
- 搜索面板背景使用系统毛玻璃：`.background(.ultraThinMaterial)`
- 不能替换为纯色背景或自定义毛玻璃效果
- 不要移除 `.background(.ultraThinMaterial)` 这一行

### 2.6 设置窗口独立
- 设置面板和搜索面板是**两个独立窗口**，不能合并
- 设置窗口通过 `SettingsWindowController` 管理
- 入口：菜单栏 ✨ 图标 → Settings

---

## 三、✅ 可以修改项（UI 优化空间）

### 3.1 搜索面板样式

| 可改项 | 当前值 | 建议方向 |
|---|---|---|
| 背景透明度和颜色 | `Color.purple.opacity(0.04)` | 调整数值或改色 |
| 次要元素颜色 | `Color.secondary.opacity(0.3)` | 调整数值或改色 |
| 列表项背景 | `Color.gray.opacity(0.1)` | hover 效果、选中高亮 |
| 搜索框 placeholder | "Search anything..." | 文案或加图标 |
| 字体/字号 | 系统默认 | 可自定义 |
| 圆角大小 | 隐式默认 | 显式设置 cornerRadius |
| 列表项间距 | VStack spacing: 0 | 调整 spacing |
| **窗口尺寸** | `minWidth: 340`, maxHeight: 200/220 | 可调整 |
| 窗口圆角 | 隐式继承系统 | 可显式设置 |

### 3.2 结果列表 (ResultListView / ResultRowView)

| 可改项 | 当前值 | 说明 |
|---|---|---|
| 行高/间距 | 默认 | 可自定义 |
| icon 样式 | 系统 SF Symbol | 可换图标或加 emoji |
| subtitle 显示 | 文件路径/描述 | 样式可调 |
| 选中态高亮 | 灰色背景 | 色调、动画可改 |
| 文件 type 标签 | 无 | 可加后缀 badge |
| 结果分组 | 无 | 可加 section header |

### 3.3 LLM 对话区域

| 可改项 | 说明 |
|---|---|
| 气泡样式 | 圆角、背景色、对齐方式 |
| 打字机动画 | 当前逐 chunk 追加，可做打字机效果 |
| Tool trace 展示 | 当前显示 `🔧 tool: summary`，可改表格/折叠 |
| 历史记录列表 | 最大 12 条，可改上限或样式 |
| 输入框 | 当前无多行输入，可加 |

### 3.4 设置面板 (SettingsView)

| 可改项 | 当前值 | 建议 |
|---|---|---|
| 布局结构 | `VStack + ScrollView + Form` 混合 | 迁移到 `TabView` 或 `Settings` scene |
| Provider 卡片样式 | 简单列表 | 网格或卡片布局 |
| Diagnostic 结果 | ✅ 已逐步更新 | 展示效果可优化（进度条、图标动画） |
| Indexed Folders 管理 | 列表 + Add/Remove/Scan | 拖拽排序、文件夹图标预览 |
| 模型选择器 | Picker 下拉 | 搜索式下拉、分组显示 |

### 3.5 交互行为

| 可改项 | 说明 |
|---|---|
| 搜索去抖 | 当前 query 变化立即搜索，可加 150ms debounce |
| 列表项出现动画 | 可加 `.transition` 和 `.animation` |
| Scan 反馈 | 当前 3 秒绿色消息，可改 Toast/HUD |
| 空状态提示 | 当前无自定义空状态 |
| 加载指示器 | `ProgressView().scaleEffect(0.5)` 可自定义 |

### 3.6 状态栏菜单

| 可改项 | 说明 |
|---|---|
| 菜单项布局 | 添加/移除菜单项 |
| ✨ 图标 | 可替换为自定义 icon |
| 快捷键显示 | 展示当前绑定的快捷键 |

---

## 四、UI 相关技术栈

### 4.1 SwiftUI + AppKit 混合
- 搜索面板主体用 SwiftUI，但包裹在 `NSHostingView` 中
- 窗口控制用 AppKit（`NSPanel`, `NSWindowController`）
- Settings 窗口也用 SwiftUI + `NSWindowController`

### 4.2 材质和颜色
- 背景：`.ultraThinMaterial`（系统毛玻璃）
- 强调色：紫色调（`Color.purple.opacity(0.04)`）
- 不要引入自定义 NSVisualEffectView，除非 Liquid Glass skill 批准

### 4.3 构建和预览
- 无 SwiftUI Preview target。改 UI 后必须 `swift build -c release` 验证
- 无 Xcode project，纯 SwiftPM
- 构建：`swift build -c release`
- 打包 app：`./scripts/make_app.sh`
- 运行：`open build/AI\ Spotlight.app`
- 测试：`swift test`
- 日志：`tail -f /tmp/aispotlight-app.log`

---

## 五、快速开始

```bash
# 构建
cd /Users/chengziyan/Developer/AI-Spotlight
swift build -c release
./scripts/make_app.sh

# 运行（杀掉旧版再开新版）
pkill AISpotlight 2>/dev/null; sleep 0.5
open build/AI\ Spotlight.app

# 测试
swift test

# 日志
tail -f /tmp/aispotlight-app.log
```

### 测试流程
1. 打开 app → 搜索面板自动弹出
2. 输入关键词搜索文件/App
3. 按 Enter 打开结果
4. 按 Escape 关闭面板
5. 右键菜单栏 ✨ → Settings → 配置 Provider → Test connection

---

## 六、常见坑

1. **窗口焦点问题** — 修改 `SpotlightPanel.swift` 时不要改 `.nonactivatingPanel` 和 `.floating` 层级
2. **SwiftUI 预览不可用** — 无 PreviewProvider，必须真机测试
3. **Settings 和 Search 共享 AppState** — 不要在 SettingsView 里创建新的 AppState
4. **macOS 版本兼容** — 目标 macOS 15+，不要用 14 以下 API
5. **构建失败时先看 /tmp/aispotlight-app.log** — 大部分运行时问题在里面
6. **FSEvents watcher 在主队列回调** — UI 更新直接在回调里做，不需要额外 dispatch

---

## 七、参考文件

| 文件 | 内容 |
|---|---|
| `PROJECT_HANDBOOK.md` | 完整项目手册（设计决策、架构说明） |
| `docs/AUDIT_2026-06-17.md` | 搜索后端审计 |
| `docs/PROJECT_PLAN.md` | 完整开发路线图 |
| `docs/SEARCH_BACKEND.md` | SQLite 搜索后端设计 |
| `Sources/AISpotlight/App/AppState.swift` | 全局状态管理（最重要的文件） |

---

*最后更新: 2026-06-19*
*由 Codex AI session 生成，供下一个 UI 优化 session 使用*
