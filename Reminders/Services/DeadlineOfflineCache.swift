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

    private let container: ModelContainer?

    private init() {
        let configuration = ModelConfiguration("DeadlineCache")
        container = try? ModelContainer(for: CachedDeadline.self, configurations: configuration)
    }

    func load() -> [Deadline] {
        guard let context = container?.mainContext else { return [] }
        let descriptor = FetchDescriptor<CachedDeadline>(sortBy: [SortDescriptor(\CachedDeadline.dueDate)])
        return (try? context.fetch(descriptor).map(\.deadline)) ?? []
    }

    func replace(with deadlines: [Deadline]) {
        guard let context = container?.mainContext else { return }
        let descriptor = FetchDescriptor<CachedDeadline>()
        guard let existing = try? context.fetch(descriptor) else { return }
        existing.forEach(context.delete)
        deadlines.forEach { context.insert(CachedDeadline(deadline: $0)) }
        try? context.save()
    }
}
