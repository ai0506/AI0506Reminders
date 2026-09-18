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
        // 演示数据是按上海时区的「今天」摆的，断言也得用同一把尺子；
        // 用 Calendar.current 的话，换个地区跑就会有一条测试无缘无故变红。
        let calendar = Calendar.shanghai
        #expect(deadlines.contains { calendar.isDateInToday($0.dueDate) })
        #expect(deadlines.contains { $0.isCompleted })
        #expect(deadlines.contains { $0.isOverdue && !$0.isCompleted })
        #expect(deadlines.contains { $0.allDay })
        #expect(deadlines.contains { $0.priority == .high })
        #expect(deadlines.contains { $0.subject != nil })
        #expect(deadlines.allSatisfy { $0.tags.count <= DeadlineTag.maxPerDeadline })
    }

    /// 标签推荐也跟着 fixture 走，键必须是真实存在的分类 id 或科目 id、值必须是真实标签。
    /// 键写错不会报错，只会让推荐悄悄消失，所以要有东西盯着。
    @Test
    func tagSuggestionsReferenceRealCatalogEntries() {
        let suggestions = DemoData.tagSuggestions
        #expect(!suggestions.isEmpty, "fixture 应当带标签推荐，否则演示模式验不到这个功能")

        let ownerIDs = Set(DemoData.categories.map(\.id) + DemoData.subjects.map(\.id))
        let tagIDs = Set(DemoData.tags.map(\.id))
        for (owner, tags) in suggestions {
            #expect(ownerIDs.contains(owner), "\(owner) 既不是分类 id 也不是科目 id")
            #expect(tags.allSatisfy { tagIDs.contains($0) }, "\(owner) 推荐了目录外的标签")
        }
    }
}

/// 推荐标签的归属规则：Academics 选了科目按科目找，其余一律按分类找。
/// 这条规则和 Calendar 网页共用一套语义，写错了只是推荐列表变空，界面不会报错。
struct TagSuggestionOwnerTests {
    private let academics = DeadlineCategory(id: "cat-academics", name: "Academics", colorHex: "#655f58", kind: "academics")
    private let research = DeadlineCategory(id: "cat-research", name: "Research", colorHex: "#7f5fb5")
    private let math = DeadlineSubject(id: "sub-math", name: "Math", categoryID: "cat-academics", colorHex: "#ff3b30")
    private let table = ["cat-academics": ["tag-exam"], "cat-research": ["tag-writing"], "sub-math": ["tag-review", "tag-exam"]]

    @Test
    func academicsWithASubjectUsesTheSubjectListInOrder() {
        #expect(TagSuggestions.ids(in: table, category: academics, subject: math) == ["tag-review", "tag-exam"])
    }

    @Test
    func academicsWithoutASubjectFallsBackToTheCategoryList() {
        #expect(TagSuggestions.ids(in: table, category: academics, subject: nil) == ["tag-exam"])
    }

    /// 普通分类即便带着一个残留的学科（切分类的瞬间可能出现），也只看分类。
    @Test
    func aNonAcademicsCategoryAlwaysUsesTheCategoryList() {
        #expect(TagSuggestions.ids(in: table, category: research, subject: math) == ["tag-writing"])
    }

    @Test
    func anUnknownOwnerYieldsNoSuggestions() {
        let unknown = DeadlineCategory(id: "cat-nope", name: "Nope", colorHex: "#000000")
        #expect(TagSuggestions.ids(in: table, category: unknown, subject: nil).isEmpty)
    }
}

/// 标签上限是后端硬约束，客户端必须自己拦。界面上超出上限的按钮会被禁用，
/// 这里守的是底层：任何调用路径都攒不出第 6 个标签。
struct TagSelectionLimitTests {
    private let catalog = (1...7).map { DeadlineTag(id: "tag-\($0)", name: "tag \($0)") }

    @Test
    func selectionStopsAtTheBackendLimit() {
        var tags: [DeadlineTag] = []
        for tag in catalog { tags.toggle(tag) }
        #expect(tags.count == DeadlineTag.maxPerDeadline)
        #expect(tags.map(\.id) == ["tag-1", "tag-2", "tag-3", "tag-4", "tag-5"])
    }

    /// 满了以后仍然要能取消，否则用户换不了标签，只能清空重来。
    @Test
    func deselectingAlwaysWorksEvenAtTheLimit() {
        var tags = Array(catalog.prefix(DeadlineTag.maxPerDeadline))
        tags.toggle(catalog[0])
        #expect(tags.count == DeadlineTag.maxPerDeadline - 1)
        tags.toggle(catalog[6])
        #expect(tags.map(\.id).contains("tag-7"))
        #expect(tags.count == DeadlineTag.maxPerDeadline)
    }
}
