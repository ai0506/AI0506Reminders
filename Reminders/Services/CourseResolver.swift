import Foundation

/// 从一条笔记推断它属于哪门课。
///
/// **模型不参与这个判断。** 实测让模型在课程候选里选有两个问题：一是候选会锚定它的
/// 分类判断（给了课程列表之后，「修一下那个崩溃」和「上学带乒乓球拍」都被拉进 Academics）；
/// 二是课程本来就能确定性地推出来——Physics、CS、Math 在目录里各只有一门课，English
/// 那几门靠写法区分。模型只判断学科，课程由这里推。
enum CourseResolver {
    /// 这门课是怎么定下来的。草稿页要把依据显示给用户，让他知道凭什么挂到这门课上。
    enum Basis: Equatable {
        /// 原文里写了课程名（全名或去掉编制修饰后的短名）。
        case namedByUser
        /// 命中了记作业的习惯，比如「卷子」指向物理。
        case writingHabit
        /// 这个学科在目录里只有这一门课。
        case onlySubjectCourse
        /// 今天上过这门课。
        case finishedToday

        /// 给草稿页显示的依据。用户得看得出凭什么挂到这门课上，才好决定要不要改。
        var explanation: String {
            switch self {
            case .namedByUser: "原文里提到了这门课"
            case .writingHabit: "按你记这门课作业的习惯"
            case .onlySubjectCourse: "这个学科只有这一门课"
            case .finishedToday: "今天上过这门课"
            }
        }
    }

    struct Resolution: Equatable {
        var course: Course?
        /// 习惯规则可以推翻模型给的学科——「卷子」就是物理，不管模型怎么想。
        var subjectName: String?
        var basis: Basis?

        static let unresolved = Resolution(course: nil, subjectName: nil, basis: nil)
    }

    static func resolve(
        input: String,
        named: Course?,
        modelSubjectName: String?,
        catalog: [Course],
        candidates: [CourseCandidate],
        subjects: [DeadlineSubject]
    ) -> Resolution {
        // 1) 用户自己写了课程名，没有比这更强的信号。
        if let named {
            return Resolution(course: named,
                              subjectName: subjectName(of: named, in: subjects),
                              basis: .namedByUser)
        }

        // 2) 记作业的习惯。它连学科一起定，因为这些写法本身就指向某一科。
        if let habit = CourseHabit.matching(input) {
            let course = habit.courseNeedle.flatMap { needle in
                unique(catalog.filter { $0.name.localizedCaseInsensitiveContains(needle) })
            } ?? onlyCourse(ofSubjectNamed: habit.subjectName, catalog: catalog, subjects: subjects)
            if course != nil {
                return Resolution(course: course, subjectName: habit.subjectName, basis: .writingHabit)
            }
            // 课程没找到也要保住学科：目录里没有物理课，不代表「卷子」不是物理的。
            return Resolution(course: nil, subjectName: habit.subjectName, basis: nil)
        }

        guard let modelSubjectName, !modelSubjectName.isEmpty else { return .unresolved }

        // 3) 学科定了、而且这个学科只有一门课，那就是它。
        if let only = onlyCourse(ofSubjectNamed: modelSubjectName, catalog: catalog, subjects: subjects) {
            return Resolution(course: only, subjectName: modelSubjectName, basis: .onlySubjectCourse)
        }

        // 4) 同一学科有多门课时，取今天上过的那门。候选已经按「还没记过作业的排前面」
        //    排好序，所以直接取第一个命中的即可。
        if let subjectID = subjects.first(where: { $0.name.compare(modelSubjectName, options: .caseInsensitive) == .orderedSame })?.id,
           let today = candidates.first(where: { $0.course.subjectID == subjectID }) {
            return Resolution(course: today.course, subjectName: modelSubjectName, basis: .finishedToday)
        }

        return Resolution(course: nil, subjectName: modelSubjectName, basis: nil)
    }

    // MARK: - 组件

    private static func unique(_ courses: [Course]) -> Course? {
        Set(courses.map(\.id)).count == 1 ? courses.first : nil
    }

    private static func onlyCourse(ofSubjectNamed name: String, catalog: [Course], subjects: [DeadlineSubject]) -> Course? {
        guard let subjectID = subjects.first(where: {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        })?.id else { return nil }
        return unique(catalog.filter { $0.subjectID == subjectID })
    }

    private static func subjectName(of course: Course, in subjects: [DeadlineSubject]) -> String? {
        guard let id = course.subjectID else { return nil }
        return subjects.first { $0.id == id }?.name
    }
}
