import Foundation
import WidgetKit

struct WidgetDeadlineSnapshot: Codable {
    let updatedAt: Date
    let upcoming: [WidgetDeadlineItem]
}

struct WidgetDeadlineItem: Codable {
    let id: String
    let title: String
    let dueDate: Date
    let allDay: Bool
    let category: String
    let colorHex: String
    let priority: DeadlinePriority
}

enum SharedDeadlineCache {
    static let appGroupID = "group.com.ai0506.reminders"
    private static let key = "widget-deadline-snapshot-v2"

    static func save(deadlines: [Deadline]) {
        let snapshot = makeSnapshot(deadlines: deadlines)
        let defaults = UserDefaults(suiteName: appGroupID) ?? .standard
        defaults.set(try? JSONEncoder().encode(snapshot), forKey: key)
        WidgetCenter.shared.reloadTimelines(ofKind: "DeadlineWidget")
    }

    static func makeSnapshot(deadlines: [Deadline], now: Date = .now) -> WidgetDeadlineSnapshot {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let candidates = deadlines
            .filter { $0.status == .open && calendar.startOfDay(for: $0.dueDate) >= today }
            .sorted(by: widgetOrder)
        // One representative per upcoming calendar day makes the medium
        // widget genuinely show day 1 / day 2 / day 3. A high-priority item
        // wins whenever multiple deadlines share one date.
        let upcoming = Dictionary(grouping: candidates, by: { calendar.startOfDay(for: $0.dueDate) })
            .keys.sorted()
            .prefix(3)
            .compactMap { day in
                candidates.first { calendar.isDate($0.dueDate, inSameDayAs: day) }
            }
            .map {
                WidgetDeadlineItem(
                id: $0.id,
                title: $0.title,
                dueDate: $0.dueDate,
                allDay: $0.allDay,
                category: $0.category.name,
                colorHex: $0.category.colorHex,
                priority: $0.priority
                )
            }
        return WidgetDeadlineSnapshot(updatedAt: now, upcoming: Array(upcoming))
    }

    static func load() -> WidgetDeadlineSnapshot? {
        let defaults = UserDefaults(suiteName: appGroupID) ?? .standard
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetDeadlineSnapshot.self, from: data)
    }

    private static func widgetOrder(_ lhs: Deadline, _ rhs: Deadline) -> Bool {
        let calendar = Calendar.current
        let lhsDay = calendar.startOfDay(for: lhs.dueDate)
        let rhsDay = calendar.startOfDay(for: rhs.dueDate)
        if lhsDay != rhsDay { return lhsDay < rhsDay }
        let priority: [DeadlinePriority: Int] = [.high: 0, .default: 1, .low: 2]
        if priority[lhs.priority] != priority[rhs.priority] {
            return priority[lhs.priority, default: 1] < priority[rhs.priority, default: 1]
        }
        return lhs.dueDate < rhs.dueDate
    }
}
