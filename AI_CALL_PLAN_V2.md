# AI 调用计划 V2

## 目标

将 AI 创建从“一次调用同时理解原文并填写 Calendar 字段”改为两次职责不同的设备端调用：先理解，再把理解结果绑定到本次从 Calendar 取得的合法目录。分类、学科和课程仍可由模型决定，但只能从第二阶段给出的候选路线中选择。

本计划不改变以下产品边界：用户输入不离开 iPad；不引入云端 AI 或 API Key；日期时间继续由本地规则解析；任何草稿必须经用户编辑或确认后才创建 Deadline。

## 决策依据

当前 V1 已有结构化输出、目录校验、一次重试、课程解析和用户确认，但模型仍在同一 prompt 中同时处理标题、Calendar taxonomy、标签、优先级和 certainty。这让分类说明、标签名称、课程上下文互相污染，也把 4096-token 上下文窗口压得过紧。

本人 DoubleAgent 双提示词实验（本地文档，未入库）的 OnlineSoup 部分不支持把 V2 做成两次完整分类再仲裁：strict/inferential 在 32/900 item-rounds 分歧，带候选标签的仲裁有锚定效应，且没有产生第三种独立标签。因此 V2 采用**顺序的职责拆分**，不采用双路投票、候选可见仲裁或第三次“裁判”调用。

## 非目标

- 不让模型解析日期、时间、星期或时区。
- 不让模型决定 priority、tags 或向用户显示的 confidence 百分比。
- 不向模型传递后端 id；更不信任模型自行编造 id。
- 不把 13 门课程或整个历史 Deadline 列表放入任何一次 prompt。
- 不让第二次调用重新解释任务语义，或静默推翻第一次的理解。

## 目标流程

```text
用户原文
  ├─ 本地时间解析（Asia/Shanghai）
  ├─ Pass A：语义理解，不提供 Calendar 目录
  │    └─ 标题、任务性质、学科线索、课程线索
  ├─ 本地候选构建
  │    └─ 当前目录 + 课表/文字/习惯缩成合法路线
  ├─ Pass B：目录绑定，只能选择候选路线或“未确定”
  │    └─ 分类、学科、课程
  ├─ 本地验证、priority/tags/confidence 决议
  └─ 可编辑草稿 → 用户确认 → Calendar API
```

每条输入仍只新建一个 `LanguageModelSession`。Pass A 与 Pass B 在这一次解析内复用该 session，方便 B 读取 A 的结构化结果；下一条输入必须重新创建 session，不能累积 transcript。

## Pass A：语义理解

Pass A 的 prompt 不含 Categories、Subjects、Tags、课程名称、后端 id 或课表。它只要求模型把原文转换成一个小型且稳定的中间表达：

```swift
@Generable
struct SemanticInterpretation {
    var title: String
    var taskNature: TaskNature
    var subjectHint: String?
    var courseHint: String?
    var reason: String
}

@Generable
enum TaskNature {
    case coursework, research, softwareProject, personal, tech, unclear
}
```

`subjectHint` 和 `courseHint` 是对用户话语的线索，不是 Calendar 名称、更不是 id。例如“物理”“雅思口语”“卷子”可以出现；“Physics”或某门具体课程只有在原文确实指向它时才出现。`reason` 仅用于本地诊断与回归，不进入创建请求，也不作为后续规则的唯一依据。

Pass A 不输出 tags、priority 或 certainty。标题为空时仍沿用本地 `fallbackTitle`。

## 候选构建

代码根据 `SemanticInterpretation`、当前 `PromptCatalog`、`CourseContextBuilder`、`CourseHabits` 和 `CourseResolver` 的既有证据，生成少量 `RoutingCandidate`。一个候选代表一条完整、层级合法的路线：

```swift
struct RoutingCandidate {
    let key: String        // 仅本次请求有效，例如 R1
    let category: DeadlineCategory
    let subject: DeadlineSubject?
    let course: Course?
    let evidence: RoutingEvidence
}
```

候选必须包含：

- 每个可用分类的 category-only 路线；
- Academics 下的可用学科路线；
- 由原文课程名、课程短名、作业习惯或课表上下文得出的课程路线；
- 一个明确的 `unresolved` 选择。

课程路线只从现有的短名单产生；短名单最多保留三个强证据候选。课程不属于所选学科、非 Academics 路线带 course，或目录中不存在的对象，都不得进入候选。候选的 `key` 由代码生成，模型只看 key、面向用户的名称和极短的层级描述，代码再把 key 映射回真实对象。

## Pass B：目录绑定

