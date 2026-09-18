import Foundation
import Testing
@testable import AI0506_Reminders

/// `Resources/sample-workspace.json` 是 Calendar 与 Reminders 共用的假数据，
/// 权威副本在 Calendar 仓库，靠 `Scripts/sync-fixtures.sh` 同步。
///
/// 这些用例守两件事：资源真的被打进了 App bundle（解码失败时 `DemoData` 会静默返回空数组，
/// 编译和运行都不会报错），以及硬编码的 `DeadlineCategory.all` 没有和 fixture 漂移。
struct SharedFixtureTests {
    @Test
    func fixtureIsBundledAndDecodes() {
        // 空数组就说明 JSON 没进 bundle 或解码失败——正是那种不报错的失败。
        #expect(!DemoData.categories.isEmpty)
        #expect(!DemoData.subjects.isEmpty)
        #expect(!DemoData.tags.isEmpty)
        #expect(!DemoData.deadlines.isEmpty)
    }

    /// `DeadlineCategory.all` 是 Widget target 的兜底目录，读不到 fixture 时也会用它。
    /// 它和 fixture 各写一份，所以必须有东西盯着两边一致。
    @Test
    func hardcodedFallbackMatchesTheFixtureCatalog() {
        let fromFixture = DemoData.categories
        let hardcoded = DeadlineCategory.all

        #expect(hardcoded.count == fromFixture.count)
        for category in fromFixture {
            let match = hardcoded.first { $0.id == category.id }
            #expect(match != nil, "兜底目录缺少 \(category.id)")
            #expect(match?.name == category.name)
            #expect(match?.colorHex.lowercased() == category.colorHex.lowercased())
            #expect(match?.kind == category.kind)
        }
    }

    @Test
    func categoriesAndSubjectsMirrorTheBackendVisibility() {
        // 归档分类不该出现在目录里，跟 GET /api/categories 一致。
        #expect(!DemoData.categories.contains { $0.name == "Physics" })
        // Academics 是唯一的 academics 分类，学科都挂在它下面。
        let academics = DemoData.categories.first { $0.kind == "academics" }
        #expect(academics?.name == "Academics")
        #expect(DemoData.subjects.allSatisfy { $0.categoryID == academics?.id })
    }

    /// fixture 里特意留了一条挂在已归档分类下的事项，用来复现 `Frontend_spec.md` §22
    /// 记的缺口：它的分类不在目录里，所以按分类筛选永远看不到它。
    /// 哪天这个缺口被修掉，这条会红，提醒把规格和 fixture 的说明一起改。
    @Test
    func theArchivedCategoryDeadlineIsStillUnreachableByFilter() {
        let orphan = DemoData.deadlines.first { $0.category.name == "Physics" }
        #expect(orphan != nil, "fixture 里应当保留一条归档分类的事项")
        #expect(!DemoData.categories.contains { $0.id == orphan?.category.id })
    }

    /// 演示工作区要覆盖到各种状态，否则界面上有些分支永远看不到。
    @Test
    func demoDataCoversEveryStatusTheUICanShow() {
        let deadlines = DemoData.deadlines
        let calendar = Calendar.current
        #expect(deadlines.contains { calendar.isDateInToday($0.dueDate) })
        #expect(deadlines.contains { $0.isCompleted })
        #expect(deadlines.contains { $0.isOverdue && !$0.isCompleted })
        #expect(deadlines.contains { $0.allDay })
        #expect(deadlines.contains { $0.priority == .high })
        #expect(deadlines.contains { $0.subject != nil })
        #expect(deadlines.allSatisfy { $0.tags.count <= 5 })
    }
}
