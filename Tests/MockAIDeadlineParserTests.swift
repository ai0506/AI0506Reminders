import Foundation
import Testing
@testable import AI0506_Reminders

struct MockAIDeadlineParserTests {
    private let shanghai = Calendar.shanghai
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
        #expect(result.draft.tags.map(\.name) == ["exam", "urgent"])
        #expect(result.draft.priority == .high)
        #expect(!result.draft.allDay)
        #expect(shanghai.component(.weekday, from: result.draft.dueDate) == 6)
        #expect(shanghai.component(.hour, from: result.draft.dueDate) == 15)
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
        #expect(shanghai.component(.hour, from: result.draft.dueDate) == 16)
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
        shanghai.date(from: DateComponents(year: year, month: month, day: day, hour: hour))
    }
}

/// 回归：真实 API 创建出来的 Deadline 必须跟刷新走同一条目录回填路径。
///
/// `CalendarAPIRepository` 的 DTO 没有可用的分类 id——它硬编码成 `"uncatalogued"`，
/// subject 也只带 id、名字是空的。真正的值靠 `DeadlineStore.applyCatalog` 按分类名回填。
/// `create()` 曾经直接把 API 返回值插进数组，于是刚建好的那条立刻从分类筛选里消失、
/// 学科名是空的，要等下一次 refresh 才恢复。
@MainActor
struct DeadlineStoreCatalogBackfillTests {
    /// `fetchDeadlines` 故意返回空：被创建的那条必须是列表里唯一的来源，
    /// 否则刷新回填过的副本会替 `create()` 把断言糊弄过去。
    ///
    /// 初始化时 `DeadlineStore` 会自己起一趟 refresh，它可能在测试中途落地。
    /// 每个用例都把断言紧接在 `await store.create(...)` 之后、中间不再 await——
    /// MainActor 上没有挂起点，那趟 refresh 就插不进来。
    private struct APIShapedRepository: DeadlineRepository {
        let catalog: DeadlineCatalog
        let created: Deadline

        func fetchDeadlines() async throws -> [Deadline] { [] }
        func fetchCatalog() async throws -> DeadlineCatalog { catalog }
        func create(_ draft: DeadlineDraft) async throws -> Deadline { created }
        func setCompletion(_ deadline: Deadline, completed: Bool) async throws -> Deadline { created }
    }

    private static let academics = DeadlineCategory(id: "academics", name: "Academics", colorHex: "#655F58", kind: "academics")
    private static let research = DeadlineCategory(id: "research", name: "Research", colorHex: "#7F5FB5")
    private static let physics = DeadlineSubject(id: "sub-physics", name: "Physics", categoryID: "academics", colorHex: "#32ADE6")

    private func makeStore() -> DeadlineStore {
        // DTO 给的就是这两样：占位的分类 id + 只有 id 没有名字的学科。
        let fromAPI = Deadline(
            id: "created-from-api",
            title: "Submit optics revision",
            detail: "",
            dueDate: Date().addingTimeInterval(3_600),
            allDay: false,
            category: DeadlineCategory(id: "uncatalogued", name: "Research", colorHex: "#999A9F"),
            subject: DeadlineSubject(id: "sub-physics", name: "", categoryID: "", colorHex: "#999A9F"),
            tags: [],
            priority: .default,
            status: .open,
            updatedAt: Date()
        )
        return DeadlineStore(repository: APIShapedRepository(
            catalog: DeadlineCatalog(categories: [Self.academics, Self.research], tags: [], subjects: [Self.physics]),
            created: fromAPI
        ))
    }

    @Test
    func createResolvesThePlaceholderCategoryID() async throws {
        let store = makeStore()
        await store.refresh()

        let created = await store.create(DeadlineDraft())
        #expect(created)
        #expect(store.deadlines.count == 1)
        #expect(store.deadlines.first?.category.id == "research")
        #expect(store.deadlines.first?.category.colorHex == "#7F5FB5")
    }

    @Test
    func createResolvesTheSubjectName() async throws {
        let store = makeStore()
        await store.refresh()

        let created = await store.create(DeadlineDraft())
        #expect(created)
        #expect(store.deadlines.first?.subject?.name == "Physics")
    }

    /// 这条是用户真正会看到的症状：回填没做的话，新建的 Deadline 在分类筛选里看不见。
    @Test
    func createdDeadlineIsVisibleUnderItsCategoryFilter() async throws {
        let store = makeStore()
        await store.refresh()

        let created = await store.create(DeadlineDraft())
        #expect(created)
        store.selectedFilter = .category("research")
        #expect(store.visibleDeadlines.contains { $0.id == "created-from-api" })
    }
}
