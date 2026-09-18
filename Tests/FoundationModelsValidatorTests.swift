import Foundation
import Testing
@testable import AI0506_Reminders

/// 校验器是模型输出的守门人。
///
/// 这里的用例不是凭空想的——全部来自接入前用真实端侧模型跑的探针，那一轮 7 个输入里
/// 有 3 个编造了不存在的标签名（"Reading"、"Report"、"friends"、"rest"，后两个还是
/// 从提示词的分类说明文字里抄走的），还有把 "review" 写成 "Review" 的大小写漂移。
/// 模型行为会随系统版本变，但这些**形状**的错误会一直存在，所以钉在这里。
@Suite
struct FoundationModelsValidatorTests {
    private let catalog = PromptCatalog(
        categories: [
            .init(id: "cat-academics", name: "Academics", colorHex: "#655f58", kind: "academics"),
            .init(id: "cat-research", name: "Research", colorHex: "#7f5fb5"),
            .init(id: "cat-personal", name: "Leisure", colorHex: "#bd5f86")
        ],
        tags: [
            .init(id: "tag-homework", name: "Homework"),
            .init(id: "tag-review", name: "review"),
            .init(id: "tag-urgent", name: "urgent")
        ],
        subjects: [
            .init(id: "sub-english", name: "English", categoryID: "cat-academics", colorHex: "#30b855"),
            .init(id: "sub-math", name: "Math", categoryID: "cat-academics", colorHex: "#ff3b30"),
            // 挂在非学业分类下的学科：清单里不该出现，也不该被接受。
            .init(id: "sub-stray", name: "Stray", categoryID: "cat-research", colorHex: "#000000")
        ]
    )

    private func proposal(
        title: String = "物理作业",
        category: String = "Academics",
        subject: String? = nil,
        tags: [String] = [],
        priority: PriorityProposal = .normal
    ) -> DraftProposal {
        DraftProposal(
            title: title,
            categoryName: category,
            subjectName: subject,
            tagNames: tags,
            priority: priority,
            reason: "测试"
        )
    }

    private func accepted(_ outcome: Validator.Outcome) throws -> CheckedProposal {
        guard case .accepted(let checked) = outcome else {
            Issue.record("期望通过校验，实际被拒：\(outcome)")
            throw CancellationError()
        }
        return checked
    }

    private func rejection(_ outcome: Validator.Outcome) throws -> String {
        guard case .rejected(let complaint) = outcome else {
            Issue.record("期望被拒，实际通过了校验")
            throw CancellationError()
        }
        return complaint
    }

    // MARK: - 该重试的：分类与学科

    @Test("编造的分类名必须被拒，且抱怨里要列出合法值")
    func inventedCategoryIsRejected() throws {
        let complaint = try rejection(Validator.validate(proposal(category: "Study"), catalog: catalog))
        #expect(complaint.contains("Study"))
        // 只说「不合法」模型只会再猜一次，必须把清单给它。
        #expect(complaint.contains("Academics"))
        #expect(complaint.contains("Leisure"))
        // 不写这句的话，模型会借着重试把标题和标签一起改了。
        #expect(complaint.contains("Keep everything else"))
    }

    @Test("编造的学科名必须被拒")
    func inventedSubjectIsRejected() throws {
        let complaint = try rejection(
            Validator.validate(proposal(subject: "Chemistry"), catalog: catalog)
        )
        #expect(complaint.contains("Chemistry"))
        #expect(complaint.contains("English"))
    }

    @Test("学科不属于所选分类时必须被拒，而不是硬写进去吃后端 400")
    func subjectFromAnotherCategoryIsRejected() throws {
        // English 挂在 Academics 下，这里分类却选了 Research。
        let complaint = try rejection(
            Validator.validate(proposal(category: "Research", subject: "English"), catalog: catalog)
        )
        #expect(complaint.contains("does not belong"))
    }

    @Test("非学业分类下的学科不进清单，模型选了也算编造")
    func subjectOutsideAcademicsIsNotOffered() throws {
        #expect(catalog.academicSubjects.map(\.name) == ["English", "Math"])
        let complaint = try rejection(
            Validator.validate(proposal(category: "Research", subject: "Stray"), catalog: catalog)
        )
        #expect(complaint.contains("Stray"))
    }

    // MARK: - 该直接修的：大小写、空值写法、标签

    @Test("分类名大小写漂移能自动规范化，不浪费一轮推理")
    func categoryCaseIsNormalized() throws {
        let checked = try accepted(Validator.validate(proposal(category: "academics"), catalog: catalog))
        #expect(checked.category?.id == "cat-academics")
        #expect(checked.category?.name == "Academics")
    }

    @Test("标签大小写漂移取目录里的原名", arguments: ["Review", "REVIEW", "review"])
    func tagCaseIsNormalized(_ written: String) throws {
        let checked = try accepted(Validator.validate(proposal(tags: [written]), catalog: catalog))
        #expect(checked.tags.map(\.name) == ["review"])
    }

    @Test("编造的标签只丢弃不重试——标签是可选的，不值得让用户多等一轮")
    func inventedTagsAreDroppedNotRejected() throws {
        let checked = try accepted(
            Validator.validate(proposal(tags: ["Reading", "Report"]), catalog: catalog)
        )
        #expect(checked.tags.isEmpty)
        #expect(checked.category?.id == "cat-academics")
    }

