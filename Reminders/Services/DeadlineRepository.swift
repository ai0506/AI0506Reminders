import Foundation

@MainActor
protocol DeadlineRepository {
    func fetchDeadlines() async throws -> [Deadline]
    func fetchCatalog() async throws -> DeadlineCatalog
    func create(_ draft: DeadlineDraft) async throws -> Deadline
    func setCompletion(_ deadline: Deadline, completed: Bool) async throws -> Deadline
}

struct DeadlineCatalog {
    var categories: [DeadlineCategory]
    var tags: [DeadlineTag]
    var subjects: [DeadlineSubject]

    static let demo = DeadlineCatalog(categories: DeadlineCategory.all, tags: DemoData.tags, subjects: DemoData.subjects)
}

enum RepositoryError: LocalizedError {
    case unavailable

    var errorDescription: String? { "Calendar service is currently unavailable." }
}

struct MockDeadlineRepository: DeadlineRepository {
    // 演示仓库不再人造延迟：这些等待只是让界面显得慢，没有任何信息量。
    func fetchDeadlines() async throws -> [Deadline] {
        DemoData.deadlines
    }

    func fetchCatalog() async throws -> DeadlineCatalog {
        DeadlineCatalog.demo
    }

    func create(_ draft: DeadlineDraft) async throws -> Deadline {
        Deadline(
            id: UUID().uuidString,
            title: draft.title,
            detail: draft.detail,
            dueDate: draft.dueDate,
            allDay: draft.allDay,
            category: draft.category, subject: draft.subject,
            tags: draft.tags,
            priority: draft.priority,
            status: .open,
            updatedAt: Date()
        )
    }

    func setCompletion(_ deadline: Deadline, completed: Bool) async throws -> Deadline {
        var updated = deadline
        updated.status = completed ? .completed : (updated.dueDate < Date() ? .overdue : .open)
        updated.updatedAt = Date()
        return updated
    }
}

enum DemoData {
    // 标签与学科同样是后端目录里的名字，保持英文原名与 Calendar 的科目色板一致。
    static let tags: [DeadlineTag] = [
        .init(id: "exam", name: "exam"), .init(id: "urgent", name: "urgent"),
        .init(id: "writing", name: "writing"), .init(id: "review", name: "review")
    ]
    static let subjects: [DeadlineSubject] = [
        .init(id: "sub-math", name: "Math", categoryID: "academics", colorHex: "#FF3B30"),
        .init(id: "sub-physics", name: "Physics", categoryID: "academics", colorHex: "#32ADE6"),
        .init(id: "sub-cs", name: "CS", categoryID: "academics", colorHex: "#30B855")
    ]

    static let deadlines: [Deadline] = {
        let calendar = Calendar.current
        let now = Date()
        func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(byAdding: .day, value: day, to: calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now)!)!
        }
        return [
            .init(id: "proposal", title: "提交研究计划书", detail: "包含修改后的方法部分与一页时间线。", dueDate: date(0, 16), allDay: false, category: .all[1], subject: nil, tags: [tags[2], tags[3]], priority: .high, status: .open, updatedAt: now),
            .init(id: "algorithms", title: "复习算法题集", detail: "明天课程前检查第 4 道证明题。", dueDate: date(1, 10), allDay: false, category: .all[0], subject: subjects[2], tags: [tags[3]], priority: .default, status: .open, updatedAt: now),
            .init(id: "seminar", title: "准备研讨课笔记", detail: "", dueDate: date(2, 9), allDay: true, category: .all[1], subject: nil, tags: [], priority: .low, status: .open, updatedAt: now),
            .init(id: "physics", title: "完成光学复习", detail: "", dueDate: date(4, 18), allDay: false, category: .all[0], subject: subjects[1], tags: [tags[0]], priority: .default, status: .open, updatedAt: now),
            .init(id: "overdue", title: "发送项目反馈", detail: "", dueDate: date(-1, 17), allDay: false, category: .all[2], subject: nil, tags: [tags[1]], priority: .high, status: .overdue, updatedAt: now),
            .init(id: "completed", title: "阅读实验简介", detail: "", dueDate: date(-2, 12), allDay: false, category: .all[1], subject: nil, tags: [], priority: .default, status: .completed, updatedAt: now)
        ]
    }()
}
