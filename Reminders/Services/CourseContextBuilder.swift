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
            // 今天上过、而且还没记过作业的课排前面：刚上完又没录入，正是最可能要记的那门。
            //
            // 这是**排序**，不是排除——上面那条注释说的「已有作业不能把课程踢出候选」仍然成立，
            // 有作业的课只是排在后面。而且 directMatch 走的是完整目录、不受候选数限制，
            // 用户写了课程名时一定能命中它。
            .sorted { lhs, rhs in
                if lhs.openCoursework.isEmpty != rhs.openCoursework.isEmpty {
                    return lhs.openCoursework.isEmpty
                }
                return (lhs.completedOccurrence?.end ?? .distantPast) > (rhs.completedOccurrence?.end ?? .distantPast)
            }
            .prefix(Self.maxContextualCandidates)

        return candidates.isEmpty ? .none : .contextual(Array(candidates))
    }

    // MARK: - 组件

    /// 字面命中：先试全名，再试去掉编制修饰后的短名。
    ///
    /// 只比全名的话覆盖不了真实写法——课程在 Calendar 里叫「AS物理 L1」「ESL 1层 雅思写作」，
    /// 而用户写的是「物理卷子」「经济学的论文」。实测去掉 AS/ESL 前缀与 L1A/1层B 这类
    /// 等级标记之后，「经济学的论文」能命中 AS经济、「雅思口语作业」能命中 ESL 1层B 雅思口语，
    /// 这两条在纯靠模型判断时是错的。
    ///
    /// 两种都要求**唯一**命中：分不清就退回候选交给模型，别赌。
    private func directMatch(input: String, catalog: [Course]) -> Course? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let exact = uniqueMatch(in: catalog, text: text, key: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }) {
            return exact
        }
        return uniqueMatch(in: catalog, text: text, key: { Self.shortName($0.name) })
    }

    private func uniqueMatch(in catalog: [Course], text: String, key: (Course) -> String) -> Course? {
        let matches = catalog.filter { course in
            let needle = key(course)
            guard !needle.isEmpty, Self.isDistinctiveEnough(needle) else { return false }
            return text.localizedCaseInsensitiveContains(needle)
        }
        guard Set(matches.map(\.id)).count == 1 else { return nil }
        return matches.first
    }

    /// 去掉学校的编制修饰，留下用户嘴里会说的那部分。
    /// 「AS物理 L1」→「物理」，「ESL 1层B 雅思口语」→「雅思口语」，「AS经济」→「经济」。
    static func shortName(_ name: String) -> String {
        var value = name
        value = value.replacingOccurrences(of: #"\bL\d+[A-Za-z]?\b"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\d+层[A-Za-z]?"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"^\s*(AS|ESL)\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        return value.trimmingCharacters(in: .whitespaces)
    }

    /// 短名太短就不参与匹配，否则到处误命中。
    /// 「EL L1」和「PE」去掉修饰只剩两个字母，几乎任何一句英文里都能撞上；
    /// 中文两个字（「物理」「经济」）已经足够独特。
    private static func isDistinctiveEnough(_ needle: String) -> Bool {
        let isPlainASCII = needle.allSatisfy { $0.isASCII }
        return isPlainASCII ? needle.count >= 4 : needle.count >= 2
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