    @Test("合法标签留下，非法的丢掉")
    func mixedTagsKeepOnlyTheValidOnes() throws {
        let checked = try accepted(
            Validator.validate(proposal(tags: ["Homework", "friends"]), catalog: catalog)
        )
        #expect(checked.tags.map(\.id) == ["tag-homework"])
    }

    @Test("重复标签去重")
    func duplicateTagsAreCollapsed() throws {
        let checked = try accepted(
            Validator.validate(proposal(tags: ["Homework", "homework"]), catalog: catalog)
        )
        #expect(checked.tags.count == 1)
    }

    @Test("标签数量卡在后端的 5 个上限，不等提交才吃 400")
    func tagsAreCappedAtTheBackendLimit() throws {
        let many = PromptCatalog(
            categories: catalog.categories,
            tags: (1...8).map { .init(id: "tag-\($0)", name: "t\($0)") },
            subjects: catalog.subjects
        )
        let checked = try accepted(
            Validator.validate(proposal(tags: (1...8).map { "t\($0)" }), catalog: many)
        )
        #expect(checked.tags.count == 5)
    }

    @Test("模型表达「没有学科」的几种写法都当作空", arguments: ["", "  ", "无", "none", "N/A", "-"])
    func nullishSubjectsAreTreatedAsEmpty(_ written: String) throws {
        let checked = try accepted(Validator.validate(proposal(subject: written), catalog: catalog))
        #expect(checked.subject == nil)
    }

    @Test("非学业分类下的学科被清空——后端要求 subject_id 必须为空，否则 400")
    func subjectIsClearedOutsideAcademics() throws {
        let checked = try accepted(
            Validator.validate(proposal(category: "Leisure", subject: nil), catalog: catalog)
        )
        #expect(checked.category?.kind != "academics")
        #expect(checked.subject == nil)
    }

    // MARK: - 兜底

    /// 兜底的规矩是「能查到的留下，查不到的丢掉，**绝不猜**」。
    /// 这里三样都查不到或对不上：分类 "Study"、学科 "Chemistry"、标签 "Reading"。
    @Test("重试用完后兜底：查不到的值一律丢掉，不拿它们硬填")
    func salvageDropsWhatItCannotResolve() {
        let salvaged = Validator.salvage(
            proposal(category: "Study", subject: "Chemistry", tags: ["Homework", "Reading"]),
            catalog: catalog
        )
        #expect(salvaged.category?.id == "cat-academics")
        #expect(salvaged.subject == nil)
        #expect(salvaged.tags.map(\.id) == ["tag-homework"])
    }

    // MARK: - 提示词

    @Test("目录查找容忍模型多打的空格", arguments: [" Academics", "Academics ", " academics "])
    func leadingWhitespaceIsTolerated(_ written: String) throws {
        // 真实目录上实测到过：模型回 " Academics"、" Other Subjects"。
        // 当成非法值打回去重试，白等一轮推理，答案还是同一个。
        let checked = try accepted(Validator.validate(proposal(category: written), catalog: catalog))
        #expect(checked.category?.id == "cat-academics")
    }

    @Test("分类清单必须带用途说明，否则模型把什么都归进第一个分类")
    func categoriesCarryTheirPurpose() {
        // 用真实目录跑的探针里，只给名字时 10 个输入 10 个 Academics，
        // 连「续费 iCloud」都算学业。
        let text = PromptBuilder.request(catalog: catalog, userText: "续费 iCloud")
        #expect(text.contains("Academics — "))
        #expect(text.contains("Leisure — "))
        // 说明文字不能用标签名当例子：早期版本把 Leisure 写成 "friends, rest"，
        // 模型转头就把它们当标签填了。
        for tag in catalog.tags.map(\.name) {
            #expect(!text.contains("— \(tag)"), "分类说明里不该出现标签名 \(tag)")
        }
    }

    @Test("提示词把全部合法值都给了模型，且用户原文被隔离起来")
    func promptCarriesTheWholeCatalog() {
        let text = PromptBuilder.request(catalog: catalog, userText: "把作文改完")
        for name in ["Academics", "Research", "Leisure", "English", "Math", "Homework", "review"] {
            #expect(text.contains(name), "提示词缺少合法值 \(name)")
        }
        // 非学业学科不能出现在清单里，否则模型选了它必然被拒。
        #expect(!text.contains("Stray"))
        // 用户原文是不可信输入，必须有明确边界。
        #expect(text.contains("<user_text>\n把作文改完\n</user_text>"))
    }

    // MARK: - 时间仍归正则

    @Test("日期时间不走模型：正则入口必须解出用户说的钟点")
    func timingStaysDeterministic() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 16, minute: 50))!

        let timing = MockAIDeadlineParser.timing(in: "明天下午三点前把物理作业交了", now: now)
        // 探针里模型把这句解成 16 点——它抄了提示词里的当前时间。正则不会。
        #expect(calendar.component(.hour, from: timing.date) == 15)
        #expect(timing.isAllDay == false)
        #expect(timing.wasExplicit)
    }
}
