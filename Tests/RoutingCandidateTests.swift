import Foundation
import Testing
@testable import AI0506_Reminders

/// 候选表是 V2 的安全带：模型只能从这里面挑，所以**非法组合根本不能出现在表里**。
/// 这些用例盯的就是「表里有没有它不该有的东西」和「表里会不会漏掉该有的路线」。
@Suite
struct RoutingCandidateBuilderTests {
    private let academics = DeadlineCategory(id: "cat-academics", name: "Academics", colorHex: "#655f58", kind: "academics")
    private let research = DeadlineCategory(id: "cat-research", name: "Research", colorHex: "#7f5fb5")
    private let leisure = DeadlineCategory(id: "cat-leisure", name: "Leisure", colorHex: "#bd5f86")

    private var physics: DeadlineSubject { .init(id: "sub-physics", name: "Physics", categoryID: "cat-academics", colorHex: "#32ade6") }
    private var english: DeadlineSubject { .init(id: "sub-english", name: "English", categoryID: "cat-academics", colorHex: "#30b855") }
    /// 挂在非学业分类下的学科。后端不允许，候选表也不该给出通往它的路线。
    private var stray: DeadlineSubject { .init(id: "sub-stray", name: "Stray", categoryID: "cat-research", colorHex: "#000000") }

    private var catalog: PromptCatalog {
        PromptCatalog(categories: [academics, research, leisure],
                      tags: [.init(id: "tag-exam", name: "exam")],
                      subjects: [physics, english, stray])
    }

    private let physicsCourse = Course(id: "course-physics", name: "AS物理 L1", subjectID: "sub-physics", active: true)
    private let writing = Course(id: "course-writing", name: "ESL 1层 雅思写作", subjectID: "sub-english", active: true)
    private let speaking = Course(id: "course-speaking", name: "ESL 1层B 雅思口语", subjectID: "sub-english", active: true)
    /// 学科 id 在目录里查不到的课程：数据漂移时必须被丢掉，不能带着挂不上的 subject 进候选。
    private let orphan = Course(id: "course-orphan", name: "AS化学 L1", subjectID: "sub-gone", active: true)

    private func interpretation(
        title: String = "写完",
        nature: TaskNature = .coursework,
        subjectHint: String? = nil,
        courseHint: String? = nil
    ) -> SemanticInterpretation {
        SemanticInterpretation(title: title, taskNature: nature,
                               subjectHint: subjectHint, courseHint: courseHint, reason: "测试")
    }

    private func build(
        text: String,
        interpretation: SemanticInterpretation? = nil,
        courses: [Course] = [],
        context: CourseContext = .none
    ) -> [RoutingCandidate] {
        RoutingCandidateBuilder.build(
            interpretation: interpretation ?? self.interpretation(),
            originalText: text,
            catalog: catalog,
            courses: courses,
            courseContext: context
        )
    }

    private func candidate(_ course: Course, completed: Bool = true) -> CourseCandidate {
        CourseCandidate(course: course, completedOccurrence: nil, openCoursework: [], nextOccurrence: nil)
    }

    @Test
    func everyCategoryGetsACategoryOnlyRoute() {
        let routes = build(text: "随便写点什么")
        let categoryOnly = routes.filter { $0.evidence == .categoryOnly && $0.key != RoutingCandidateBuilder.unresolvedKey }
        #expect(Set(categoryOnly.map(\.category.name)) == ["Academics", "Research", "Leisure"])
        #expect(categoryOnly.allSatisfy { $0.subject == nil && $0.course == nil })
    }

    @Test
    func thereIsAlwaysAnExplicitUnresolvedChoice() {
        let routes = build(text: "随便写点什么")
        let unresolved = try? #require(routes.last)
        #expect(unresolved?.key == RoutingCandidateBuilder.unresolvedKey)
        #expect(RoutingCandidateBuilder.isUnresolved(routes.last!))
    }

    /// 挂在 Research 下的学科不该有路线：后端只允许 academics 分类带 subject_id。
    @Test
    func subjectRoutesOnlyExistUnderTheirOwnAcademicCategory() {
        let routes = build(text: "随便写点什么")
        let subjectRoutes = routes.filter { $0.subject != nil }
        #expect(Set(subjectRoutes.map(\.subject!.name)) == ["Physics", "English"])
        #expect(subjectRoutes.allSatisfy { $0.category.kind == "academics" })
    }

    @Test
    func aNamedCourseBecomesTheStrongestRoute() {
        let routes = build(text: "AS物理 L1 的卷子", courses: [physicsCourse],
                           context: .direct(candidate(physicsCourse)))
        let course = try? #require(routes.first { $0.course?.id == physicsCourse.id })
        #expect(course?.evidence == .courseNamedByUser)
        #expect(course?.subject?.name == "Physics")
        #expect(course?.category.name == "Academics")
    }

    /// 页码写法指向计算机，这里用物理的「卷子」验同一条通路：习惯命中要能造出课程路线。
    @Test
    func aWritingHabitBecomesACourseRoute() {
        let routes = build(text: "卷子写完", courses: [physicsCourse])
        let course = try? #require(routes.first { $0.course != nil })
        #expect(course?.course?.id == physicsCourse.id)
        #expect(course?.evidence == .courseFromHabit)
    }

