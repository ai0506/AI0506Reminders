import Foundation
import Testing
@testable import AI0506_Reminders

/// 课程推断是确定性的那一半：模型只给学科，这门课挂在哪由规则定。
///
/// 数据用的是机主的真实课表（`Calendar/migrations/0014`）与真实学科目录，因为这些
/// 规则本来就是照着他的课表现实写的——Physics / CS / Math 各只有一门课，English 有五门。
@Suite
struct CourseResolverTests {
    private let subjects: [DeadlineSubject] = [
        .init(id: "sub-math", name: "Math", categoryID: "cat-academics", colorHex: "#ff3b30"),
        .init(id: "sub-physics", name: "Physics", categoryID: "cat-academics", colorHex: "#32ade6"),
        .init(id: "sub-cs", name: "CS", categoryID: "cat-academics", colorHex: "#30b855"),
        .init(id: "sub-english", name: "English", categoryID: "cat-academics", colorHex: "#ff9f0a"),
        .init(id: "sub-other", name: "Other Subjects", categoryID: "cat-academics", colorHex: "#0a84ff")
    ]
    private let catalog: [Course] = [
        .init(id: "c01", name: "AS物理 L1", subjectID: "sub-physics", active: true),
        .init(id: "c02", name: "AS经济", subjectID: "sub-other", active: true),
        .init(id: "c03", name: "ESL 1层A 雅思外教口语", subjectID: "sub-english", active: true),
        .init(id: "c06", name: "计算机", subjectID: "sub-cs", active: true),
        .init(id: "c07", name: "AS数学 L1A", subjectID: "sub-math", active: true),
        .init(id: "c09", name: "ESL 1层 雅思写作", subjectID: "sub-english", active: true),
        .init(id: "c10", name: "EL L1", subjectID: "sub-english", active: true),
        .init(id: "c11", name: "ESL 1层B 雅思口语", subjectID: "sub-english", active: true)
    ]

    private func candidate(_ id: String, subject: String) -> CourseCandidate {
        CourseCandidate(
            course: catalog.first { $0.id == id }!,
            completedOccurrence: nil,
            openCoursework: [],
            nextOccurrence: nil
        )
    }

    private func resolve(_ input: String, subject: String? = nil, named: Course? = nil,
                         candidates: [CourseCandidate] = []) -> CourseResolver.Resolution {
        CourseResolver.resolve(input: input, named: named, modelSubjectName: subject,
                               catalog: catalog, candidates: candidates, subjects: subjects)
    }

    @Test("原文里写了课程名，没有比这更强的信号")
    func namedByUserWins() {
        let named = catalog.first { $0.id == "c02" }!
        // 模型说是 English 也没用——用户自己写了课程名。
        let r = resolve("经济学的论文", subject: "English", named: named)
        #expect(r.course?.id == "c02")
        #expect(r.subjectName == "Other Subjects")
        #expect(r.basis == .namedByUser)
    }

    @Test("「卷子」就是物理，哪怕模型判成了数学")
    func writingHabitOverridesTheModel() {
        let r = resolve("把卷子订正了", subject: "Math")
        #expect(r.course?.id == "c01")
        #expect(r.subjectName == "Physics")
        #expect(r.basis == .writingHabit)
    }

    @Test("页码指向计算机的习题册", arguments: [
        "习题册 25 26 27页", "p30-32", "第 30 页做完", "计算机 p12", "workbook pages 25 26 27", "P.14"
    ])
    func pageNumbersMeanTheCSWorkbook(_ input: String) {
        let r = resolve(input, subject: "Math")
        #expect(r.course?.id == "c06", "\(input) 应当指向计算机")
        #expect(r.subjectName == "CS")
    }

    @Test("同一学科下的多门英语课靠写法区分")
    func englishCoursesAreSeparatedByHabit() {
        #expect(resolve("雅思作文").course?.id == "c09")
        #expect(resolve("录一下口语音频").course?.id == "c11")
        #expect(resolve("文学分析写完").course?.id == "c10")
    }

    @Test("学科只有一门课时，学科就足以定下课程")
    func aSubjectWithOneCourseSettlesIt() {
        let r = resolve("数学作业", subject: "Math")
        #expect(r.course?.id == "c07")
        #expect(r.basis == .onlySubjectCourse)
    }

    @Test("学科有多门课且没有写法线索时，取今天上过的那门")
    func fallsBackToWhatFinishedToday() {
        let r = resolve("把剩下的写完", subject: "English",
                        candidates: [candidate("c10", subject: "sub-english")])
        #expect(r.course?.id == "c10")
        #expect(r.basis == .finishedToday)
    }

    @Test("目录里没有对应课程时，学科仍要保住")
    func subjectSurvivesAMissingCourse() {
        // 目录里没有物理课，但「卷子」仍然是物理的事。
        let r = CourseResolver.resolve(input: "卷子", named: nil, modelSubjectName: nil,
                                       catalog: catalog.filter { $0.subjectID != "sub-physics" },
                                       candidates: [], subjects: subjects)
        #expect(r.course == nil)
        #expect(r.subjectName == "Physics")
    }

    @Test("不是页码的数字不算", arguments: ["写完前三题", "第 4 章读完", "跑 5 公里"])
    func plainNumbersAreNotPageNumbers(_ input: String) {
        #expect(!CourseHabit.mentionsPageNumber(input), "\(input) 不该被当成页码")
    }

    @Test("没有任何线索就不猜")
    func noEvidenceMeansNoCourse() {
        let r = resolve("把那件事做完")
        #expect(r == .unresolved)
    }

    @Test("论文类关键词与课堂作文分得开")
    func researchMarkersAreDistinctFromClassEssays() {
        #expect(ResearchMarkers.matches("论文 Introduction 完成"))
        #expect(ResearchMarkers.matches("查重报告发给导师"))
        // 「作文」是英语课作业，不能被论文规则吃掉。
        #expect(!ResearchMarkers.matches("雅思作文"))
        #expect(!ResearchMarkers.matches("把作文改完"))
    }
}
