# CLAUDE.md

给在这个仓库里工作的 Claude Code 看的。**这份文件不复述其它文档**，只做三件事：把「该读哪一份」指清楚、把这个项目和 Calendar 后端的契约点讲明白、把踩过的坑写下来。内容失效时就地改掉，不要往下堆。

## 沟通方式

- 默认使用简体中文回复，代码注释与面向用户的文案也用中文。
- 用户有编程基础但经验有限。先说结论，再用简单语言说原因。
- 不要只给方案。风险可控就直接改代码、跑构建、跑测试。
- 不确定的信息先读代码、读 `Calendar/API_DOC.md` 或实际跑一次，不要凭印象猜。
- 这个项目由 Codex 和 Claude Code 共同开发（`updates.md` 里的 `[CodeX]` 前缀）。用户提到的「同事」指 Codex。

## 这是什么

AI0506 Reminders：面向 11 英寸 iPad Pro 的原生 Deadline 管理 App（SwiftUI / iPadOS 18+，仅 iPad，`TARGETED_DEVICE_FAMILY = 2`）。

它**不是**独立产品，而是 AI0506 Calendar 的第三个客户端（另两个是 Web 主日历和 Android / macOS 客户端）。它读写 Calendar 的 Deadline API，**不使用 EventKit**，不碰 Apple 日历与 Apple 提醒事项。

Calendar 后端在 `/Users/shuwenai/Desktop/Projects/Calendar`（Cloudflare Pages + Pages Functions + D1）。改任何涉及数据语义的东西之前先去那边核对，不要在 iPad 侧自行发明规则。

远程仓库：<https://github.com/ai0506/AI0506Reminders>（公开，主分支 `main`）。

## 常用命令

```bash
xcodegen generate
```

```bash
xcodebuild -project AI0506Reminders.xcodeproj -scheme AI0506Reminders -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build CODE_SIGNING_ALLOWED=NO
```

```bash
xcodebuild -project AI0506Reminders.xcodeproj -scheme AI0506Reminders -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' test CODE_SIGNING_ALLOWED=NO
```

- 工程文件由 **XcodeGen 从 `project.yml` 生成**。增删文件、改 target 设置、改 bundle id 都改 `project.yml` 再 `xcodegen generate`，**不要手改 `.xcodeproj/project.pbxproj`**——下次生成会被覆盖。
- 测试用的是 **Swift Testing**（`import Testing` / `@Test`），不是 XCTest。新增用例跟着现有写法走。
- 要在模拟器里看界面，用 iOS Simulator 工具（attach / screenshot / inspect），不要用 Bash 去敲 `simctl` 拼流程。
- **优先看横屏**。这是 iPad 应用的主形态，三栏布局只有横屏才完整，用户明确要求以横屏为准。
  **但 agent 目前转不了屏**：`simctl` 没有转屏命令；`osascript` 发 `keystroke` 被拒（`-1002`）；
  点 Device 菜单能解析到菜单项引用、`click` 却静默失败（缺辅助功能权限）。
  所以横屏截图要么请用户在 Simulator 里按 `Cmd+←` 转一次（设备会记住方向），
  要么请用户在系统设置 → 隐私与安全性 → 辅助功能里给终端授权。
  **不要反复重试 osascript**，会白烧时间。已经是横屏时正常截图即可。

## Git 约定

与 Calendar 仓库保持一致：

- **提交信息用英文**，祈使句，首行一句话说清做了什么；需要展开就空一行写正文，解释**为什么**这么改。不写流水账式的「update files」。
- 末尾加一行 `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`。
- 主分支 `main`。
- `project.yml` 是工程的真相来源，但生成出来的 `AI0506Reminders.xcodeproj` **也提交**（跟 Calendar 的 `mac-app` 一样），这样别人不跑 XcodeGen 也能打开。改完 `project.yml` 记得把重新生成的 pbxproj 一起提交。
- `**/xcuserdata/` 和 `*.xcuserstate` 是 Xcode 的窗口布局与个人 scheme，已在 `.gitignore` 里，不要提交。
- **完成一段完整的改动就自己 commit**，不用等用户开口——本地提交可撤销，有提交点用户才能看 diff、才能回滚。
  但**推送到 GitHub 前要先问**：这是公开仓库，推出去会被缓存和索引，`git reset` 撤不干净。
  另外这个工作区有 Codex 同时在改，提交前先确认工作区里没有别人没做完的中间状态。
- `updates.md` 的记录照写不误——它记的是「为什么这么做、验证了什么、什么没做到」，和 git history 互补，不是重复。

## 权威文档：按问题找，别通读