    /// 学科线索只是线索：查得到、而且那个学科只有一门课，才算证据。
    @Test
    func aSubjectHintYieldsACourseOnlyWhenTheSubjectHasExactlyOne() {
        let single = build(text: "做点东西", interpretation: interpretation(subjectHint: "Physics"),
                           courses: [physicsCourse])
        #expect(single.contains { $0.course?.id == physicsCourse.id && $0.evidence == .onlyCourseOfSubject })

        let many = build(text: "做点东西", interpretation: interpretation(subjectHint: "English"),
                         courses: [writing, speaking])
        #expect(!many.contains { $0.evidence == .onlyCourseOfSubject })
    }

    @Test
    func todaysCoursesBecomeTheWeakestRoutes() {
        let routes = build(text: "做点东西", courses: [writing, speaking],
                           context: .contextual([candidate(writing), candidate(speaking)]))
        let courseRoutes = routes.filter { $0.course != nil }
        #expect(courseRoutes.count == 2)
        #expect(courseRoutes.allSatisfy { $0.evidence == .courseFinishedToday })
    }

    /// 论文类笔记不挂课程，但分类和学科路线照常给——不在客户端硬编码「Research」这个名字。
    @Test
    func researchWordingRemovesCourseRoutesButKeepsTheRest() {
        let routes = build(text: "论文 Introduction 完成", courses: [writing, speaking],
                           context: .contextual([candidate(writing)]))
        #expect(!routes.contains { $0.course != nil })
        #expect(routes.contains { $0.category.name == "Research" })
        #expect(routes.contains { $0.subject?.name == "English" })
    }

    /// 但原文点名了课程时不拦：「经济学的论文」是那门课的课业，不是科研论文。
    @Test
    func aNamedCourseSurvivesTheResearchWording() {
        let routes = build(text: "AS物理 L1 的论文", courses: [physicsCourse],
                           context: .direct(candidate(physicsCourse)))
        #expect(routes.contains { $0.course?.id == physicsCourse.id && $0.evidence == .courseNamedByUser })
    }

    /// 课程的 subject_id 在目录里查不到时整条丢掉。带着挂不上的学科写入会被后端拒。
    @Test
    func aCourseWhoseSubjectIsMissingNeverEntersTheTable() {
        let routes = build(text: "做点东西", courses: [orphan],
                           context: .direct(candidate(orphan)))
        #expect(!routes.contains { $0.course != nil })
    }

    @Test
    func courseRoutesAreCappedAndOrderedByEvidence() {
        let extra = Course(id: "course-el", name: "EL L1", subjectID: "sub-english", active: true)
        let fourth = Course(id: "course-pe", name: "PE", subjectID: "sub-physics", active: true)
        let routes = build(
            text: "卷子写完",
            courses: [physicsCourse, writing, speaking, extra, fourth],
            context: .contextual([candidate(writing), candidate(speaking), candidate(extra), candidate(fourth)])
        )
        let courseRoutes = routes.filter { $0.course != nil }
        #expect(courseRoutes.count == RoutingCandidateBuilder.maxCourseRoutes)
        // 「卷子」命中习惯，但物理下有两门课（AS物理 L1 与 PE），习惯推不出唯一一门，
        // 所以这里剩下的全是当天课表那条最弱的证据。
        #expect(courseRoutes.first?.evidence.strength ?? 0 >= courseRoutes.last?.evidence.strength ?? 0)
    }

    /// 同一句输入跑两次，候选表必须逐项相同——否则回归测试没法比。
    @Test
    func theTableIsStableAcrossRuns() {
        func run() -> [String] {
            build(text: "卷子写完", courses: [physicsCourse, writing, speaking],
                  context: .contextual([candidate(writing), candidate(speaking)]))
                .map { "\($0.key)|\($0.label)" }
        }
        #expect(run() == run())
    }

    @Test(arguments: ["R1", " R1 ", "r1"])
    func lookupTrimsAndIgnoresCase(key: String) {
        let routes = build(text: "随便写点什么")
        #expect(RoutingCandidateBuilder.candidate(forKey: key, in: routes)?.key == "R1")
    }

    /// 模型给了表外的 key 时必须查不到，**不能回落到第一项**。
    /// V1 在这里猜过一次目录第一项，结果所有分不清的输入都变成了 Academics。
    @Test(arguments: ["R99", "", "  ", "Academics"])
    func lookupNeverGuessesForAnUnknownKey(key: String) {
        let routes = build(text: "随便写点什么")
        #expect(RoutingCandidateBuilder.candidate(forKey: key, in: routes) == nil)
    }

    @Test
    func theLabelShowsTheHierarchyAndNoIDs() {
        let routes = build(text: "AS物理 L1 的卷子", courses: [physicsCourse],
                           context: .direct(candidate(physicsCourse)))
        let course = routes.first { $0.course != nil }
        #expect(course?.label == "Academics › Physics › AS物理 L1")
        #expect(routes.allSatisfy { !$0.label.contains("cat-") && !$0.label.contains("sub-") && !$0.label.contains("course-") })
    }
}
