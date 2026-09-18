import Foundation
import Testing
@testable import AI0506_Reminders

/// 可信状态要说人话，而且要说得**能指导用户去检查哪一项**。
/// 这些用例钉住的是「什么情况下必须提醒用户看一眼」，不是具体文案。
@Suite
struct DraftConfidenceTests {
    private func confidence(
        time: DraftConfidence.TimeBasis = .explicitTime,
        route: DraftConfidence.RouteBasis = .course(.courseNamedByUser),
        path: DraftConfidence.Path = .model
    ) -> DraftConfidence {
        DraftConfidence(timeBasis: time, routeBasis: route, path: path)
    }

    @Test
    func aFullyResolvedDraftNeedsNoCheck() {
        let state = confidence()
        #expect(!state.needsCheck)
        #expect(state.itemsToCheck.isEmpty)
        #expect(state.headline == "原文里提到了这门课")
    }

    @Test
    func anUnresolvedRouteAsksTheUserToPickTheCategory() {
        let state = confidence(route: .unresolved)
        #expect(state.needsCheck)
        #expect(state.itemsToCheck.contains("分类"))
    }

    /// 「今天上过这门课」是最弱的证据——同一天上过好几门课时它更接近猜测，要提醒。
    @Test
    func theWeakestCourseEvidenceAsksTheUserToCheckTheCourse() {
        #expect(confidence(route: .course(.courseFinishedToday)).itemsToCheck.contains("课程"))
        #expect(!confidence(route: .course(.courseNamedByUser)).itemsToCheck.contains("课程"))
        #expect(!confidence(route: .course(.courseFromHabit)).itemsToCheck.contains("课程"))
    }

    @Test
    func aDefaultedDueDateIsAlwaysSurfaced() {
        let state = confidence(time: .defaulted)
        #expect(state.itemsToCheck.contains("截止时间"))
        #expect(state.headline.contains("没识别出截止时间"))
    }

    /// 降级路径绝不能显得有把握。
    @Test(arguments: [DraftConfidence.Path.localRulesOnly, .conflicted, .modelAfterRetry])
    func everyDegradedPathNeedsCheck(path: DraftConfidence.Path) {
        #expect(confidence(path: path).needsCheck)
    }

    @Test
    func localRulesSayItPlainly() {
        #expect(confidence(path: .localRulesOnly).headline == "本地规则解析，请逐项检查")
    }

    @Test
    func timeBasisDistinguishesAClockTimeFromADayFromNothing() {
        #expect(DraftConfidence.timeBasis(isAllDay: false, wasExplicit: true) == .explicitTime)
        #expect(DraftConfidence.timeBasis(isAllDay: true, wasExplicit: true) == .explicitDay)
        #expect(DraftConfidence.timeBasis(isAllDay: true, wasExplicit: false) == .defaulted)
    }

    @Test
    func routeBasisReadsTheCandidateItWasGiven() {
        let academics = DeadlineCategory(id: "cat-academics", name: "Academics", colorHex: "#655f58", kind: "academics")
        let physics = DeadlineSubject(id: "sub-physics", name: "Physics", categoryID: "cat-academics", colorHex: "#32ade6")
        let course = Course(id: "course-physics", name: "AS物理 L1", subjectID: "sub-physics", active: true)

        #expect(DraftConfidence.routeBasis(for: nil) == .unresolved)
        #expect(DraftConfidence.routeBasis(for: RoutingCandidate(
            key: RoutingCandidateBuilder.unresolvedKey, category: academics,
            subject: nil, course: nil, evidence: .categoryOnly)) == .unresolved)
        #expect(DraftConfidence.routeBasis(for: RoutingCandidate(
            key: "R1", category: academics, subject: nil, course: nil,
            evidence: .categoryOnly)) == .categoryOnly)
        #expect(DraftConfidence.routeBasis(for: RoutingCandidate(
            key: "R2", category: academics, subject: physics, course: nil,
            evidence: .subjectOfCategory)) == .subject)
        #expect(DraftConfidence.routeBasis(for: RoutingCandidate(
            key: "R3", category: academics, subject: physics, course: course,
            evidence: .courseFromHabit)) == .course(.courseFromHabit))
    }
}

/// 优先级和标签是 V2 明确不交给模型的两项，规则得自己站得住。
@Suite
struct LocalDraftRulesTests {
    private let tags: [DeadlineTag] = [
        .init(id: "tag-exam", name: "exam"),
        .init(id: "tag-urgent", name: "urgent"),
        .init(id: "tag-review", name: "review")
    ]

    @Test(arguments: ["这个很重要", "urgent: 交表", "高优先级", "High priority"])
    func explicitUrgencyRaisesPriority(text: String) {
        #expect(LocalDraftRules.priority(for: text) == .high)
    }

    /// 没有明确证据就是普通优先级。
    ///
    /// 最后那句英文是真实撞到的：模型路径还在自己判优先级时，它在模拟器里连着两次
    /// 被标成「高」，而句子里没有任何紧急字样。现在优先级由这里决定，钉住它。
    @Test(arguments: ["写完物理卷子", "明天下午三点交作业", "计算机练习册 25 26 27页",
                      "Finish the physics worksheet tomorrow at 3pm",
                      "Book the travel tickets on Sunday"])
    func noEvidenceMeansDefaultPriority(text: String) {
        #expect(LocalDraftRules.priority(for: text) == .default)
    }

    @Test
    func tagsComeFromLiteralHitsOnly() {
        #expect(LocalDraftRules.tags(in: "复习准备考试", catalog: tags).map(\.name) == ["exam", "review"])
        #expect(LocalDraftRules.tags(in: "写完物理卷子", catalog: tags).isEmpty)
    }

    /// 后端硬上限是 5 个，客户端不卡的话超了要等提交才吃 400。
    @Test
    func tagsAreCappedAtTheBackendLimit() {
        let many = (1...8).map { DeadlineTag(id: "tag-\($0)", name: "t\($0)") }
        let text = many.map(\.name).joined(separator: " ")
        #expect(LocalDraftRules.tags(in: text, catalog: many).count == 5)
    }
}
