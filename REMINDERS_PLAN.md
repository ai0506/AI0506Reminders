# AI0506 Reminders — iPad Deadline App 总体规划

更新时间：2026-08-21

## 0. 当前实施状态（2026-08-21）

已创建可编译的 SwiftUI/XcodeGen 工程 `AI0506Reminders`，部署目标 iOS 18，限制为 iPad（`TARGETED_DEVICE_FAMILY = 2`），包含 App 与 WidgetKit extension。

| 范围 | 已实现 | 当前边界 / 下一步 |
| --- | --- | --- |
| iPad 界面 | Today / Upcoming / Overdue / All / 分类与标签导航、横屏三栏、详情、稳定的创建与 AI 入口；浅色与深色模式均已在模拟器检查 | 真机上补 Dynamic Type、键盘与 Apple Pencil 专项验收 |
| Deadline 操作 | 演示仓库的创建、完成、重开；真实 API 的 `GET`、`POST`、`complete`、`reopen` transport；分类与标签目录从 Calendar API 拉取 | 需要实际 Calendar API 地址与 bearer token 才能做端到端验证 |
| Calendar 连接 | 设置页输入 API 根地址；token 只存 iPad Keychain；成功请求后才保存 | 当前没有在代码或文档中写入任何真实 token |
| 模拟 AI | 本地模拟解析与可编辑 Title / Category / Due / Priority / All-day / Tags / Notes，确认后创建 | 真实 AI 仍待后端 Proxy，不会把 API Key 放进 iPad App |
| 本地提醒 | 用户主动开启后申请权限；定时项提前 15 分钟、全天项当天 09:00；最多安排 48 个未来任务；点击通知会路由到对应 Deadline | 尚未在真机授权状态下验收 |
| Widget | App Group 快照、small/medium Today Widget、App 数据变化后刷新 timeline、点击后路由到对应 Deadline | 当前显示今日数量和最近一项；多项 Widget 仍待补充 |
| 缓存 | SwiftData 保存真实 Calendar Deadline，冷启动先显示缓存、联网成功后替换；App Group `UserDefaults` 供 Widget 使用 | 需要真实后端断网/恢复网络测试 |

已在 iPad Pro 11-inch 模拟器验证：横屏浅色/深色三栏主界面、竖屏侧栏自动收起后的列表+详情双栏、分类和标签筛选与详情同步、设置页、AI 解析后的可编辑字段、AI 创建后的详情显示、完成/重开状态切换，以及 URL Scheme 跳转到指定 Deadline。Debug 构建已通过。真实 Calendar 后端、通知授权、Widget 添加到主屏幕和 2021 真机性能仍不能在没有用户凭据与设备连接的情况下宣称已验收。

自动化验证：`AI0506RemindersTests` 在 iPad Pro 11-inch (M5) iOS 26.5 模拟器通过 3/3，覆盖中文自然语言解析、英文自然语言解析和 Deadline URL 路由。模拟解析只在设备本地运行，不会发送用户输入或调用任何 AI API。

## 1. 项目定位

这是一个全新的 iPad 原生 Reminder App，项目目录为：

`/Users/shuwenai/Desktop/Projects/Reminders`

本项目已有 Swift/Xcode 实现；它不是 Apple Calendar 或 Apple Reminders 的客户端，也不使用 EventKit 读写系统日历数据库。

核心定位：

> 使用现有 AI0506 Calendar 后端中的 Deadline 数据，在 iPad 上提供一个简洁、漂亮、流畅的原生查看、提醒和管理体验。

第一版允许 iPad 端：

- 读取 Deadline
- 创建 Deadline
- 完成 Deadline
- 重开 Deadline
- 查看详情
- 使用本地通知提醒
- 使用 Widget 查看 Deadline
- 使用模拟 AI 将自然语言解析为可编辑的 Deadline 草稿

第一版不做：

- Apple Calendar 数据读写
- Apple Reminders 数据读写
- EventKit 集成
- 直接替换 iPadOS 默认 Reminders App
- 多用户和社交功能
- 真实 AI API 调用

后续真实 AI 接入后，App 才会通过后端写入接口创建 Deadline。

## 2. 目标设备和体验目标

主要目标设备：

- 11 英寸 iPad Pro（2021 年款）
- iPadOS 26.6.1

体验目标：

- 简洁
- 安静
- 高级感
- 触控自然
- 页面切换稳定
- 列表滚动流畅
- 不因加载、错误、选中和状态变化产生跳动

