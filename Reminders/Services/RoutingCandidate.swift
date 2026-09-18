import Foundation

/// 一条完整、层级合法的归档路线：分类 →（学科）→（课程）。
///
/// 模型在 Pass B 只能从这些里面选一个 `key`，**不能自己填分类名、学科名或课程名**。
/// V1 让模型直接写名字，于是要在校验层反复处理编造的名字、大小写漂移和多出来的空格；
/// 这里换成「代码出选项、模型选序号、代码再把序号换回真实对象」，那类错误从根上没有了。
/// 模型看不到任何后端 id。
struct RoutingCandidate: Identifiable, Equatable {
    /// 只在本次请求内有效的编号，由代码生成。
    let key: String
    let category: DeadlineCategory
    let subject: DeadlineSubject?
    let course: Course?
    let evidence: RoutingEvidence

    var id: String { key }

    /// 给模型看的一行。刻意极短——Pass B 的 prompt 要留在 4096 token 窗口里，
    /// 而且路线越啰嗦，模型越容易去读描述而不是比对 Pass A 的理解。
    var label: String {
        [category.name, subject?.name, course?.name]
            .compactMap { $0 }
            .joined(separator: " › ")
    }
}

/// 这条路线是凭什么造出来的。用户要在草稿页看得见依据，才好决定要不要改。
enum RoutingEvidence: Equatable {
    /// 只到分类，没有更细的证据。
    case categoryOnly
    /// 分类下的某个学科，同样没有课程证据。
    case subjectOfCategory
    /// 原文里写了课程名（全名或去掉编制修饰的短名）。
    case courseNamedByUser
    /// 命中了记作业的习惯，比如「卷子」指向物理。
    case courseFromHabit
    /// 这个学科在目录里只有这一门课。
    case onlyCourseOfSubject
    /// 今天上过这门课。
    case courseFinishedToday

    /// 同一门课被多种证据推出来时，留最强的那条。
    var strength: Int {
        switch self {
        case .courseNamedByUser: 4
        case .courseFromHabit: 3
        case .onlyCourseOfSubject: 2
        case .courseFinishedToday: 1
        case .subjectOfCategory, .categoryOnly: 0
        }
    }

    var explanation: String {
        switch self {
        case .categoryOnly: "只归到分类"
        case .subjectOfCategory: "归到学科，没挂具体课程"
        case .courseNamedByUser: "原文里提到了这门课"
        case .courseFromHabit: "按你记这门课作业的习惯"
        case .onlyCourseOfSubject: "这个学科只有这一门课"
        case .courseFinishedToday: "今天上过这门课"
        }
    }
}

/// 把当前目录和课程证据缩成一小张候选表。纯函数：不发请求、不碰状态、不调模型。
enum RoutingCandidateBuilder {
    /// 「证据不足」这一项的 key。它是**显式选项**，不是缺省值——
    /// V1 的教训是模型宁可猜第一项也不肯留空，必须给它一个可选的「不确定」。
    static let unresolvedKey = "unresolved"

    /// 课程路线的上限。再多模型也分辨不出来，而且会稀释 prompt。
    static let maxCourseRoutes = 3

    static func build(
        interpretation: SemanticInterpretation,
        originalText: String,
        catalog: PromptCatalog,
        courses: [Course],
        courseContext: CourseContext
    ) -> [RoutingCandidate] {
        var rows: [(DeadlineCategory, DeadlineSubject?, Course?, RoutingEvidence)] = []

        for category in catalog.categories {
            rows.append((category, nil, nil, .categoryOnly))
        }

        let academicSubjects = catalog.academicSubjects
        for subject in academicSubjects {
            guard let category = catalog.categories.first(where: { $0.id == subject.categoryID }) else { continue }
            rows.append((category, subject, nil, .subjectOfCategory))
        }

        for (course, evidence) in courseRoutes(
            interpretation: interpretation,
            originalText: originalText,
            catalog: catalog,
            courses: courses,
            courseContext: courseContext
        ) {
            // 课程只能挂在它自己那个学科下，学科又只能挂在 academics 分类下。
            // 这两条都是后端硬约束，违反了写入时会吃 400，所以非法组合根本不进候选表。
            guard let subjectID = course.subjectID,
                  let subject = academicSubjects.first(where: { $0.id == subjectID }),
                  let category = catalog.categories.first(where: { $0.id == subject.categoryID }),
                  category.kind == "academics" else { continue }
            rows.append((category, subject, course, evidence))
        }

        var candidates = rows.enumerated().map { index, row in
            RoutingCandidate(key: "R\(index + 1)", category: row.0, subject: row.1,
                             course: row.2, evidence: row.3)
        }
        candidates.append(RoutingCandidate(
            key: unresolvedKey,
            category: catalog.categories.first ?? DeadlineCategory.all[0],
            subject: nil, course: nil, evidence: .categoryOnly
        ))
        return candidates
    }

