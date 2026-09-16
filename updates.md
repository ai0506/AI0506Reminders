[2608211827] 创建 REMINDERS_PLAN.md，总结 Reminders iPad Deadline App 的项目定位、Calendar 后端复用方案、SwiftUI 架构、iPad Pro 11 英寸适配、创建/完成流程、模拟 AI、性能、通知、Widget、ChatAI 参考和分阶段实施计划。
[2608211846] 新建 AI0506Reminders XcodeGen/SwiftUI iPad 工程和 WidgetKit extension；实现 Deadline 三栏界面、模拟数据/Calendar API Repository、创建、完成/重开、可编辑模拟 AI 草稿、App Group Widget 快照缓存，并通过 iPad Simulator Debug 构建与横屏交互验证。
[2608211852] 增加 Calendar 连接设置（API 根地址、iPad Keychain bearer token、连通后保存、演示模式回退）及用户主动授权的本地 Deadline 通知调度；在 iPad Pro 11-inch 模拟器验证设置页、AI 草稿的全部可编辑字段与创建结果，并更新 REMINDERS_PLAN.md 的实现状态和未验收边界。
[2608211902] 加入 SwiftData Deadline 离线缓存、Calendar 分类/标签目录同步、标签筛选及筛选-详情选择同步；实现 Widget 和本地通知的 Deadline URL 路由、App URL Scheme 与通知 delegate；修正深色模式纸墨 Token/操作对比度，并在 iPad Pro 11-inch 模拟器验证浅深色、标签筛选和指定 Deadline 跳转。
[2608211907] 新增本地 MockAIDeadlineParser，支持中英文标题清理、明天/后天/中英文星期、英文 AM/PM 与中文数字时间、分类/标签/优先级解析；新增 iOS Testing target，iPad Pro 11-inch (M5) 模拟器 3/3 通过中文解析、英文解析和 Deadline URL 路由测试。
[2608211909] 增加项目内 SVG 导出的 1024px AppIcon 并配置 Xcode asset catalog；确认 iPad AppIcon rendition 已进入 Assets.car。新增 README.md，说明 Xcode 运行、Keychain 连接、验证命令与真实设备验收项。
[2608211911] 在 iPad Pro 11-inch (M5) 模拟器实际旋转验证竖屏布局：NavigationSplitView 收起侧栏为左上入口，Deadline 列表与详情保持稳定双栏；同步更新规划验收记录。
[CodeX][2609142105] Reminder 全量改为中文界面与中文 Widget/本地通知文案；深色模式的正文、按钮和卡片边界统一采用系统动态语义色，修复低对比文字。
[CodeX][2609142105] 对齐新版 Calendar Deadline 语义：接入 Category kind、Academics Subject 目录与 subject_id 读写；新增学科筛选、创建/AI 草稿的学科选择，并保持 Course 课程层不进入 Reminder。
[CodeX][2609142105] SwiftData 离线缓存将 Subject 字段设为可选，保障已安装旧版本缓存可自动迁移；模拟数据、AI 解析和回归测试同步更新为中文体系。
[CodeX][2609142110] 深色模式的 Sidebar、Deadline 列表与两个系统 Form 明确隐藏 UIKit 默认画布并使用 Reminder 动态深色背景/前景，消除默认白色不透明框造成的文字不可读问题；Simulator Debug 编译通过。
[CodeX][2609142114] 修正深色 Deadline 列表选中态：全局 tint 原本随 label 在深色变白，被 iPad List 用作选中行填充而与白色标题冲突；改为独立 systemBlue accent，并为 Deadline 行显式指定动态卡片背景；Simulator Debug 编译通过。
[CodeX][2609160950] 为主动创建与 AI 草稿共用的 TagPicker 标签按钮指定 borderless 样式，避免 SwiftUI Form 将同一行的多个标签合并为行级操作，点击单一标签误切换全部标签。
[CodeX][2609142121] Widget 改为仅显示未来未完成 Deadline：中号按最近三个有事项的日期各显示一项，同日按高/普通/低优先级再按时间决胜；小号显示首项及其余数量。Widget 快照升级 v2，规避旧单项缓存；新增三日期与同日高优先级回归测试，全部 iOS 测试通过。
[ClaudeCode][2609161209] 依据实际代码填写 Frontend_spec.md：把通用 Web 模板改写为 SwiftUI/iPadOS 约束，补齐三栏布局尺寸、RemindersTheme 令牌表、状态与空态文案、项目特有规则（列表/详情/侧栏/学科/AI/Widget/通知）；对照 Calendar/API_DOC.md 与 production/FRONTEND_SPEC.md 新增 §18.9 跨客户端一致性约束，并把 category id 硬编码为 uncatalogued、归档分类与停用科目导致的筛选失效、全天逾期语义与后端相反、设备时区分组、标签 5 个上限记入 §22 技术债；更正原先「PUT/DELETE 契约未冻结」的错误说法（实际已在 API_DOC 冻结）。新增 CLAUDE.md，记录 XcodeGen/Swift Testing 工作流、文档指路表与已踩过的坑（accent 不可跟随 label、必须调 reminderCanvas、Form 行内按钮 borderless、Models/Theme 被 Widget 共编译、快照版本号、SwiftData 旧缓存迁移）。未跑构建与测试，本次只改文档。
[ClaudeCode][2609161236] 将项目纳入版本控制：git init、按 Calendar 惯例编写 .gitignore（忽略 xcuserdata/xcuserstate/构建产物/系统文件，保留 XcodeGen 生成的 .xcodeproj）、提交前扫描确认无凭据泄露，主分支 main，远程公开仓库 github.com/ai0506/AI0506Reminders。CLAUDE.md 删去已失效的「本目录不是 git 仓库」并新增 Git 约定节（英文祈使句提交信息、Co-Authored-By、pbxproj 随 project.yml 一起提交、仅在用户要求时提交推送）。