| 你要知道的 | 读这个 |
|---|---|
| 界面该长什么样、交互验收条件 | `Frontend_spec.md`（**是验收条件，不是风格偏好**） |
| 项目定位、分阶段计划、当前实施状态 | `REMINDERS_PLAN.md` |
| 怎么跑起来、怎么连 Calendar | `README.md` |
| 改过什么、为什么那样改 | `updates.md`（只追加） |
| Deadline / 分类 / 科目 / 标签的**字段语义与校验规则** | `../Calendar/API_DOC.md` |
| 跨客户端共同的视觉与稳定性原则 | `../Calendar/production/FRONTEND_SPEC.md` |
| Calendar 的整体架构与业务规则 | `../Calendar/PROJECT_SPEC.md` |
| 分类 / 学科 / 标签的**真实名字与配色** | `../Calendar/migrations/*.sql`（**不是** `production/FRONTEND_SPEC.md`，见下） |

`Frontend_spec.md` §22 是已知技术债清单。**不要因为那里已经有同类问题，就默认允许新增同类问题。**

## 目录

| 路径 | 是什么 |
|---|---|
| `Reminders/Views/` | 全部界面。`ContentView.swift` 是三栏主界面 + 列表行 + 详情；另三个是 sheet。 |
| `Reminders/ViewModels/DeadlineStore.swift` | **唯一状态入口**。筛选、分组、刷新、创建、完成/重开、深链接都在这里。 |
| `Reminders/Services/` | Repository（演示 / 真实 API）、Keychain 连接、离线缓存、通知调度、模拟 AI 解析。 |
| `Reminders/Models/Deadline.swift` | 领域模型与 `DeadlineFilter`。**Widget target 也编译这个文件**。 |
| `Reminders/Theme/DesignSystem.swift` | 设计令牌与 `.paperCard()` / `.reminderCanvas()`。**Widget target 也编译这个文件**。 |
| `Shared/` | App 与 Widget 共用：App Group 快照、URL Scheme 路由。 |
| `Widgets/` | WidgetKit extension。 |
| `Tests/` | Swift Testing 用例。 |
| `Reminders/Resources/sample-workspace.json` | **与 Calendar 共用的假数据**，权威副本在 Calendar 仓库，这里是 vendored 拷贝。 |
| `Scripts/sync-fixtures.sh` | 从 `../Calendar/fixtures/` 拉取上面那份。 |

## 开发原则

- 所有读写走 `DeadlineStore` → `DeadlineRepository`，不要在视图里各自维护一套状态或直接发请求。
- 写入一律以服务端返回为准。可以先做乐观更新，失败必须回滚到操作前的快照。
- 本地缓存（SwiftData + App Group `UserDefaults`）只是展示加速与离线兜底，**不是业务真相来源**。
- 新增 UI 前先查 `Frontend_spec.md` §14.1 的组件清单和 `RemindersTheme` 令牌，不要造第二套卡片 / 标签 / 空态。
- 颜色只走 `RemindersTheme`；分类与科目色是**数据颜色**，从后端来，不当主题色用。
- 保持改动范围小，不顺手重构无关代码，不加无意义注释。
- 现有注释里记的多数是踩过的坑（为什么不用那个显而易见的做法），**别删**。

## 坑

**`RemindersTheme.accent` 不能跟随 `label`。** iPad 的 `List` 拿全局 tint 当选中行填充色，深色模式下 `label` 是白的，于是白底白字、选中行的标题直接消失。现在固定用 `systemBlue`。改 accent 前先在深色模式里选中一行看看。

**新加的 `List` / `Form` 必须调 `.reminderCanvas()`。** 否则 UIKit 的默认画布在深色模式下回落成浅色不透明背景，文字不可读。这个修饰符同时隐藏滚动背景、铺 `paper`、设 `ink` 前景，三件事缺一不可。自定义行背景还要显式 `.listRowBackground(RemindersTheme.card)`。

**`Form` 行里放多个自定义按钮，每个都要 `.buttonStyle(.borderless)`。** 不然 SwiftUI 把整行合并成一个行级操作——点任意一个标签会把整行所有标签一起切换。`TagPicker` 就是这么踩过一次。

**后端返回的 Deadline 没有可用的分类 id。** `CalendarAPIRepository.DeadlineDTO.model` 把 category id 硬编码成 `"uncatalogued"`，真正的 id 靠 `DeadlineStore.applyCatalog` 用**分类名**回填。所以：分类一旦在 Calendar 侧被归档（`GET /api/categories` 就不返回它了），回填失败，那条 Deadline 会在所有分类筛选下消失。科目同理——`GET /api/subjects` 只返回 `active = 1` 的。动这块之前先想清楚归档 / 停用数据怎么办。

**全天 Deadline 的逾期规则跟直觉相反。** 后端定义是「截止日**当天仍为 open**，次日按 `Asia/Shanghai` 才变 overdue」。而 `Deadline.isOverdue` 现在用 `dueDate < Date()`，全天项当天 00:00 一过就标红——这是已知不一致（`Frontend_spec.md` §22）。凡是判「今天」「逾期」的地方，时区锚点是 **Asia/Shanghai**，不是设备时区。

