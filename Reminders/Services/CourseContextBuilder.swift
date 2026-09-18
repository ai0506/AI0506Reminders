import Foundation

/// Calendar 课程目录里的一门课（`GET /api/course-catalog`）。
///
/// 目录**包含停用课程**：历史课程仍然要能被名字命中，Calendar 也仍然允许把新的
/// Deadline 关联到停用课程上（详见 `../Calendar/API_DOC.md` 的 `course_id` 校验小节）。
struct Course: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let subjectID: String?
    let active: Bool
}

/// 某一天的一节课（`GET /api/course-schedule` 的投影行，不落库）。
///
/// 被请假的课在后端就已经从投影里消失了，不会返回 `cancelled` 状态的行，
/// 所以这里拿到的每一节都是真的上了（或将要上）的课。
struct CourseOccurrence: Identifiable, Hashable {
    let id: String
    let courseID: String
    let title: String
    let subjectID: String?
    let start: Date
    let end: Date
}

/// 交给设备端模型的一个候选课程。
struct CourseCandidate: Identifiable, Hashable {
    let course: Course
    /// 今天那一节已经结束的课；direct match 时可能为 nil（周末提到旧课程名也算命中）。
    let completedOccurrence: CourseOccurrence?
    /// 这门课下已存在的未完成作业。**只是 metadata**：它不能把课程从候选里排除，
    /// 一门课已经录过作业不代表今天不会再留一份。
    let openCoursework: [Deadline]
    /// 这门课的下一次上课，用于 `next_course` 截止策略（由 app 落成绝对时间，模型不算日期）。
    let nextOccurrence: CourseOccurrence?

    var id: String { course.id }
}

/// 候选构建的结果。
enum CourseContext: Hashable {
    /// 用户在输入里写全了课程名，且全目录里唯一命中——**由 app 定死，模型不能覆盖**。
    case direct(CourseCandidate)
    /// 没有直接命中，交给模型在这些候选里选（至多三个，按最近结束排序）。
    case contextual([CourseCandidate])
    /// 没有任何候选，`course_id` 保持 nil。
    case none
}

/// 纯函数式的候选构建：不发请求、不碰状态、不做语义判断。
///
/// 分工是刻意的——确定性的部分（谁今天上过课、哪门课有未完成作业、下次什么时候上）
/// 全在这里算完，模型只负责「这句话更像哪一门课的作业」。这样周末、时区、单双周
/// 这些容易算错的东西不会被交给模型去猜。
struct CourseContextBuilder {
    /// 交给模型的候选上限。再多模型也分辨不出来，而且提示词会被稀释。
    static let maxContextualCandidates = 3
    /// 判定「已录作业」时认的任务性质标签。
    static let courseworkTagNames: Set<String> = ["homework", "assignment"]

    private let timeZone: TimeZone

    init(timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current) {
        self.timeZone = timeZone
    }

    func build(
        input: String,
        catalog: [Course],
        occurrences: [CourseOccurrence],
        openDeadlines: [Deadline],
        now: Date = .now
    ) -> CourseContext {
        let courseworkByCourse = openCourseworkByCourse(openDeadlines)
        let nextByCourse = nextOccurrenceByCourse(occurrences, now: now)

        // 1) 直接命名优先，而且是在**完整目录**里找，不受当天课表限制：
        //    周末说「ESL 1层雅思写作的作文」也该命中那门课。
        if let matched = directMatch(input: input, catalog: catalog) {
            return .direct(CourseCandidate(
                course: matched,
                completedOccurrence: latestCompletedToday(occurrences, courseID: matched.id, now: now),
                openCoursework: courseworkByCourse[matched.id] ?? [],
                nextOccurrence: nextByCourse[matched.id]
            ))
        }

        // 2) 否则才看今天已经上完的课，按结束时间倒序去重取前三。
        let coursesByID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let candidates = completedToday(occurrences, now: now)
            .sorted { $0.end > $1.end }
            .compactMap { occurrence -> CourseCandidate? in
                guard seen.insert(occurrence.courseID).inserted,
                      let course = coursesByID[occurrence.courseID] else { return nil }
                return CourseCandidate(
                    course: course,
                    completedOccurrence: occurrence,
                    openCoursework: courseworkByCourse[course.id] ?? [],
                    nextOccurrence: nextByCourse[course.id]
                )
            }
            .prefix(Self.maxContextualCandidates)

        return candidates.isEmpty ? .none : .contextual(Array(candidates))
    }

    // MARK: - 组件

    /// 唯一完整名称命中。第一版不做别名，也不做部分词匹配：
    /// 宁可退回 contextual 候选，也不要猜错课程。
    private func directMatch(input: String, catalog: [Course]) -> Course? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let matches = catalog.filter { course in
            let name = course.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return false }
            return text.localizedCaseInsensitiveContains(name)
        }
        // 同名或同时命中多门课时不算直接命中——分不清就交给模型，别赌。
        let distinct = Set(matches.map(\.id))
        guard distinct.count == 1 else { return nil }
        return matches.first
    }

    private func completedToday(_ occurrences: [CourseOccurrence], now: Date) -> [CourseOccurrence] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return occurrences.filter { $0.end <= now && calendar.isDate($0.end, inSameDayAs: now) }
    }

    private func latestCompletedToday(_ occurrences: [CourseOccurrence], courseID: String, now: Date) -> CourseOccurrence? {
        completedToday(occurrences, now: now)
            .filter { $0.courseID == courseID }
            .max { $0.end < $1.end }
    }

    private func nextOccurrenceByCourse(_ occurrences: [CourseOccurrence], now: Date) -> [String: CourseOccurrence] {
        occurrences
            .filter { $0.start > now }
            .sorted { $0.start < $1.start }
            .reduce(into: [:]) { result, occurrence in
                if result[occurrence.courseID] == nil { result[occurrence.courseID] = occurrence }
            }
    }

    /// 未完成 = 未完成且未软删除；**逾期也算未完成**，所以取这批数据的请求不能带日期窗口，
    /// 否则过期未交的作业会从课程上下文里消失。
    private func openCourseworkByCourse(_ deadlines: [Deadline]) -> [String: [Deadline]] {
        deadlines.reduce(into: [:]) { result, deadline in
            guard let courseID = deadline.courseID, !deadline.isCompleted else { return }
            let isCoursework = deadline.tags.contains {
                Self.courseworkTagNames.contains($0.name.lowercased())
            }
            guard isCoursework else { return }
            result[courseID, default: []].append(deadline)
        }
    }
}
