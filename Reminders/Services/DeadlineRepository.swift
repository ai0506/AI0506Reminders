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

/// 演示工作区的数据来自 `Resources/sample-workspace.json`——那是 Calendar 与 Reminders
/// 共用的假数据，权威副本在 Calendar 仓库，用 `Scripts/sync-fixtures.sh` 同步过来。
///
/// 这样做的好处是：本地起一个真的 Calendar（`npm run db:seed-fake` + `npm run dev`）之后，
/// 演示工作区和真实后端看到的是同一批事项，来回切换时界面是连续的；
/// 分类名也不会再出现「文档写 Personal、库里其实叫 Leisure」那种两边各写一份导致的漂移。
enum DemoData {
    private struct Fixture: Decodable {
        struct Category: Decodable {
            let id: String, name: String, color: String, kind: String, archived: Int
        }
        struct Subject: Decodable {
            let id: String, name: String, categoryId: String, color: String, active: Int
        }
        struct Tag: Decodable { let id: String, name: String }
        struct Item: Decodable {
            let id: String, title: String, description: String
            let dueOffsetDays: Int
            let dueTime: String?
            let allDay: Bool
            let category: String
            let subjectId: String?
            let priority: DeadlinePriority
            let completed: Bool
            let tagIds: [String]
        }
        let categories: [Category]
        let subjects: [Subject]
        let tags: [Tag]
        let deadlines: [Item]
    }

    /// 后端按上海时间判定「今天」和「逾期」，假数据也必须照这个锚点展开，
    /// 否则演示工作区和本地 Calendar 会对不上一天。
    private static let shanghai = TimeZone(identifier: "Asia/Shanghai") ?? .current

    private static let fixture: Fixture? = {
        guard let url = Bundle.main.url(forResource: "sample-workspace", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(Fixture.self, from: data)
    }()

    /// 只暴露未归档的分类，跟 `GET /api/categories` 一致。
    static var categories: [DeadlineCategory] {
        guard let fixture else { return DeadlineCategory.all }
        return fixture.categories
            .filter { $0.archived == 0 }
            .map { .init(id: $0.id, name: $0.name, colorHex: $0.color, kind: $0.kind) }
    }

    /// 只暴露启用中的学科，跟 `GET /api/subjects` 一致。
    static var subjects: [DeadlineSubject] {
        guard let fixture else { return [] }
        return fixture.subjects
            .filter { $0.active == 1 }
            .map { .init(id: $0.id, name: $0.name, categoryID: $0.categoryId, colorHex: $0.color) }
    }

    static var tags: [DeadlineTag] {
        guard let fixture else { return [] }
        return fixture.tags.map { .init(id: $0.id, name: $0.name) }
    }

    static var deadlines: [Deadline] {
        guard let fixture else { return [] }
        let tagsByID = Dictionary(uniqueKeysWithValues: fixture.tags.map { ($0.id, DeadlineTag(id: $0.id, name: $0.name)) })
        // 按名字找分类时连归档的一起找：真实数据里就是存着归档分类的名字，
        // 演示工作区照样复现「它不在侧栏里、按分类筛不到」这个既有缺口。
        let categoriesByName = Dictionary(uniqueKeysWithValues: fixture.categories.map {
            ($0.name, DeadlineCategory(id: $0.id, name: $0.name, colorHex: $0.color, kind: $0.kind))
        })
        let subjectsByID = Dictionary(uniqueKeysWithValues: fixture.subjects.map {
            ($0.id, DeadlineSubject(id: $0.id, name: $0.name, categoryID: $0.categoryId, colorHex: $0.color))
        })
        let now = Date()

        return fixture.deadlines.compactMap { item in
            guard let category = categoriesByName[item.category],
                  let dueDate = dueDate(for: item, now: now) else { return nil }
            let status: DeadlineStatus = item.completed ? .completed : (dueDate < now ? .overdue : .open)
            return Deadline(
                id: item.id,
                title: item.title,
                detail: item.description,
                dueDate: dueDate,
                allDay: item.allDay,
                category: category,
                subject: item.subjectId.flatMap { subjectsByID[$0] },
                tags: item.tagIds.compactMap { tagsByID[$0] },
                priority: item.priority,
                status: status,
                updatedAt: now
            )
        }
    }

    private static func dueDate(for item: Fixture.Item, now: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai
        guard let day = calendar.date(byAdding: .day, value: item.dueOffsetDays, to: now) else { return nil }
        guard !item.allDay else { return calendar.startOfDay(for: day) }
        let parts = (item.dueTime ?? "09:00").split(separator: ":")
        let hour = Int(parts.first ?? "9") ?? 9
        let minute = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }
}