**分类名以迁移脚本为准，不要照 `Calendar/production/FRONTEND_SPEC.md` §6 抄。** 那份文档写的是
"AI0506 Project" 和 "Personal"，而 `migrations/0001` 里 `cat-project` 一直叫 **Projects**、
`migrations/0003` 已经把 Personal 改名成 **Leisure**。我照文档写过一次，两个名字都是错的。
数据库是真相，文档不是。

**假数据别在 Reminders 这边改。** `Reminders/Resources/sample-workspace.json` 是 vendored 拷贝，
权威副本在 `../Calendar/fixtures/sample-workspace.json`。改那边，然后跑 `Scripts/sync-fixtures.sh`。
Calendar 的 `scripts/seed-fake.mjs` 会校验引用完整性（分类/学科/标签存不存在、非 academics 分类不能挂
subject_id、标签不超 5 个），`SharedFixtureTests` 会盯着 `DeadlineCategory.all` 别和 fixture 漂移。

**标签最多 5 个**，是后端硬约束。客户端目前没拦，超了要等提交才吃 400。

**改 `Reminders/Models` 或 `Reminders/Theme` 会同时改到 Widget。** 这两个目录被 Widget target 一起编译（见 `project.yml`）。往里面加 App 专属依赖（`UserNotifications`、SwiftData、`UIApplication`）会把 extension 编译搞挂。

**改 Widget 快照结构必须提 `SharedDeadlineCache` 的 key 版本号。** 现在是 `widget-deadline-snapshot-v2`。不提的话已装机的旧缓存会被按新结构解读。

**SwiftData 模型加字段要考虑已装机的旧缓存。** 之前加 Subject 时是设成可选才让旧缓存自动迁移过去的。

**token 只进 iPad 钥匙串。** 不写进源码、`project.yml`、README、`updates.md`、日志、错误信息和截图。错误提示也不要把原始响应体整个抛给用户。

**演示模式是默认状态。** 首次运行进的是不写远端的 Demo workspace，`isDemoMode = true`。在模拟器上「验证通过」不等于真实 API 通过——真实后端、通知授权、Widget 上主屏、真机性能都还没验收，别替用户宣称已验收。

## 完成前验证

1. `xcodegen generate` + Simulator Debug 构建必须通过。
2. 跑 `test`，Swift Testing 用例必须全绿。
3. 改了界面：在 iPad Pro 11-inch 模拟器里**浅色和深色各看一遍**，并按 `Frontend_spec.md` §20 的清单过一遍相关项。横竖屏都要转一次。
4. 改了 Widget 或通知：在模拟器里实际触发一次，不要只看代码。
5. 往 `updates.md` 追加一条（见下）。
6. 事实变了就同步 `Frontend_spec.md`（尤其 §22 技术债表）和 `REMINDERS_PLAN.md` 的状态表。

明确告诉用户哪些检查跑过了、哪些因为没有真机或没有 Calendar 凭据**没跑**。

## 更新记录

每次完成一段改动后，在项目根目录的 `updates.md` 追加一行：

```
[ClaudeCode][YYMMDDHHmm] 本次改动的说明
```

`YYMMDDHHmm` 是当前时间（两位年月日时分），与现有条目格式一致。写清楚**改了什么、为什么、验证了什么、什么没做到**。这个仓库的变更记录是技术性的，不是流水账；不要留「文件已更新」这类没有信息量的行。

## 跨项目改动

一次改动同时动到另一个项目（基本都是 Calendar）时，**两边的 `updates.md` 都要记**，用前缀标出方向：

| 记在哪 | 前缀 |
|---|---|
| 本仓库 `updates.md` | `[ClaudeCode to Calendar][YYMMDDHHmm]` |
| `../Calendar/updates.md` | `[ClaudeCode from Reminders][YYMMDDHHMMSS]` |

时间戳沿用各自仓库的既有格式：Reminders 到分钟（10 位），Calendar 到秒（12 位）。

这样在任一侧翻变更记录，都能看出「这次改动还牵动了另一个仓库」，不会只看到半截。
对面仓库的提交和推送同样要先问过用户。

## 禁止事项

- 不把 token、API 地址或任何凭据写进仓库里的任何文件。
- 不引入 EventKit，不读写 Apple 日历 / Apple 提醒事项。
- 不在 iPad App 里放任何 AI API Key。真实 AI 必须走 Calendar 后端的 Proxy。
- 不让 AI 解析结果未经用户确认就直接创建 Deadline。
- 不手改 `.xcodeproj`。
- 不在 iPad 侧自行发明分类 / 科目 / 优先级的合法值，一律以 Calendar 后端目录为准。
- 不为了修一个功能顺手重排无关页面、换视觉风格，或删掉看起来「暂时没用」的占位代码——那些多半是修抖动的产物。
- 不在没有真机和真实凭据的情况下宣称通知、Widget、真实 API 已验收。