Pass B 的输入是 Pass A 的结构化理解及 `RoutingCandidate` 列表。输出只有：

```swift
@Generable
struct RouteSelection {
    var routeKey: String // R1…Rn 或 unresolved
    var reason: String
}
```

其指令必须明确：不改写标题和 taskNature；只选择最符合 Pass A 的一条候选；证据不足时选择 `unresolved`。它没有 tags、priority、时间或任意自由填写的分类/学科/课程字段。

若 `routeKey` 不在候选表中，最多发起一次精确的纠错重试；重试失败则选择 `unresolved`，不按目录第一项猜测。Pass B 与 Pass A 语义冲突时，不启动第三次仲裁：保留可编辑草稿，降低可信状态，并在开发诊断中记录冲突来源。

## 非模型决议

| 字段 | 决策者 | 规则 |
|---|---|---|
| Due date/time | `MockAIDeadlineParser.timing` | 固定使用 Asia/Shanghai；识别不到时按现有默认值并降级可信状态。 |
| Priority | 本地规则 | 仅明确紧急证据设 high；否则 default。 |
| Tags | 本地规则 | 精确名称/别名命中才加入；无证据即为空，用户可编辑。 |
| Confidence | 本地来源记录 | 用“时间是否明确、路线证据级别、是否 unresolved、是否重试/回退”生成可解释状态，不使用模型自评。 |

草稿界面把现有“解析置信度 70%”改为面向用户的状态，例如“已根据明确课程名匹配”“请检查分类和课程”“未识别明确截止时间”。具体文案在 UI 实施前与 `Frontend_spec.md` 一起定稿。

## 失败与降级

- Apple Intelligence 不可用：保留现有本地规则解析；共享时间、priority、tags 和可信状态规则，避免两条路径产生不同的日期语义。
- Pass A 失败：使用本地标题与时间结果，路线设为 `unresolved`。
- Pass B 失败或候选非法：保留 Pass A 标题，路线设为 `unresolved`。
- 任一降级：草稿页明确写“本地规则解析”或“部分信息需要检查”，从不伪装成高可信 AI 结果。

## 实施阶段

1. **先修确定性基础。** 将相对日期计算从 `Calendar.current` 改为项目既定的 Asia/Shanghai，并补跨时区单元测试。
2. **建立 V2 类型与纯函数。** 新增中间语义、路线候选、可信状态和候选校验的单元测试；不改 UI。
3. **实现 Pass A。** 将 `DraftProposal` 缩为语义输出，保留新 session-per-input 规则和不可用回退。
4. **实现候选构建与 Pass B。** 将现有课程上下文和 resolver 变为候选证据，而非直接覆盖模型结论；限制候选数量和 prompt 长度。
5. **接入草稿与降级 UI。** 显示路线依据与需检查状态；保持所有字段可编辑、创建前确认。
6. **真实回归后再替换 V1。** 完成后同步 `REMINDERS_PLAN.md`、`Frontend_spec.md` 与 `CLAUDE.md` 中已变化的事实。

## 验收

### 自动化

- 覆盖合法路线、候选外 key、父子不一致、空目录、Pass B 重试、unresolved、模型不可用和 Asia/Shanghai 相对日期。
- 覆盖 priority 与 tag 的明确证据和无证据默认值。
- 确认每次新输入只创建一个 session，连续输入不会累积上下文。
- 测量两阶段 prompt 的上限，确保目录变化后仍远离 4096-token 窗口。

### 真实模型回归

- 使用真实 Calendar 目录和本人的历史标题建立私有回归集；标题、token、课程资料不得提交进仓库或日志。
- 保留一组不参与调参的 holdout；每例运行 2–3 轮，分别统计标题可用性、分类、学科、课程、时间和无依据高优先级/标签。
- 对比 V1 与 V2，单独报告“Pass A 语义错”“候选构建漏项”“Pass B 绑定错”“本地规则错”，不把它们混成一个百分比。

### 体验与边界

- 真机在 Apple Intelligence 已下载、未下载、关闭三种状态下各走一次输入 → 草稿 → 编辑 → 创建。
- 两次调用期间只禁用分析按钮，仍允许取消；不新增仲裁等待页。
- 真实 Calendar API、课程归属和创建结果要独立验收；模拟器构建和单元测试不能替代这些检查。

## 停止条件

若真实回归显示 Pass B 对候选绑定没有净提升，或端侧延迟明显破坏 AI 创建体验，则保留 Pass A 与本地候选/用户编辑，不继续添加第二次调用或仲裁。V2 的成功标准是更可解释、更易校验的草稿，不是增加模型调用次数。
