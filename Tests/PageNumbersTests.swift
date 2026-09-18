import Foundation
import Testing
@testable import AI0506_Reminders

/// 页码进备注，是机主在真机上提的：他记计算机作业就是写页码，
/// 那串数字是作业内容本身，只留在原文里的话过两天就不知道要做哪几页了。
///
/// 抄错一位就是做错作业，所以这里**宁可认不出，也不要认错**——
/// 下面一半用例钉的是「不该认出来的场合」。
@Suite
struct PageNumbersTests {
    /// 用户在真机上给的两个原话之一。注意这句**没写「页」**，
    /// 全靠「练习册」这个词才敢把光秃秃的数字当页码。
    @Test
    func theUsersOwnWorkbookWording() {
        #expect(PageNumbers.note(from: "cs练习册 25 26 27") == "P25, 26, 27")
    }

    @Test(arguments: [
        ("计算机练习册 25 26 27页", "P25, 26, 27"),
        ("习题册 25,26,27", "P25, 26, 27"),
        ("练习册 25、26", "P25, 26"),
        ("第30页", "P30"),
        ("第 30 页做完", "P30"),
        ("p30", "P30"),
        ("P25", "P25"),
        ("pages 12", "P12")
    ])
    func recognisesTheWaysHeWritesPages(input: String, expected: String) {
        #expect(PageNumbers.note(from: input) == expected)
    }

    /// 范围要保留成范围：`p30-32` 是三页，写成「P30, 32」就漏了中间那页。
    @Test(arguments: ["p30-32", "30~32页", "第30至32页"])
    func keepsARangeAsARange(input: String) {
        #expect(PageNumbers.note(from: input) == "P30-32")
    }

    /// 没有页码线索的句子一个字都不该往备注里写。
    @Test(arguments: [
        "写完物理卷子",
        "明天下午三点交作业",
        "跟朋友吃饭",
        "续费 iCloud",
        "论文 Introduction 完成"
    ])
    func staysSilentWithoutPageEvidence(input: String) {
        #expect(PageNumbers.note(from: input) == nil)
    }

    /// 只有一个光秃秃的数字时不认——「练习册 25」里的 25 也可能是题号。
    /// 写了「页」或「p」就另说，那是明确的。
    @Test
    func asingleBareNumberIsNotEnough() {
        #expect(PageNumbers.note(from: "练习册 25") == nil)
        #expect(PageNumbers.note(from: "练习册 25页") == "P25")
    }

    /// 句子里别的数字不能被当成页码。这条是最容易出错的地方：
    /// 有页码标记时按标记取，别顺手把时间里的数字也扫进来。
    @Test
    func doesNotSwallowUnrelatedNumbers() {
        #expect(PageNumbers.note(from: "练习册 p30-32 明天8点交") == "P30-32")
        #expect(PageNumbers.note(from: "练习册第25页 明天8点交") == "P25")
    }
}

/// 「下节课交」要真的算出时间——课表里就有那门课的下一次上课，没理由让模型猜。
@Suite
struct NextLessonMarkersTests {
    @Test(arguments: ["物理试卷 下节课交", "下一节课交", "下次课带过来", "hand in next lesson", "Next Class"])
    func recognisesTheWordingsHeUses(input: String) {
        #expect(NextLessonMarkers.matches(input))
    }

    @Test(arguments: ["明天下午三点交", "周五交", "卷子写完", "下周一交"])
    func staysOutOfTheWayOtherwise(input: String) {
        #expect(!NextLessonMarkers.matches(input))
    }

    private let physics = Course(id: "course-physics", name: "AS物理 L1", subjectID: "sub-physics", active: true)
    private let cs = Course(id: "course-cs", name: "计算机", subjectID: "sub-cs", active: true)

    private func occurrence(_ courseID: String, hour: Int) -> CourseOccurrence {
        let start = Calendar.shanghai.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: hour))!
        return CourseOccurrence(id: "\(courseID)-\(hour)", courseID: courseID, title: "课",
                                subjectID: nil, start: start, end: start.addingTimeInterval(2_700))
    }

    private func candidate(_ course: Course, next: CourseOccurrence?) -> CourseCandidate {
        CourseCandidate(course: course, completedOccurrence: nil, openCoursework: [], nextOccurrence: next)
    }

    @Test
    func takesTheNextLessonOfTheCourseThatWasNamed() {
        let next = occurrence(physics.id, hour: 9)
        let found = FoundationModelsDeadlineParser.nextOccurrence(
            of: physics, in: .direct(candidate(physics, next: next)))
        #expect(found?.start == next.start)
    }

    @Test
    func findsItAmongTodaysCandidates() {
        let next = occurrence(cs.id, hour: 14)
        let context = CourseContext.contextual([
            candidate(physics, next: occurrence(physics.id, hour: 9)),
            candidate(cs, next: next)
        ])
        #expect(FoundationModelsDeadlineParser.nextOccurrence(of: cs, in: context)?.start == next.start)
    }

    /// **拿另一门课的上课时间当截止时间，比没有时间更糟。**
    /// 候选里没有这门课时必须返回 nil，让调用方保留时间正则的结果。
    @Test
    func neverBorrowsAnotherCoursesLesson() {
        let context = CourseContext.contextual([candidate(physics, next: occurrence(physics.id, hour: 9))])
        #expect(FoundationModelsDeadlineParser.nextOccurrence(of: cs, in: context) == nil)
        #expect(FoundationModelsDeadlineParser.nextOccurrence(of: cs, in: .direct(candidate(physics, next: occurrence(physics.id, hour: 9)))) == nil)
    }

    @Test
    func handlesAMissingScheduleAndAMissingCourse() {
        #expect(FoundationModelsDeadlineParser.nextOccurrence(of: physics, in: .none) == nil)
        #expect(FoundationModelsDeadlineParser.nextOccurrence(of: nil, in: .direct(candidate(physics, next: occurrence(physics.id, hour: 9)))) == nil)
        // 课表里没有下一节：课程对得上也得返回 nil。
        #expect(FoundationModelsDeadlineParser.nextOccurrence(of: physics, in: .direct(candidate(physics, next: nil))) == nil)
    }
}
