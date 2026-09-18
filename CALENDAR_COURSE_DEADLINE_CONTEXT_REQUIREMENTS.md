# Remaindar AI：Calendar 课程关联能力需求

更新时间：2026-09-18

## 1. 结论

Remaindar 的 Apple Foundation Models 创建功能，希望基于「今天实际上过、但尚未录入作业的**具体课程**」推断用户未明说的作业归属。

这不是仅靠 `Deadline.subject_id` 或 `tag_ids` 能可靠完成的需求。Calendar 应把 `Deadline` 与独立的 `Course` 领域建立一个**可空、受校验、长期保留的关联**：

```text
Deadline.course_id? → Course.id
Deadline.subject_id  → Subject.id
Deadline.tags        → Homework / Assignment / Exam / Revision ...
```

其中：

- `Course` 是具体授课对象，例如「ESL 1层雅思写作」或「EL L1」。
- `Subject` 是较高层的学术归类，例如 English。
- `tag` 是 Deadline 的任务性质，例如 Homework、Assignment、Exam、Revision。

`course_id` 不是把 Course 变成 Deadline，也不会让 Course 获得 Deadline 的完成、提醒或生命周期；它只是一个可选的上下文关联。

## 2. Remaindar 当前瓶颈

现有 Remaindar 已能读取 Calendar 的 Deadline、Category、Subject 和 Tag，也已具备「自然语言 → 可编辑 Deadline 草稿 → 用户确认 → 创建」的界面流程。但它目前没有真实 LLM，也没有课程上下文。

Calendar 现有模型已经有：

```text
Term → Course → CourseSlot → CourseOverride
```

以及独立的：

```text
Deadline → subject_id + tag_ids
```

问题在于同一 Subject 下可有多门不同 Course。真实课表中，English 下有 ESL 1层A 雅思外教口语、Speaking L1A、ESL 1层雅思写作、EL L1、ESL 1层B雅思口语；Other 下有 AS经济、升旗、语文分层、政治和 PE。

因此，下列推断是错误的：

```text
English 有一条 Homework Deadline
→ 今天上过的所有 English Course 都已经录过作业
```

正确判断的单位必须是 Course：

```text
ESL 1层雅思写作：没有未完成 Homework / Assignment
EL L1：有未完成 Homework
```

现有 `Homework`、`Assignment`、`Exam`、`Revision` 等全局 Tag 已足以标识任务性质；它们不能表达「属于哪一门具体课程」。将 Course 名写入标题、备注或额外 Tag 都会混淆用户内容与机器关联，且不能保证稳定。

## 3. 为什么不采用 Remaindar 私有 watermark

可在 `source` / `external_id` 中写入 `course-hint`，作为无迁移的临时线索；但不应成为长期方案：

- 它只是 Remaindar 私有约定，不是 Calendar 的业务数据。
- Calendar Web、Android、macOS、MCP 与导出无法可靠消费这个关联。
- 用户在其他客户端编辑 Deadline 后，水印与当前内容可能不再一致。
- `external_id` 的本意是外部来源去重，不应承载可查询的领域关系。

若 Course 归属会用于「是否已录作业」、跨客户端展示或以后统计，它应由 Calendar 保存为显式字段。

## 4. Calendar 最小改动

### 4.1 D1 migration

为 `deadlines` 增加：

```sql
course_id TEXT REFERENCES courses(id)
```

并增加 `course_id` 查询索引。字段必须允许 `NULL`，以保持下列既有数据与流程不变：

- 非学业 Deadline；
- 旧数据；
- 手动创建但未选择课程的 Deadline；
- 无法合理关联具体课程的学业事项。

不得因为 Course 停用、学期结束或课表 Override 而清空历史 Deadline 的 `course_id`。Course 是历史归属，CourseSlot 是某日的排课实例，两者不能混用。

### 4.2 写入校验

Deadline create / update 在提供 `course_id` 时必须验证：

1. Course 存在；
2. Deadline `category` 为 Academics；
3. `course.subject_id === deadline.subject_id`；
4. 未提供 `subject_id` 时，拒绝 `course_id`，而不是静默猜测。

客户端可预填 Subject，但 Calendar 必须是最终校验者。API 不应只信任客户端传入的 Course 名称。

### 4.3 API 与 MCP