横屏优先使用 iPad 双栏或三栏布局，竖屏自动切换为导航堆栈。

## 3. 后端复用原则

Calendar 后端已经具备 Deadline 基础能力，Reminders 不重新设计数据库，优先复用现有 API 和业务规则。

需要确认并冻结的接口契约：

- `GET /api/deadlines`
- `GET /api/deadlines/:id`
- `POST /api/deadlines`
- `PUT /api/deadlines/:id`
- `POST /api/deadlines/:id/complete`
- `POST /api/deadlines/:id/reopen`
- 分类和标签读取接口
- 认证方式
- 日期范围查询方式
- Deadline 状态、优先级、分类和标签字段语义

Calendar Deadline 的核心规则：

- 全天 Deadline 使用 `YYYY-MM-DD`。
- 定时 Deadline 使用带时区的 ISO 8601 datetime。
- 状态包括 `open`、`overdue`、`completed`。
- 完成状态优先于逾期状态。
- `priority` 支持 `high`、`default`、`low`。
- `category` 必须是后端已经存在的合法分类。
- 标签由后端校验。
- Deadline 的提醒计划由后端业务规则生成；iPad 本地通知需要跟随服务端数据刷新。

数据流：

```text
Calendar D1
    ↓
Calendar Pages Functions API
    ↓
iPad SwiftUI App
    ↓
本地只读/可同步缓存
    ↓
界面、Widget、本地通知
```

创建和完成操作必须最终以服务端结果为准。iPad 可以先做乐观更新，但请求失败时必须回滚。

## 4. 技术架构

### iPad App

- Swift
- SwiftUI
- Swift Concurrency / async-await
- `URLSession`
- Swift Observation 或等效的单向状态管理
- SwiftData 作为本地缓存，而不是独立的业务真相来源
- WidgetKit
- UserNotifications
- App Intents（第一版可预留，后续接入 Siri、Spotlight 和 Shortcuts）

不使用：

- EventKit
- `EKEventStore`
- Apple Calendar 权限
- Apple Reminders 权限

### 数据层建议

```text
CalendarAPIClient
    ↓
DeadlineRepository
    ↓
DeadlineStore / ViewModel
    ↓
SwiftUI Views
```

所有创建、完成、重开、刷新和错误处理通过统一 Repository 入口执行，避免不同页面各自维护一套状态。

### 本地缓存

缓存用于：

- App 冷启动快速展示
- 无网络时保留最后一次数据
- Widget 读取
- 本地通知重建

缓存不是后端的替代品。每次网络恢复后仍需刷新服务端数据，并根据更新时间或数据指纹决定是否重绘界面。

## 5. UI 结构

### 横屏

```text
左侧导航             中间列表                 右侧详情
Today                Deadline 列表            选中 Deadline
Upcoming             按日期分组                名称/状态/时间
Overdue              分类和标签筛选            Priority/Category/Tags
Categories           创建和完成操作            Description
```

可根据实际宽度采用双栏或三栏。不能依赖设备名称判断布局，应根据可用宽度和宽高比切换。

### 竖屏

```text
导航页 → Deadline 列表 → Deadline 详情
```

竖屏顶部保持紧凑，底部或右上角提供创建和 AI 入口，不使用影响阅读的复杂工具栏。

### 主页面

第一版包括：

- Today
- Upcoming
- Overdue
- All Deadlines
- Category 筛选
- Tag 筛选
- 日期分组
- 最后同步时间
- 创建 Deadline
- AI 创建入口

### Deadline 列表行

每行展示：

- 标题
- 到期日期/时间
- Category 色点
- Tag
- Priority
- Open / Completed / Overdue 状态
- 完成操作

列表不显示过多辅助信息，标题和到期时间是主要视觉层级。

### 详情页

展示：

- Title
- Due date
- Due time 或 All-day
- Status
- Priority
- Category
- Tags
- Description
- Updated time

第一版提供：

- Complete
- Reopen
- Edit
- Delete（如果第一版产品确认需要）

## 6. 视觉设计规则

Reminders 必须遵循 Calendar 项目的前端设计规则，同时参考 ChatAI 的稳定交互设计。

参考文件：

