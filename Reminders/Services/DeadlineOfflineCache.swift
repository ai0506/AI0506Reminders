import Foundation
import SwiftData

@Model
final class CachedDeadline {
    @Attribute(.unique) var id: String
    var title: String
    var detail: String
    var dueDate: Date
    var allDay: Bool
    var categoryID: String
    var categoryName: String
    var categoryColorHex: String
    var subjectData: Data?
    /// 可选字段，已装机的旧缓存靠它自动迁移（加 Subject 时就是这么过来的）。
    var courseID: String?
    var tagsData: Data
    var priorityRawValue: String
    var statusRawValue: String
    var updatedAt: Date

    init(deadline: Deadline) {
        id = deadline.id
        title = deadline.title
        detail = deadline.detail
        dueDate = deadline.dueDate
        allDay = deadline.allDay
        categoryID = deadline.category.id
        categoryName = deadline.category.name
        categoryColorHex = deadline.category.colorHex
        subjectData = try? JSONEncoder().encode(deadline.subject)
        courseID = deadline.courseID
        tagsData = (try? JSONEncoder().encode(deadline.tags)) ?? Data()
        priorityRawValue = deadline.priority.rawValue
        statusRawValue = deadline.status.rawValue
        updatedAt = deadline.updatedAt
    }

    var deadline: Deadline {
        Deadline(
            id: id,
            title: title,
            detail: detail,
            dueDate: dueDate,
            allDay: allDay,
            category: .init(id: categoryID, name: categoryName, colorHex: categoryColorHex),
            subject: subjectData.flatMap { try? JSONDecoder().decode(DeadlineSubject?.self, from: $0) } ?? nil,
            courseID: courseID,
            tags: (try? JSONDecoder().decode([DeadlineTag].self, from: tagsData)) ?? [],
            priority: DeadlinePriority(rawValue: priorityRawValue) ?? .default,
            status: DeadlineStatus(rawValue: statusRawValue) ?? .open,
            updatedAt: updatedAt
        )
    }
}

@MainActor
final class DeadlineOfflineCache {
    static let shared = DeadlineOfflineCache()

    /// 缓存里有没有东西。`load()` 在 `DeadlineStore.init` 里被调用，也就是在第一帧之前，
    /// 而建起 SwiftData 容器要几十毫秒（真机首次建库更久）。演示模式从不写缓存，
    /// 没连过 Calendar 的冷启动因此根本不需要这个容器——用这个标记记住上次的结果，
    /// 确定是空的就整个跳过，不再进启动关键路径。
    private static let hasRowsKey = "offline-cache-has-rows"

    private var loadedContainer: ModelContainer?

    private init() {}

    private var container: ModelContainer? {
        if let loadedContainer { return loadedContainer }
        let configuration = ModelConfiguration("DeadlineCache")
        loadedContainer = try? ModelContainer(for: CachedDeadline.self, configurations: configuration)
        return loadedContainer
    }

    func load() -> [Deadline] {
        let defaults = UserDefaults.standard
        // 只有明确记录过「上次缓存是空的」才跳过。没有记录说明是旧版本装上来的，
        // 照常打开容器——否则升级后第一次离线启动会把用户已有的缓存藏起来。
        if defaults.object(forKey: Self.hasRowsKey) != nil, !defaults.bool(forKey: Self.hasRowsKey) {
            return []
        }
        guard let context = container?.mainContext else { return [] }
        let descriptor = FetchDescriptor<CachedDeadline>(sortBy: [SortDescriptor(\CachedDeadline.dueDate)])
        let cached = (try? context.fetch(descriptor).map(\.deadline)) ?? []
        defaults.set(!cached.isEmpty, forKey: Self.hasRowsKey)
        return cached
    }

    func replace(with deadlines: [Deadline]) {
        guard let context = container?.mainContext else { return }
        let descriptor = FetchDescriptor<CachedDeadline>()
        guard let existing = try? context.fetch(descriptor) else { return }
        existing.forEach(context.delete)
        deadlines.forEach { context.insert(CachedDeadline(deadline: $0)) }
        try? context.save()
        UserDefaults.standard.set(!deadlines.isEmpty, forKey: Self.hasRowsKey)
    }
}