    /// 按 key 取回真实对象。查不到就是查不到——**不回落到第一项**。
    /// V1 在这里猜过一次目录第一项，结果是所有分不清的输入都变成 Academics。
    static func candidate(forKey key: String, in candidates: [RoutingCandidate]) -> RoutingCandidate? {
        let needle = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        return candidates.first { $0.key.compare(needle, options: .caseInsensitive) == .orderedSame }
    }

    static func isUnresolved(_ candidate: RoutingCandidate) -> Bool {
        candidate.key == unresolvedKey
    }

    // MARK: - 课程证据

    /// 收集课程证据，同一门课只留最强的一条，最多 `maxCourseRoutes` 条。
    private static func courseRoutes(
        interpretation: SemanticInterpretation,
        originalText: String,
        catalog: PromptCatalog,
        courses: [Course],
        courseContext: CourseContext
    ) -> [(Course, RoutingEvidence)] {
        var found: [(Course, RoutingEvidence)] = []

        var namedByUser: Course?
        if case .direct(let candidate) = courseContext {
            namedByUser = candidate.course
            found.append((candidate.course, .courseNamedByUser))
        }

        // 论文类笔记不挂课程。
        //
        // 「论文」和「作文」只差一个字，模型分不开：把区别写进提示词之后「论文
        // Introduction 完成」修好了，「雅思作文」却整个掉进 Research（V1 实测 45→41）。
        // 所以这一层用字面判断放在代码里。它**只拦课程路线**，分类和学科路线照常给，
        // 不在客户端硬编码「Research」这个分类名。
        //
        // 原文点名了课程时不拦：「经济学的论文」是 AS经济 的课业，不是科研论文。
        let blocksCourses = namedByUser == nil && ResearchMarkers.matches(originalText)
        if blocksCourses { return found }

        if let habit = CourseHabit.matching(originalText) {
            let course = habit.courseNeedle.flatMap { needle in
                unique(courses.filter { $0.name.localizedCaseInsensitiveContains(needle) })
            } ?? onlyCourse(ofSubjectNamed: habit.subjectName, courses: courses, catalog: catalog)
            if let course { found.append((course, .courseFromHabit)) }
        }

        // 模型给的学科线索只是线索：拿去目录里查，查得到而且那个学科只有一门课才算证据。
        if let hint = interpretation.subjectHint,
           let subject = catalog.subject(named: hint),
           let only = unique(courses.filter { $0.subjectID == subject.id }) {
            found.append((only, .onlyCourseOfSubject))
        }

        if case .contextual(let todays) = courseContext {
            found.append(contentsOf: todays.map { ($0.course, .courseFinishedToday) })
        }

        // 去重时记住首次出现的次序：光按 strength 排会让同强度的两门课顺序随字典哈希漂移，
        // 同一句输入两次运行给出的候选表就不一样了，回归测试也就没法比。
        var strongest: [String: (course: Course, evidence: RoutingEvidence, order: Int)] = [:]
        for (order, entry) in found.enumerated() {
            let existing = strongest[entry.0.id]
            if existing == nil || entry.1.strength > existing!.evidence.strength {
                strongest[entry.0.id] = (entry.0, entry.1, existing?.order ?? order)
            }
        }
        return strongest.values
            .sorted {
                $0.evidence.strength != $1.evidence.strength
                    ? $0.evidence.strength > $1.evidence.strength
                    : $0.order < $1.order
            }
            .prefix(maxCourseRoutes)
            .map { ($0.course, $0.evidence) }
    }

    private static func unique(_ courses: [Course]) -> Course? {
        Set(courses.map(\.id)).count == 1 ? courses.first : nil
    }

    private static func onlyCourse(ofSubjectNamed name: String, courses: [Course], catalog: PromptCatalog) -> Course? {
        guard let subject = catalog.subject(named: name) else { return nil }
        return unique(courses.filter { $0.subjectID == subject.id })
    }
}
