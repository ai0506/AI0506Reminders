# AI0506 Reminders

面向 iPad 的原生 Deadline 管理 App。它读取并写入现有 AI0506 Calendar 的 Deadline API，不使用 EventKit，也不会访问 Apple Calendar 或 Apple Reminders 数据。



AI0506 Calendar 本地project位置：
/Users/shuwenai/Desktop/Projects/Calendar

如果需要可以查看相关接口或者代码

## 文档

| 文件 | 内容 |
|---|---|
| `REMINDERS_PLAN.md` | 项目定位、分阶段计划、当前实施状态 |
| `Frontend_spec.md` | 界面与交互的验收条件，§22 是已知技术债 |
| `CLAUDE.md` / `AGENTS.md` | 在这个仓库里干活的约定与踩过的坑 |
| `lessons.md` | 从这些事故抽象出的通用工程原则 |
| `updates.md` | 改动记录（只追加） |
| `Scripts/ai-probe/README.md` | 设备端模型的回归探针怎么跑 |

`private/` 不被 git 追踪，隐私数据（AI 回归集等）放那里。

## 已实现

- iPad 横屏三栏、竖屏导航、浅色/深色模式
- Today / Upcoming / Overdue / All / 分类 / 标签筛选
- 创建、完成、重开 Deadline
- Calendar API 连接设置；token 仅保存到 iPad Keychain
- SwiftData 离线缓存与 App Group Widget 快照
- small / medium Today Widget、Widget/通知跳转到具体 Deadline
- 本地模拟 AI：自然语言 → 可编辑 Deadline 草稿；不发送任何 AI 请求
- 本地通知：定时 Deadline 提前 15 分钟、全天 Deadline 当日 09:00

## 在 Xcode 运行

1. 安装 Xcode 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

2. 在此目录执行：
   
   ```sh
   xcodegen generate
   open AI0506Reminders.xcodeproj
   ```

3. 在 Xcode 的 `AI0506Reminders` target 选择你的 Development Team 和 iPad。

4. Build & Run。首次运行默认进入不写入远端的 Demo workspace。

## 连接 Calendar

在 App 左侧底部点齿轮，填写：

- Calendar API 根地址，例如 `https://calendar.ai0506.com`
- Calendar 的 Bearer access token

连接成功后才会保存 token；token 只存储在该 iPad 的 Keychain。不要将 token 写入源码、`project.yml`、README 或截图。

## 本地验证

```sh
xcodegen generate
xcodebuild -project AI0506Reminders.xcodeproj \
  -scheme AI0506Reminders \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
  test CODE_SIGNING_ALLOWED=NO
```

当前测试覆盖中文模拟解析、英文模拟解析和 Deadline 深链接路由。

## 当前外部验收项

- 用真实 Calendar token 运行 `GET /api/deadlines`、创建、完成和重开。
- 在 2025 iPad Pro 真机确认通知授权、Widget 添加到主屏、横竖屏和性能。
- 提交 App Store 前配置正式签名、隐私说明与发布元数据。