- `/Users/shuwenai/Desktop/Projects/Calendar/production/FRONTEND_SPEC.md`
- `/Users/shuwenai/Desktop/Projects/Calendar/public/styles.css`
- `/Users/shuwenai/Desktop/Projects/ChatAI/ChatAI/FRONTEND_SPEC.md`
- `/Users/shuwenai/Desktop/Projects/ChatAI/ChatAI/src/styles.css`

### 核心原则

1. 稳定压倒一切。
2. 视觉做减法。
3. 大量留白。
4. 圆角和柔和层次。
5. 尽量不用边框和重阴影。
6. 不使用强烈品牌色。
7. 任何切换都不能让固定元素移动。

### 配色

整体采用“纸与墨”的中性灰阶：

- 浅色：白色、暖灰、浅灰
- 深色：暖黑、深灰、柔和浅色文字
- 主操作：深色实心按钮，深色模式自动反转
- 删除和错误：低饱和语义色
- Category 颜色：只用于表达分类数据，不作为全局品牌色

颜色统一通过设计 Token 管理，不在组件内到处写死颜色。

### 动效

- 动效短促、自然、可中断。
- 不使用弹跳、位移、缩放式 hover。
- 选中态不能通过改变字重导致文字宽度变化。
- 需要支持减少动态效果。
- 加载、错误、解析状态尽量使用固定槽位，不撑动周围内容。

### 布局稳定性

- 固定导航、标题和操作按钮的位置。
- 切换筛选条件时不重建整个页面。
- 弹窗在不同表单状态之间保持尺寸稳定。
- 列表区和详情区的滚动边界固定。
- 不因为滚动条出现或消失造成横向偏移。
- 所有内部可滚动的容器明确设置最小尺寸和稳定滚动区域。

## 7. 创建 Deadline

原生创建表单包括：

- Title
- Due date
- Due time
- All-day
- Category
- Tags
- Priority
- Description

创建流程：

```text
打开创建表单
    ↓
填写字段
    ↓
客户端基础校验
    ↓
POST /api/deadlines
    ↓
服务端校验 category/tag/time
    ↓
成功后更新列表和缓存
```

基础校验包括：

- Title 不为空。
- 全天 Deadline 使用日期格式。
- 定时 Deadline 必须带时区。
- Due date/time 合法。
- Category 必须从服务端分类中选择。
- Priority 必须是合法值。

## 8. 完成和重开 Deadline

完成操作采用乐观更新：

```text
用户点击 Complete
    ↓
界面立即显示 Completed
    ↓
取消对应本地通知
    ↓
调用 complete API
    ↓
失败则恢复原状态并提示
```

重开操作相反：

- 恢复 Open 或 Overdue 状态。
- 根据最新到期时间重新安排本地通知。
- 以服务端返回 Deadline 为最终结果。

## 9. 模拟 AI 功能

第一版就实现完整的 AI 前端，但暂时不连接真实 AI API。

### 用户流程

```text
输入自然语言
    ↓
点击解析
    ↓
返回模拟结构化结果
    ↓
用户检查和修改
    ↓
确认创建
    ↓
调用 Deadline 创建接口
```

示例输入：

> 周五下午三点前交实验报告，放到 Research，标记 exam 和 urgent，优先级高。

模拟结果展示：

```text
Title       交实验报告
Category    Research
Tags        exam, urgent
Due         2026-08-28 15:00
Priority    High
Description None
```

用户可以在确认前修改：

- Title
- Category
- Tags
- Due date
- Due time
- Priority
- Description

模拟解析器应单独抽象，例如：

```text
MockAIParser
AIParseResult
DeadlineDraft
```

以后接入真实 AI 时，只替换解析器和 API 层，不重做整个界面。

### AI 真实接入预留

后续建议使用：

```text
iPad App
    ↓
Calendar 后端 AI Proxy
    ↓
真实 AI API
```

API Key 不能放入 iPad App。

真实 AI 必须返回结构化 JSON，并经过：

- JSON schema 校验
- 日期和时区校验
- Category 合法性校验
- Priority 合法性校验
- 用户确认

AI 不应该未经用户确认直接写入 Deadline。

## 10. 性能和流畅性

重点针对 11 英寸 iPad Pro 的高刷新率体验：

- 网络请求使用 async/await。
- 不在主线程做 JSON 大量解析和日期格式化。
- 使用日期范围请求，不加载全部历史 Deadline。
- 当前范围优先加载。
- 相邻范围后台预取。
- 旧缓存先展示，网络结果后台替换。
- 数据没有变化时不重绘整个列表。
- 列表使用懒加载。
- 颜色、日期、标签等派生值提前计算或缓存。
- AI 解析期间不阻塞主界面。
- 表单提交期间固定按钮位置，只改变 loading 状态。

