import Foundation
import FoundationModels

/// Pass A 的输出：**不含任何 Calendar 目录信息**的中间理解。
///
/// V1 让模型在一个 prompt 里同时产出标题、分类、学科、标签、优先级和自评置信度，
/// 结果是分类说明、标签名和课程上下文互相污染——给模型看课程列表会把「修一下那个崩溃」
/// 拉进 Academics，分类说明里出现 "friends, rest" 就会被当成标签填回来。
/// V2 把这一步压缩成「模型只说它读懂了什么」，目录绑定交给 Pass B。
///
/// `subjectHint` / `courseHint` 是**用户话里的线索**，不是目录里的名字，更不是 id：
/// 「物理」「雅思口语」「卷子」都可以出现，只有原文确实点名时才会出现具体课程名。
/// 代码随后自己去目录里找对应物，找不到就当没有。
@Generable
struct SemanticInterpretation: Equatable {
    @Guide(description: "任务标题，只保留要做的事，去掉所有时间词，不超过 30 字")
    var title: String

    var taskNature: TaskNature

    @Guide(description: "原文里指向某个学科的词，原样摘出来；没有就留空。不要翻译，不要改写。")
    var subjectHint: String?

    @Guide(description: "原文里指向某一门具体课程的词，原样摘出来；没有明确点名就留空。")
    var courseHint: String?

    @Guide(description: "一句完整的中文，说明你依据原文里的哪些词做出判断")
    var reason: String
}

/// 任务性质。这是模型对「这是件什么事」的判断，**不是**分类名——
/// 分类名只能在 Pass B 从候选路线里选。
///
/// case 顺序不是随意排的：端侧模型有很强的「选第一个」偏置（V1 探针里 priority
/// 一度五个用例全是 high），所以第一个必须是最保守的值。
///
/// 但这里的保守值有代价：`unclear` 排第一，模型可能把本来判得出的事也说成不清楚，
/// 那 Pass A 就白做了。V1 的偏置是在**有明确正确答案**的枚举上观察到的，这个枚举
/// 还没跑过探针——接 Pass A（第三阶段）时必须重跑一遍，用真实回归集看 unclear 的占比，
/// 高得不正常就把顺序换掉并记下结论。
@Generable
enum TaskNature: Equatable {
    /// 判断不出来。Pass B 会因此更容易走 unresolved，由用户在草稿页决定。
    case unclear
    /// 学校布置的功课：作业、卷子、习题册、复习、考试。
    case coursework
    /// 机主自己的科研论文及其周边：写作、查重、投递、汇报给导师。
    case research
    /// 他自己写的软件。
    case softwareProject
    /// 生活杂事：出行、运动、休息、要带的东西。
    case personal
    /// 设备、账号、订阅、证件这类事务。
    case tech
}
