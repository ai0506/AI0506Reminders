# AGENTS.md

给在这个仓库里工作的 Codex 看的。**完整约定在 [`CLAUDE.md`](CLAUDE.md)，先读那一份**——
沟通方式、目录结构、权威文档指路表、开发原则、踩过的坑、完成前的验证清单都在里面，
这里不复述，只补 Codex 特有的部分和几条绝不能破的红线。

## 更新记录

每完成一段改动，在项目根目录的 `updates.md` 追加一行：

```
[CodeX][YYMMDDHHMM] 本次改动的说明
```

`YYMMDDHHMM` 是当前时间（两位年月日时分），与现有条目一致。写清楚**改了什么、为什么、
验证了什么、什么没做到**。这个仓库的变更记录是技术性的，不要留「文件已更新」这类没有信息量的行。

一次改动同时动到 Calendar 仓库时，两边都要记，前缀分别是 `[CodeX to Calendar][YYMMDDHHMM]`
和 `[CodeX from Reminders][YYMMDDHHMMSS]`（Calendar 侧的时间戳到秒）。

用户提到的「同事」指 Claude Code，它在 `updates.md` 里的前缀是 `[ClaudeCode]`。

## 红线

- 工程文件由 XcodeGen 从 `project.yml` 生成。**不要手改 `.xcodeproj/project.pbxproj`**，下次生成会被覆盖。
- 不引入 EventKit，不读写 Apple 日历 / Apple 提醒事项。
- token、API 地址、任何凭据都不写进仓库里的任何文件，也不写进日志、错误信息和截图。
- 隐私数据（真实标题、课表、教师姓名等第三方个人信息）只放 `private/`，那个目录不被 git 追踪；放之前先 `git check-ignore -v` 确认。
- AI 一律是**设备端** Apple Foundation Models，不引入任何云端 AI、不放 API Key。
- 不在 iPad 侧自行发明分类 / 科目 / 优先级的合法值，一律以 Calendar 后端目录为准。
- AI 解析结果必须经用户确认才能创建 Deadline。
- 推送到 GitHub 前先问用户（公开仓库，推出去会被缓存和索引）。本地 commit 不用问。

## 提交前

本仓库有 Codex 和 Claude Code 同时在改。提交前先 `git status` 确认工作区里没有别人没做完的
中间状态，再决定要不要 `git add -A`。

## 动 AI 那部分之前

`Reminders/Services/FoundationModels*.swift` 与 `Course*.swift` 里的提示词措辞、枚举顺序、
校验分级都是实测调出来的，注释里记着为什么那样写。改之前读 `CLAUDE.md` 的〈Foundation Models〉
一节——尤其是「不要为单个用例调提示词」和「改了提示词要跑真实回归集」这两条，
这个项目在这上面栽过。

回归集怎么跑见 `Scripts/ai-probe/README.md`：`swift Scripts/ai-probe/probe.swift`。
**数据集是私有的，放在不被 git 追踪的 `private/` 下**（真实 Deadline 标题、真实课表、
一位教师的姓名），跑出来的失败行同样不要贴进 `updates.md`、提交信息或 issue——
写分数和结论就够了。
