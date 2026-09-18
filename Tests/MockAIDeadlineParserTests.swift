import Foundation
import Testing
@testable import AI0506_Reminders

struct MockAIDeadlineParserTests {
    private let categories = DeadlineCatalog.demo.categories
    private let tags = DeadlineCatalog.demo.tags
    private let subjects = DeadlineCatalog.demo.subjects

    @Test
    func parsesChineseDeadlineIntoEditableFields() throws {
        let now = try #require(date(year: 2026, month: 8, day: 17, hour: 9))
        let result = MockAIDeadlineParser.parse(
            input: "周五下午三点前交实验报告，放到 Research，标记 exam 和 urgent，优先级高。",
            categories: categories,
            tags: tags, subjects: subjects,
            now: now
        )

        #expect(result.draft.title == "交实验报告")
        #expect(result.draft.category.name == "Research")
        #expect(result.draft.tags.map(\.id) == ["exam", "urgent"])
        #expect(result.draft.priority == .high)
        #expect(!result.draft.allDay)
        #expect(Calendar.current.component(.weekday, from: result.draft.dueDate) == 6)
        #expect(Calendar.current.component(.hour, from: result.draft.dueDate) == 15)
    }

    @Test
    func parsesEnglishDeadlineIntoTimedDraft() throws {
        let now = try #require(date(year: 2026, month: 8, day: 17, hour: 9))
        let result = MockAIDeadlineParser.parse(
            input: "Finish research proposal tomorrow at 4pm, high priority, writing review",
            categories: categories,
            tags: tags, subjects: subjects,
            now: now
        )

        #expect(result.draft.title == "Finish research proposal")
        #expect(result.draft.category.name == "Research")
        #expect(result.draft.priority == .high)
        #expect(!result.draft.allDay)
        #expect(Calendar.current.component(.hour, from: result.draft.dueDate) == 16)
    }

    @Test
    func roundTripsDeadlineRoute() {
        let url = RemindersRoute.deadlineURL(id: "course/project 1")
        #expect(RemindersRoute.deadlineID(from: url) == "course/project 1")
    }

    @Test
    func widgetUsesThreeFutureDaysAndPrioritisesHighWithinADay() throws {
        let now = try #require(date(year: 2026, month: 9, day: 14, hour: 9))
        let calendar = Calendar(identifier: .gregorian)
        func deadline(_ id: String, day: Int, priority: DeadlinePriority) -> Deadline {
            let due = calendar.date(byAdding: .day, value: day, to: now)!
            return Deadline(id: id, title: id, detail: "", dueDate: due, allDay: true,
                            category: DeadlineCategory.all[0], subject: nil, tags: [],
                            priority: priority, status: .open, updatedAt: now)
        }
        let snapshot = SharedDeadlineCache.makeSnapshot(deadlines: [
            deadline("today-low", day: 0, priority: .low),
            deadline("today-high", day: 0, priority: .high),
            deadline("tomorrow", day: 1, priority: .default),
            deadline("day-three", day: 3, priority: .high),
            deadline("day-four", day: 4, priority: .high)
        ], now: now)

        #expect(snapshot.upcoming.map(\.id) == ["today-high", "tomorrow", "day-three"])
    }

    private func date(year: Int, month: Int, day: Int, hour: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))
    }
}
