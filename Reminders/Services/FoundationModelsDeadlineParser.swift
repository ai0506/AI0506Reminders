import Foundation
import FoundationModels

/// 设备端 Apple Foundation Models 解析器。
///
/// 分工是刻意的，来自 `CALENDAR_COURSE_DEADLINE_CONTEXT_REQUIREMENTS.md` §5：
/// **确定性的事一律不交给模型**。日期、时间、星期由 `MockAIDeadlineParser.timing`
/// 的正则解析（实测模型会把 prompt 里的当前时间当答案抄走），模型只做语义判断——
/// 这句话属于哪一类、哪个学科、什么性质、有多急。
///
/// 模型永远不接触 id：分类、学科、标签一律用**名字**回传。编一个不存在的 id
/// 我们无从分辨真假，编一个不在清单里的名字一眼就能查出来。
/// **这是个 actor，不是 `@MainActor` 类。**
///
/// 之前它挂在主 actor 上，于是端侧推理那几秒都占着主线程：界面冻住，用户点
/// 「取消」「关闭」没有反应，连点几次之后等推理结束才一起生效——真机上的表现
/// 就是「按很多次才能关掉窗口」。Mac 上快到察觉不出，所以模拟器复现不了。
/// 推理必须离开主线程，界面才有资格在它跑的时候响应。
actor FoundationModelsDeadlineParser {
    /// 端侧模型编造清单外名字的概率不低（探针里 7 个用例有 3 个编了标签名），
    /// 所以校验不是可选优化。但重试一次就要多等一轮推理，超过一次用户会觉得卡。
    static let maxRetries = 1

    enum Unavailable: Error {
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
        case other

        /// 三种不可用原因用户能做的事完全不同，不能统一报「AI 不可用」。
        var message: String {
            switch self {
            case .deviceNotEligible: "这台设备不支持 Apple 智能，AI 创建暂时用本地规则解析。"
            case .appleIntelligenceNotEnabled: "请先在「设置 › Apple 智能与 Siri」里打开 Apple 智能。"
            case .modelNotReady: "Apple 智能的模型还在下载，稍后再试。"
            case .other: "设备端模型暂时不可用，这次用本地规则解析。"
            }
        }
    }

    /// 只用来预热模型权重，不参与真正的解析（解析每次开新的，见 `parse`）。
    private var warmupSession: LanguageModelSession?

    nonisolated static var availability: Unavailable? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady): .modelNotReady
        case .unavailable: .other
        @unknown default: .other
        }
    }

    /// 在 AI 面板出现时就调，别等用户点「分析这段话」。
    /// 首次推理要加载模型，那段成本正好用用户打字的几秒吃掉。
    func prewarm() {
        guard Self.availability == nil else { return }
        // 预热加载的是模型权重，那是进程级的资源，不属于某一个 session——
        // 所以这里预热的 session 和后面解析用的不是同一个，也不影响效果。
        let session = warmupSession ?? makeSession()
        warmupSession = session
        session.prewarm()
    }

    func parse(
        input: String,
        categories: [DeadlineCategory],
        tags: [DeadlineTag],
        subjects: [DeadlineSubject],
        courseContext: CourseContext = .none,
        courseCatalog: [Course] = [],
        now: Date = .now
    ) async throws -> AIParseResult {
        if let unavailable = Self.availability { throw unavailable }

        let catalog = PromptCatalog(categories: categories, tags: tags, subjects: subjects)
        // 每次解析开一个新 session。
        //
        // `LanguageModelSession` 是有状态的：每轮问答都留在它的 transcript 里，下一次
        // 请求会把历史一起送进去。而上下文窗口只有 4096 token 且**连输出一起算**，
        // 复用同一个 session 的话，连着解析几条就会把窗口撑爆，报
        // `exceededContextWindowSize` 而不是给出草稿。
        // 每条笔记的解析本来也互不相干，不需要看见上一条。
        // 一次解析**内部**的重试仍然复用这个 session——重试就是要让模型看到自己刚才的回答。
        let session = makeSession()

        var prompt = PromptBuilder.request(catalog: catalog, userText: input)
        var attempt = 0
        while true {
            let proposal = try await session.respond(to: prompt, generating: DraftProposal.self).content
            switch Validator.validate(proposal, catalog: catalog) {
            case .accepted(let checked):
                return assemble(checked, input: input, catalog: catalog,
                                courseContext: courseContext, courseCatalog: courseCatalog, now: now)
            case .rejected(let complaint):
                // 重试上限之外不再等第二轮推理，把能用的部分留下比整条丢掉好。
                guard attempt < Self.maxRetries else {
                    return assemble(Validator.salvage(proposal, catalog: catalog), input: input, catalog: catalog,
                                    courseContext: courseContext, courseCatalog: courseCatalog, now: now)
                }
                attempt += 1
                prompt = complaint
            }
        }
    }

    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(instructions: PromptBuilder.instructions)
    }

    /// 把模型的语义判断、正则的时间判断和规则推出的课程合成草稿。
    private func assemble(
        _ checked: CheckedProposal,
        input: String,
        catalog: PromptCatalog,
        courseContext: CourseContext,
        courseCatalog: [Course],
        now: Date
    ) -> AIParseResult {
        let timing = MockAIDeadlineParser.timing(in: input, now: now)
        let title = checked.title.isEmpty ? MockAIDeadlineParser.fallbackTitle(from: input) : checked.title

        let named: Course? = if case .direct(let candidate) = courseContext { candidate.course } else { nil }
        let candidates: [CourseCandidate] = if case .contextual(let list) = courseContext { list } else { [] }

        // 论文类笔记不挂课程。模型会把「论文 Introduction 完成」也往「ESL 1层 雅思写作」
        // 上挂（都涉及写作），挂上之后下面那条「有课程就是课业」又会把分类顶成 Academics，
        // 于是一条科研事项被整条判错。用户写了课程名时不受此限——「经济学的论文」
        // 是 AS经济 的课业。
        let resolution = (named == nil && ResearchMarkers.matches(input))
            ? .unresolved
            : CourseResolver.resolve(input: input, named: named,
                                     modelSubjectName: checked.subject?.name,
                                     catalog: courseCatalog, candidates: candidates,
                                     subjects: catalog.subjects)

        // 推出了课程就必然是课业：后端要求 course_id 只能挂在 Academics 上。
        var category = checked.category ?? catalog.categories.first ?? DeadlineCategory.all[0]
        if resolution.course != nil, let academics = catalog.categories.first(where: { $0.kind == "academics" }) {
            category = academics
        }

        // 记作业的习惯可以推翻模型给的学科：「卷子」就是物理，不管模型判成了什么。
        var subject = checked.subject
        if let name = resolution.subjectName, let matched = catalog.subject(named: name) {
            subject = matched
        }
        // 后端硬约束：非 academics 分类下 subject_id 与 course_id 必须为空，否则 400。
        let isAcademic = category.kind == "academics"

        // 「下节课交」是能算出来的：课表里就有那门课的下一次上课。
        // 推不出课程、或者课表里没有下一节时，保持时间正则的结果不变——
        // 宁可留一个明显不对的默认日期让用户改，也不要编一个看着像真的时刻。
        var dueDate = timing.date
        var allDay = timing.isAllDay
        if NextLessonMarkers.matches(input),
           let next = Self.nextOccurrence(of: resolution.course, in: courseContext) {
            dueDate = next.start
            allDay = false
        }

        return AIParseResult(
            originalText: input.trimmingCharacters(in: .whitespacesAndNewlines),
            draft: DeadlineDraft(
                title: title.isEmpty ? "新建截止事项" : title,
                // 页码写进备注：那是作业内容本身，只留在原文里的话，
                // 过两天打开这条 Deadline 就不知道要做哪几页了。
                detail: PageNumbers.note(from: input) ?? "",
                dueDate: dueDate,
                allDay: allDay,
                category: category,
                subject: isAcademic ? subject : nil,
                courseID: isAcademic ? resolution.course?.id : nil,
                tags: checked.tags,
                // 优先级不问模型：它会无中生有。实测「Finish the physics worksheet
                // tomorrow at 3pm」这种毫无紧急字样的句子也给「高」。规则只认明确的
                // 紧急字样，其余一律普通——宁可让用户自己抬，也不要草稿页上半数都是高优先。
                priority: LocalDraftRules.priority(for: input)
            ),
            courseName: isAcademic ? resolution.course?.name : nil,
            courseBasis: isAcademic ? resolution.basis?.explanation : nil
        )
    }

    /// 这门课在课表里的下一次上课。候选是按课程建的，所以只认对得上 id 的那一条——
    /// 拿另一门课的上课时间当截止时间，比没有时间更糟。
    ///
    /// `nonisolated` 是因为这是个纯函数：整个类挂在 MainActor 上只是为了模型调用，
    /// 这条规则跟 actor 无关，不解除隔离的话测试连调都调不了。
    nonisolated static func nextOccurrence(of course: Course?, in context: CourseContext) -> CourseOccurrence? {
        guard let course else { return nil }
        switch context {
        case .direct(let candidate):
            return candidate.course.id == course.id ? candidate.nextOccurrence : nil
        case .contextual(let candidates):
            return candidates.first { $0.course.id == course.id }?.nextOccurrence
        case .none:
            return nil
        }
    }
}