以下返回对象应包含 `course_id`（可以为 `null`）：

- `GET /api/deadlines`
- `GET /api/deadlines/:id`
- `POST /api/deadlines`
- `PUT /api/deadlines/:id`
- `calendar_list_deadlines`
- `calendar_get_deadline`
- `calendar_create_deadline`
- `calendar_update`

写入请求支持可选的 `course_id`。保留现有 `subject_id`、`tag_ids`、`source` 与 `external_id` 的语义，不复用它们。

第一版无需修改 Calendar Web 的新建表单，也无需在 Calendar Web 列表新增视觉元素；字段缺省为 `null` 即可。详情页将来可低调显示「关联课程」，但这不是 Remaindar AI 接入的阻塞项。

### 4.4 查询能力

现有 `GET /api/course-schedule?from=YYYY-MM-DD&to=YYYY-MM-DD` 已可返回按日期展开的 Course 实例。Remaindar 可用它找出今天已结束的 Course。

Remaindar 也需要读取未完成 Deadline 及其 tags / `course_id`。第一版允许在客户端按 Course 聚合；当数据量或其他客户端需要时，再增加 Calendar 的专用只读摘要接口，例如：

```text
GET /api/course-context?at=ISO-8601
```

该接口不是本次 schema 变更的前置条件。不要为了 Apple AI 先让 Calendar 接入任何 LLM 或代替 Remaindar 执行语义推断。

## 5. Remaindar 接入后的职责

### 系统（确定性）

1. 用上海时区取得当前时间；
2. 读取当天和近期 Course 实例；
3. 找出已经结束的具体 Course；
4. 按 `course_id` 检查未完成、带 `Homework` 或 `Assignment` tag 的 Deadline；
5. 为每个候选 Course 计算其下次实际上课时间；
6. 将合法 Course、Subject、Tag 与上述摘要交给模型；
7. 校验模型选出的 Course 与 Subject，并写入 `course_id`。

### LLM（不确定性）

1. 理解用户输入是否是在记录作业；
2. 在系统给出的候选 Course 中判断最相关的一门；
3. 从已有合法 Tags 中判断 Homework、Assignment、Exam、Revision 等任务性质；
4. 判断是否应采用「该 Course 的下一次上课」作为截止候选；
5. 提供置信度和推断原因。

模型不计算星期、课表、下次上课时间，不生成 Course / Subject / Tag ID，不直接创建 Deadline。

## 6. 目标上下文示例

```text
Current time: Friday 16:50 Asia/Shanghai

Completed courses today:
- ESL 1层雅思写作
  course_id: course-g11-09
  subject: English (sub-english)
  open coursework: none
  next occurrence: Thursday 16:05
  suggested tags: Homework, Assignment, Revision, Lecture

- EL L1
  course_id: course-g11-10
  subject: English (sub-english)
  open coursework: Homework: "Read Chapter 4"
  next occurrence: Tuesday 13:10

User input:
"把作文改完"
```

模型可推断 ESL 写作是更强候选；系统将候选截止时间精确落为周四 16:05，并在用户确认后保存：

```text
course_id  = course-g11-09
subject_id = sub-english
tag_ids    includes tag-homework or tag-assignment
```

## 7. 验收条件

- 同一 Subject 下两门 Course 的 Homework / Assignment 不互相遮蔽；
- Course 与 Subject 不匹配的写入返回验证错误；
- `course_id = null` 的旧 Deadline、非学业 Deadline 和手动创建 Deadline 保持可读写；
- Course 停用或学期结束后，历史 Deadline 仍返回原 `course_id`；
- Remaindar 能用真实 `course_id` 区分「ESL 写作尚无作业」与「EL L1 已有作业」；
- AI 产生的是草稿，用户确认前不会写入 Calendar；
- Apple Foundation Models 不进入 Calendar 后端，用户输入与推断仍在设备端完成。

## 8. 非目标

- 不将 Course 实例转换成 Event 或 Deadline；
- 不给 Course 增加提醒、完成状态或 Deadline 生命周期；
- 不要求所有 Calendar 客户端立即展示或编辑 `course_id`；
- 不在本次改动中增加 Calendar AI Proxy、云端 LLM 或 API Key；
- 不用 tags、标题、description、`group_title`、`source` 或 `external_id` 伪造 Course 外键。