需要测试：

- 500 条 Deadline
- 1000 条 Deadline
- 大量标签和分类
- 快速切换 Today / Upcoming / Overdue
- 连续完成多个 Deadline
- 快速打开和关闭 AI 面板
- 网络慢、断网、恢复网络

## 11. 本地通知

如果启用本地提醒：

- 创建后安排通知。
- 修改截止时间后取消旧通知并重建。
- 完成后取消通知。
- 重开后重新安排。
- 删除后取消通知。
- 服务端刷新发现数据变化后重建受影响的通知。

通知只存在于 iPad 本地，不写入 Apple Reminders。

通知点击后进入对应 Deadline 详情页。

## 12. Widget

第一版 Widget 建议包含：

### Today

- 今日 Deadline 数量
- 最近 3–5 项
- 到期时间
- Priority

### Upcoming

- 未来几天 Deadline
- 按日期分组
- 最近到期项突出显示

### Overdue

- 逾期数量
- 最近逾期项目
- 点击进入 Overdue 页面

Widget 实现要求：

- WidgetKit
- App Group 共享缓存
- 独立 Widget timeline
- App 与 Widget 共享轻量模型
- Widget 点击 deep link 到列表或详情
- App 更新后主动刷新 Widget timeline

## 13. ChatAI 参考范围

参考项目：

`/Users/shuwenai/Desktop/Projects/ChatAI/ChatAI`

可复用的经验：

- 自然语言输入工作区
- 模拟 AI 模式
- 空状态
- 状态和错误处理
- 主题 Token
- 解析过程和最终结果分离
- 界面状态切换时保持固定布局
- 不让流式/加载状态造成页面抖动

不直接照搬：

- Web 聊天页面的具体布局
- 多供应商 API Key 管理
- 对话历史系统
- Markdown 聊天渲染

Reminders 的 AI 是“输入 → 结构化 Deadline 草稿 → 用户确认”，不是聊天产品。

## 14. 分阶段实施顺序

### Phase 0：后端契约确认

- 确认 API 地址和认证。
- 确认 Deadline 字段。
- 确认分类、标签读取。
- 确认创建、完成、重开响应。
- 确认时区和状态计算。

### Phase 1：基础工程

- 创建 SwiftUI iPad 工程。
- 建立网络层。
- 建立 Deadline 模型。
- 建立 Repository 和统一状态管理。
- 建立本地缓存。
- 建立设计 Token。

### Phase 2：主界面

- Today。
- Upcoming。
- Overdue。
- All Deadlines。
- 分类和标签筛选。
- 详情页。
- Loading / Empty / Error 状态。

### Phase 3：写入操作

- 创建 Deadline。
- 完成 Deadline。
- 重开 Deadline。
- 乐观更新和失败回滚。
- 本地通知同步。

### Phase 4：模拟 AI

- 自然语言输入界面。
- 模拟解析。
- 结构化结果面板。
- 字段编辑。
- 用户确认后创建。

### Phase 5：Widget 和真机优化

- Today Widget。
- Upcoming Widget。
- Overdue Widget。
- App Group 缓存。
- Deep link。
- 横竖屏、深色模式、Dynamic Type、键盘、Apple Pencil。
- 11 英寸 iPad Pro 真机性能测试。

### Phase 6：真实 AI

- 后端 AI Proxy。
- 结构化 JSON 输出。
- Category 和 Tag 匹配。
- 置信度和缺失字段确认。
- API Key 隔离。
- 限流和错误处理。

## 15. 第一阶段验收标准

- iPad 横屏和竖屏布局稳定。
- Today、Upcoming、Overdue 可正常切换。
- Deadline 创建成功后立即出现。
- 创建失败能够回滚。
- Deadline 可以完成和重开。
- 完成后本地通知被取消。
- 模拟 AI 能展示 Title、Category、Tags、Due、Priority、Description。
- 用户可以编辑模拟 AI 结果后创建。
- Widget 能显示缓存数据并进入对应页面。
- 无网络时能显示最后一次缓存并提示状态。
- 网络恢复后能同步最新数据。
- 大量 Deadline 滚动无明显卡顿。
- 动态字体、深色模式、减少动态效果正常。
- 页面切换、表单校验和加载状态不造成布局跳动。
