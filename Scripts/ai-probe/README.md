# 设备端模型的回归探针

改 AI 提示词或校验规则后必须跑这个。单元测试只挡得住**结构**问题（编造的名字、非法的层级），
挡不住**语义漂移**——V1 有一次为了让一个用例过关改了一句分类说明，真实数据上 5 条 Research
全被判成 Academics，而那轮单元测试是全绿的。

```bash
swift Scripts/ai-probe/probe.swift              # 全部调参用例，每例 3 轮 × 2 个时间锚点
swift Scripts/ai-probe/probe.swift --rounds 1   # 快速看一眼
swift Scripts/ai-probe/probe.swift --holdout    # 只跑没参与调参的那组
swift Scripts/ai-probe/probe.swift --source real    # 只跑真实 Deadline 标题
swift Scripts/ai-probe/probe.swift --verbose    # 连模型的 reason 一起打印
swift Scripts/ai-probe/probe.swift --size       # 只量 prompt 长度，不打分
```

在 Mac 上直接跑，不用模拟器（`FoundationModels` 在 macOS 上就能用，Apple Intelligence
要已经下载完）。免费，所以该批量跑就批量跑。

## 数据集不在仓库里

默认读 `~/.ai0506/reminders/regression.json`，用 `--data` 可以指到别处。

**它为什么不在这里**：那份文件是真实课表、真实 Deadline 标题和一位教师的姓名。
这是公开仓库，而 Calendar 的 migration 0014 明确把 `courses.teacher` 写成 NULL，
理由就是教师姓名属于第三方个人信息。回归集的价值恰恰来自它是真的，所以只能放在仓库外。

同样的道理：**不要把跑出来的失败行贴进 `updates.md`、提交信息或 issue**，
写结论和分数就够了（「分类 47/56，5 条 Research 全错」）。

数据集丢了可以用 MCP 的 calendar 工具重建：`calendar_list_deadlines` 取真实标题，
期望值取数据库里的 `category` / `subject_id`，课表从 `GET /api/course-schedule` 拿。
文件结构见 `probe.swift` 里的 `Dataset`，每个字段都有注释。

## 怎么读结果

- **分三组报告**：`real`（真实标题，防回归）、`shorthand`（简写补全，看能力）、
  `holdout`（不参与调参，防过拟合）。混成一个百分比会把「为单个用例调参」的代价藏起来。
- **多轮不一致的那些例子别用来调参**。端侧模型接近确定性，同一例三轮基本一致；
  不一致说明它本身在判断边界上，跟着它调会把别的例子调坏。
- **每条输入都新建 session**。探针已经这么做了，改的时候别图省事复用——
  `LanguageModelSession` 有状态，复用到第 9 条就撑爆 4096 窗口并静默回退，分数全是假的。

## 加 V2 的两阶段时

`probe.swift` 里 `MARK: - 被测提示词` 那一段是当前 V1 的等价基线。加 Pass A / Pass B
时**新增**一个实现、用开关切换，不要改掉基线——`AI_CALL_PLAN_V2.md` 的验收要求分开报告
「Pass A 语义错」「候选构建漏项」「Pass B 绑定错」「本地规则错」，不能混成一个数。

## 已知现象

**超上下文窗口跟 prompt 长度没有必然关系。** 跑这份数据集时观察到偶发的
`exceededContextWindowSize`（约 57 次调用里 2 次，报 4089–4090 tokens），而当时
prompt 只有约 1.1k 字符、session 是新建的。也就是说撑爆窗口的是**输出**——
`reason` 之类的自由文本字段一旦跑飞就能把 4096 的预算吃光。

三个推论：
- 量 prompt 长度（`--size`）是必要的，但不充分。留余量，别卡到 3900。
- 输出字段越少越短越安全。V2 的 Pass B 只返回一个 key 加一句短理由，
  比 V1 那个七字段的结构体暴露小得多。
- app 侧必须把它当**降级路径**处理（回退本地规则并告诉用户），不是当崩溃。

**V1 在 holdout 上明显过拟合。** 「修一下那个崩溃」四轮全部被判成 Academics/CS/计算机：
模型看到「崩溃」给出 CS，CS 在目录里只有一门课，于是推出课程，再被「有课程就是课业」
的规则把分类顶成 Academics，Projects 就没了。这正是 `AI_CALL_PLAN_V2.md` 要解决的耦合，
也说明 holdout 组值得单独留着——调参用例上它是 37/38，holdout 上只有 11/15。
