import Foundation
import Testing
@testable import AI0506_Reminders

/// 课程候选构建是整条 AI 链路里**唯一确定性**的一段：谁今天上过课、哪门课已有未完成作业、
/// 下次什么时候上，全在这里算完，模型只做「更像哪一门」的判断。所以这里必须被钉死。
///
/// 时间锚点一律是 Asia/Shanghai，不是设备时区。
@Suite
struct CourseContextBuilderTests {
    private static let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    private static func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = shanghai
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: value)!
    }

    // 目录里混着一门停用课程：停用不代表不能被名字命中，也不代表不能再挂新作业。
    private let catalog: [Course] = [
        .init(id: "course-writing", name: "ESL 1层雅思写作", subjectID: "sub-english", active: true),
        .init(id: "course-el", name: "EL L1", subjectID: "sub-english", active: true),
        .init(id: "course-econ", name: "AS经济", subjectID: "sub-other", active: true),
        .init(id: "course-retired", name: "Speaking L1A", subjectID: "sub-english", active: false)
    ]

    private func occurrence(_ id: String, _ courseID: String, _ title: String, start: String, end: String) -> CourseOccurrence {
        .init(id: id, courseID: courseID, title: title, subjectID: "sub-english",
              start: Self.date(start), end: Self.date(end))
    }

    private func deadline(id: String, courseID: String?, tags: [String], completed: Bool = false, due: String = "2026-09-18 23:00") -> Deadline {
        Deadline(
            id: id,
            title: "作业 \(id)",
            detail: "",
            dueDate: Self.date(due),
            allDay: false,
            category: DeadlineCategory.all[0],
            subject: .init(id: "sub-english", name: "English", categoryID: "cat-academics", colorHex: "#ff9f0a"),
            courseID: courseID,
            tags: tags.map { .init(id: $0.lowercased(), name: $0) },
            priority: .default,
            status: completed ? .completed : .open,
            updatedAt: Self.date("2026-09-18 08:00")
        )
    }

    /// 2026-09-18 是周五。当天两节英语：写作 14:00-14:45，EL L1 15:00-15:45。
    private var friday: [CourseOccurrence] {
        [
            occurrence("course:slot-w:2026-09-18", "course-writing", "ESL 1层雅思写作", start: "2026-09-18 14:00", end: "2026-09-18 14:45"),
            occurrence("course:slot-e:2026-09-18", "course-el", "EL L1", start: "2026-09-18 15:00", end: "2026-09-18 15:45"),
            // 下周的两节，用来算 next occurrence。
            occurrence("course:slot-w:2026-09-24", "course-writing", "ESL 1层雅思写作", start: "2026-09-24 16:05", end: "2026-09-24 16:50"),
            occurrence("course:slot-e:2026-09-22", "course-el", "EL L1", start: "2026-09-22 13:10", end: "2026-09-22 13:55")
        ]
    }

    // MARK: 直接命名命中

    @Test
    func directNameMatchWinsAndIsNotLimitedToTodaysTimetable() {
        // 周日晚上，当天没有任何课；但用户写全了课程名，照样要命中。
        let context = CourseContextBuilder(timeZone: Self.shanghai).build(
            input: "ESL 1层雅思写作的作文改完",
            catalog: catalog,
            occurrences: friday,
            openDeadlines: [],
            now: Self.date("2026-09-20 21:00")
        )
        guard case .direct(let candidate) = context else {
            Issue.record("应当是 direct 命中，实际是 \(context)")
            return
        }
        #expect(candidate.course.id == "course-writing")
        #expect(candidate.completedOccurrence == nil)
    }

    @Test
    func directMatchWorksForARetiredCourse() {
        let context = CourseContextBuilder(timeZone: Self.shanghai).build(
            input: "Speaking L1A 的口语稿",
            catalog: catalog,
            occurrences: [],
            openDeadlines: [],
            now: Self.date("2026-09-20 21:00")
        )
        guard case .direct(let candidate) = context else {
            Issue.record("停用课程也应该能被名字命中，实际是 \(context)")
            return
        }
        #expect(candidate.course.id == "course-retired")
        #expect(candidate.course.active == false)
    }

    @Test
    func twoCoursesWithTheSameNameAreNotADirectMatch() {
        let ambiguous = catalog + [.init(id: "course-writing-b", name: "ESL 1层雅思写作", subjectID: "sub-english", active: true)]
        let context = CourseContextBuilder(timeZone: Self.shanghai).build(
            input: "ESL 1层雅思写作的作文",
            catalog: ambiguous,
            occurrences: friday,
            openDeadlines: [],
            now: Self.date("2026-09-18 16:50")
        )
        // 分不清就退回当天候选交给模型，不赌其中一门。
        guard case .contextual(let candidates) = context else {
            Issue.record("同名两门课不应直接命中，实际是 \(context)")
            return
        }
        #expect(candidates.count == 2)
    }

    // MARK: 当天候选

    @Test
    func contextualCandidatesComeFromCoursesThatAlreadyEndedToday() {
        let context = CourseContextBuilder(timeZone: Self.shanghai).build(
            input: "把作文改完",
            catalog: catalog,
            occurrences: friday,
            openDeadlines: [],
            now: Self.date("2026-09-18 15:20") // EL L1 还没下课
        )
        guard case .contextual(let candidates) = context else {
            Issue.record("应当有当天候选，实际是 \(context)")
            return
        }
        #expect(candidates.map(\.course.id) == ["course-writing"])
    }

    @Test
    func candidatesAreOrderedByMostRecentlyFinishedAndCappedAtThree() {
        var many = friday
        for (index, id) in ["course-econ", "course-retired"].enumerated() {
            many.append(occurrence("course:extra-\(index):2026-09-18", id, "x",
                                   start: "2026-09-18 09:0\(index)", end: "2026-09-18 09:4\(index)"))
        }
        let context = CourseContextBuilder(timeZone: Self.shanghai).build(
            input: "把作业写了",
            catalog: catalog,
            occurrences: many,
            openDeadlines: [],
            now: Self.date("2026-09-18 16:50")
        )
        guard case .contextual(let candidates) = context else {
            Issue.record("应当有当天候选，实际是 \(context)")
            return
        }
        #expect(candidates.count == CourseContextBuilder.maxContextualCandidates)
        // 最近结束的排最前：EL L1 15:45 > 写作 14:45 > 09:41 那节。
        #expect(candidates.map(\.course.id) == ["course-el", "course-writing", "course-retired"])
    }

    // MARK: - 短名命中

    @Test("去掉编制修饰后的短名", arguments: [
        ("AS物理 L1", "物理"),
        ("AS数学 L1A", "数学"),
        ("AS经济", "经济"),
        ("ESL 1层雅思写作", "雅思写作"),
        ("ESL 1层B 雅思口语", "雅思口语"),
        ("EL L1", "EL"),
        ("Speaking L1A", "Speaking"),
        ("计算机", "计算机")
    ])
    func shortNameStripsTheSchoolsScaffolding(_ input: String, _ expected: String) {
        #expect(CourseContextBuilder.shortName(input) == expected)
    }

    @Test("用户说的是短名也能命中：课程叫「AS经济」，他写的是「经济学的论文」")
    func shortNameMatchesWhatTheUserActuallyWrites() {
        let context = CourseContextBuilder(timeZone: Self.shanghai).build(
            input: "经济学的论文",
            catalog: catalog,
            occurrences: [],
            openDeadlines: [],
            now: Self.date("2026-09-19 10:00")
        )
        guard case .direct(let candidate) = context else {
            Issue.record("应当直接命中 AS经济，实际是 \(context)")
            return
        }
        #expect(candidate.course.id == "course-econ")
    }

    @Test("短名命中同样不受当天课表限制——周末写「雅思写作的作文」也算数")
    func shortNameMatchIsNotLimitedToTodaysTimetable() {
        let context = CourseContextBuilder(timeZone: Self.shanghai).build(
            input: "雅思写作的作文改完",
            catalog: catalog,
            occurrences: [],
            openDeadlines: [],
            now: Self.date("2026-09-19 10:00")
        )
        guard case .direct(let candidate) = context else {
            Issue.record("应当命中雅思写作，实际是 \(context)")
            return
        }
        #expect(candidate.course.id == "course-writing")
    }

    @Test("短名太短的课程不参与匹配，否则两个字母到处都能撞上")
    func tooShortAShortNameNeverMatches() {
        // 「EL L1」的短名是 "EL"，下面这句里就含 "el"（travel）。
        let context = CourseContextBuilder(timeZone: Self.shanghai).build(
            input: "book the travel tickets",
            catalog: catalog,
            occurrences: [],
            openDeadlines: [],
            now: Self.date("2026-09-19 10:00")
        )
        #expect(context == .none)
    }

    // MARK: - 候选排序

    @Test("今天上过、且还没记过作业的课排在前面")
    func coursesWithoutLoggedCourseworkComeFirst() {
        let context = CourseContextBuilder(timeZone: Self.shanghai).build(
            input: "把作业写了",
            catalog: catalog,
            // EL L1 15:45 比写作 14:45 晚，但 EL L1 已经记过作业了。
            occurrences: friday,
            openDeadlines: [deadline(id: "d1", courseID: "course-el", tags: ["Homework"])],
            now: Self.date("2026-09-18 16:50")
        )
        guard case .contextual(let candidates) = context else {
            Issue.record("应当有当天候选，实际是 \(context)")
            return
        }
        #expect(candidates.first?.course.id == "course-writing")
        // 排序不等于排除：一门课一天可以留两份作业，EL L1 必须仍在候选里。
        #expect(candidates.map(\.course.id).contains("course-el"))
    }

    @Test
    func oneCandidatePerCourseEvenWithTwoLessonsInADay() {
        let doubled = friday + [occurrence("course:slot-w2:2026-09-18", "course-writing", "ESL 1层雅思写作",
                                           start: "2026-09-18 10:00", end: "2026-09-18 10:45")]
        let context = CourseContextBuilder(timeZone: Self.shanghai).build(
            input: "作业", catalog: catalog, occurrences: doubled, openDeadlines: [],
            now: Self.date("2026-09-18 16:50")
        )
        guard case .contextual(let candidates) = context else {
            Issue.record("应当有当天候选，实际是 \(context)")
            return
        }
        #expect(candidates.filter { $0.course.id == "course-writing" }.count == 1)
        // 去重保留当天最后一节。
        let writing = candidates.first { $0.course.id == "course-writing" }
        #expect(writing?.completedOccurrence?.end == Self.date("2026-09-18 14:45"))
    }

    @Test
    func aCancelledLessonNeverBecomesACandidate() {
        // 请假的课在 /api/course-schedule 里就已经不返回了，所以这里等价于「投影里没有这一节」。
        let withoutWriting = friday.filter { $0.courseID != "course-writing" }
        let context = CourseContextBuilder(timeZone: Self.shanghai).build(
            input: "作业", catalog: catalog, occurrences: withoutWriting, openDeadlines: [],
            now: Self.date("2026-09-18 16:50")
        )
        guard case .contextual(let candidates) = context else {
            Issue.record("应当有当天候选，实际是 \(context)")
            return
        }
        #expect(!candidates.contains { $0.course.id == "course-writing" })
    }

    @Test
    func noLessonsTodayAndNoNameMatchYieldsNoContext() {
        let context = CourseContextBuilder(timeZone: Self.shanghai).build(
            input: "买牛奶", catalog: catalog, occurrences: friday, openDeadlines: [],
            now: Self.date("2026-09-20 10:00")
        )
        #expect(context == .none)
    }

    // MARK: 已有作业只是 metadata

    @Test
    func anExistingOpenHomeworkDoesNotRemoveTheCourseFromCandidates() {
        let context = CourseContextBuilder(timeZone: Self.shanghai).build(
            input: "作业",
            catalog: catalog,
            occurrences: friday,
            openDeadlines: [deadline(id: "d1", courseID: "course-el", tags: ["Homework"])],
            now: Self.date("2026-09-18 16:50")
        )
        guard case .contextual(let candidates) = context else {
            Issue.record("应当有当天候选，实际是 \(context)")
            return
        }
        // 已经录过作业的课**仍然**是候选，只是带上了 metadata；一门课一天可以留两份作业。
        let el = candidates.first { $0.course.id == "course-el" }
        #expect(el != nil)
        #expect(el?.openCoursework.map(\.id) == ["d1"])
        #expect(candidates.first { $0.course.id == "course-writing" }?.openCoursework.isEmpty == true)
    }

    @Test
    func overdueButUnfinishedCourseworkStillCountsAsMetadata() {
        let overdue = deadline(id: "old", courseID: "course-el", tags: ["Assignment"], due: "2026-09-10 23:00")
        let context = CourseContextBuilder(timeZone: Self.shanghai).build(
            input: "作业", catalog: catalog, occurrences: friday, openDeadlines: [overdue],
            now: Self.date("2026-09-18 16:50")
        )
        guard case .contextual(let candidates) = context else {
            Issue.record("应当有当天候选，实际是 \(context)")
            return
        }
        #expect(candidates.first { $0.course.id == "course-el" }?.openCoursework.map(\.id) == ["old"])
    }

    @Test
    func completedOrUntaggedDeadlinesAreNotCourseworkMetadata() {
        let noise = [
            deadline(id: "done", courseID: "course-el", tags: ["Homework"], completed: true),
            deadline(id: "untagged", courseID: "course-el", tags: []),
            deadline(id: "exam", courseID: "course-el", tags: ["Exam"]),
            deadline(id: "nocourse", courseID: nil, tags: ["Homework"])
        ]
        let context = CourseContextBuilder(timeZone: Self.shanghai).build(
            input: "作业", catalog: catalog, occurrences: friday, openDeadlines: noise,
            now: Self.date("2026-09-18 16:50")
        )
        guard case .contextual(let candidates) = context else {
            Issue.record("应当有当天候选，实际是 \(context)")
            return
        }
        #expect(candidates.first { $0.course.id == "course-el" }?.openCoursework.isEmpty == true)
    }

    // MARK: 下一次上课

    @Test
    func eachCandidateCarriesItsOwnNextOccurrence() {
        let context = CourseContextBuilder(timeZone: Self.shanghai).build(
            input: "作业", catalog: catalog, occurrences: friday, openDeadlines: [],
            now: Self.date("2026-09-18 16:50")
        )
        guard case .contextual(let candidates) = context else {
            Issue.record("应当有当天候选，实际是 \(context)")
            return
        }
        // next_course 的绝对时间由 app 给，模型不算日期。
        #expect(candidates.first { $0.course.id == "course-writing" }?.nextOccurrence?.start == Self.date("2026-09-24 16:05"))
        #expect(candidates.first { $0.course.id == "course-el" }?.nextOccurrence?.start == Self.date("2026-09-22 13:10"))
    }

    @Test
    func aCourseWithNoFutureLessonHasNoNextOccurrence() {
        let onlyToday = friday.filter { $0.start < Self.date("2026-09-19 00:00") }
        let context = CourseContextBuilder(timeZone: Self.shanghai).build(
            input: "作业", catalog: catalog, occurrences: onlyToday, openDeadlines: [],
            now: Self.date("2026-09-18 16:50")
        )
        guard case .contextual(let candidates) = context else {
            Issue.record("应当有当天候选，实际是 \(context)")
            return
        }
        #expect(candidates.allSatisfy { $0.nextOccurrence == nil })
    }

    // MARK: 目录之外的课程

    @Test
    func anOccurrenceWithoutACatalogEntryIsSkipped() {
        let stray = friday + [occurrence("course:ghost:2026-09-18", "course-ghost", "幽灵课",
                                         start: "2026-09-18 08:00", end: "2026-09-18 08:45")]
        let context = CourseContextBuilder(timeZone: Self.shanghai).build(
            input: "作业", catalog: catalog, occurrences: stray, openDeadlines: [],
            now: Self.date("2026-09-18 16:50")
        )
        guard case .contextual(let candidates) = context else {
            Issue.record("应当有当天候选，实际是 \(context)")
            return
        }
        #expect(!candidates.contains { $0.course.id == "course-ghost" })
    }
}
