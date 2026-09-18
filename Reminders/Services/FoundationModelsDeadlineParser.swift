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
@MainActor
final class FoundationModelsDeadlineParser {
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

    static var availability: Unavailable? {
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
                return assemble(checked, input: input, catalog: catalog, now: now)
            case .rejected(let complaint):
                // 重试上限之外不再等第二轮推理，把能用的部分留下比整条丢掉好。
                guard attempt < Self.maxRetries else {
                    return assemble(Validator.salvage(proposal, catalog: catalog), input: input, catalog: catalog, now: now)
                }
                attempt += 1
                prompt = complaint
            }
        }
    }

    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(instructions: PromptBuilder.instructions)
    }

    /// 把模型的语义判断和正则的时间判断合成草稿。
    private func assemble(
        _ checked: CheckedProposal,
        input: String,
        catalog: PromptCatalog,
        now: Date
    ) -> AIParseResult {
        let timing = MockAIDeadlineParser.timing(in: input, now: now)
        let title = checked.title.isEmpty ? MockAIDeadlineParser.fallbackTitle(from: input) : checked.title
        let category = checked.category ?? catalog.categories.first ?? DeadlineCategory.all[0]

        return AIParseResult(
            originalText: input.trimmingCharacters(in: .whitespacesAndNewlines),
            draft: DeadlineDraft(
                title: title.isEmpty ? "新建截止事项" : title,
                detail: "",
                dueDate: timing.date,
                allDay: timing.isAllDay,
                category: category,
                // 后端硬约束：非 academics 分类下 subject_id 必须为空，否则 400。
                subject: category.kind == "academics" ? checked.subject : nil,
                courseID: nil,
                tags: checked.tags,
                priority: checked.priority
            ),
            // 时间没解析出来时不该显得很有把握——那是草稿里最容易错的一格。
            confidence: timing.wasExplicit ? checked.confidence : min(checked.confidence, 0.7)
        )
    }
}
