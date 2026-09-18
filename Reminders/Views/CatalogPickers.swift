import SwiftUI

/// 目录类字段（分类 / 学科 / 标签）的选择器。
///
/// 这三个字段以前都是系统 `Picker`：先点一次展开菜单、再点一次选值，两次点击加一次
/// 转场才换掉一个值，而候选项一共只有五六个，完全放得下。改成一排常驻的胶囊按钮后
/// 一次点击就完成，且当前值和其它候选同时可见——这和 Calendar 网页的分类色块、
/// 标签 chip 是同一套交互，三个客户端的手感对得上。
///
/// 色块不能只有颜色：`Frontend_spec.md` §3.3 要求分类必须「色点 **且** 名称」，
/// 所以这里是「色点 + 名字」的胶囊，而不是 Calendar 网页那种纯色圆点（网页靠
/// hover tooltip 补名字，触摸屏上没有 hover）。

// MARK: - 胶囊

/// 所有目录胶囊的唯一实现。选中态刻意不使用 `RemindersTheme.accent`：
/// 分类色和学科色是**数据颜色**（§3.2），用它们自己的颜色描边 + 淡填充，
/// 既能表达「选中」，又不会把数据色当成主题色。
private struct CatalogChip: View {
    let title: String
    /// 数据颜色；标签没有颜色，传 nil 就不画色点、选中态改用主题 accent。
    let tint: Color?
    let isSelected: Bool
    var accessibilityHint: String?
    let action: () -> Void

    private var fill: Color { tint ?? RemindersTheme.accent }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let tint {
                    Circle()
                        .fill(tint)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(RemindersTheme.ink.opacity(0.12), lineWidth: 0.5))
                }
                Text(title)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(RemindersTheme.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(isSelected ? fill.opacity(0.22) : RemindersTheme.pale, in: Capsule())
            .overlay {
                Capsule().strokeBorder(isSelected ? fill : .clear, lineWidth: 2)
            }
            .contentShape(Capsule())
        }
        // `Form` 行里的多个自定义按钮不显式指定 borderless 会被合并成一个行级操作，
        // 点任意一个会触发全部（TagPicker 踩过一次）。
        .buttonStyle(.borderless)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint(accessibilityHint ?? "")
    }
}

// MARK: - 字段小标题

/// 字段小标题。胶囊铺开之后一个 Section 里会连着出现分类、学科、优先级三排样子相近的
/// 按钮，没有标题就分不清哪排是什么。
struct FieldCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(RemindersTheme.muted)
    }
}

// MARK: - 分类与学科

struct CategoryPicker: View {
    let categories: [DeadlineCategory]
    @Binding var selection: DeadlineCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldCaption(text: "分类")
            FlowLayout(spacing: 8) {
                ForEach(categories) { category in
                    CatalogChip(title: category.name, tint: category.tint, isSelected: category == selection) {
                        selection = category
                    }
                }
            }
        }
    }
}

struct SubjectPicker: View {
    let subjects: [DeadlineSubject]
    @Binding var selection: DeadlineSubject?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldCaption(text: "学科")
            FlowLayout(spacing: 8) {
                // 「未指定」是合法值：Academics 下也可以没有学科，后端的 subject_id 允许为空。
                CatalogChip(title: "未指定", tint: nil, isSelected: selection == nil) { selection = nil }
                ForEach(subjects) { subject in
                    CatalogChip(title: subject.name, tint: subject.tint, isSelected: subject == selection) {
                        selection = subject
                    }
                }
            }
        }
    }
}

// MARK: - 标签

struct TagPicker: View {
    @Binding var tags: [DeadlineTag]
    let availableTags: [DeadlineTag]
    /// 当前分类 / 学科推荐的标签 id，**按推荐顺序**，来自后端
    /// `GET /api/category-tag-suggestions`。为空时退化成「全部标签按目录顺序排」。
    var suggestedIDs: [String] = []

    /// 折叠阈值：非推荐标签超过这个数就先收起来。真实目录有二十多个标签，
    /// 全铺开会把备注和主操作挤到屏幕外。
    private static let collapsedLimit = 8

    @State private var isExpanded = false

    private var selectedIDs: Set<String> { Set(tags.map(\.id)) }
    private var isAtLimit: Bool { tags.count >= DeadlineTag.maxPerDeadline }

    /// 推荐组保持后端给的顺序（最可能的排前面），目录里没有的 id 直接丢掉；
    /// 其余标签按目录顺序排在「全部标签」里。
    private var suggested: [DeadlineTag] {
        let byID = Dictionary(uniqueKeysWithValues: availableTags.map { ($0.id, $0) })
        return suggestedIDs.compactMap { byID[$0] }
    }

    private var others: [DeadlineTag] {
        let suggestedSet = Set(suggestedIDs)
        return availableTags.filter { !suggestedSet.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("标签")
                Spacer()
                // 上限必须在点得动之前就说清楚，不能等提交才由后端返回 400（§8.1）。
                Text(isAtLimit
                     ? "已选 \(tags.count)/\(DeadlineTag.maxPerDeadline) · 已达上限"
                     : "已选 \(tags.count)/\(DeadlineTag.maxPerDeadline)")
                    .font(.footnote)
                    .foregroundStyle(isAtLimit ? RemindersTheme.accent : RemindersTheme.muted)
            }

            if availableTags.isEmpty {
                Text("目录里还没有标签")
                    .font(.footnote)
                    .foregroundStyle(RemindersTheme.muted)
            } else {
                // 推荐用一个小标题分组，而不是只给推荐的 chip 换个描边色：
                // 颜色不得是状态的唯一载体（§3.3），分组标题同时也给读屏用户讲清楚了。
                if !suggested.isEmpty {
                    FieldCaption(text: "推荐")
                    chips(suggested)
                    FieldCaption(text: "全部标签")
                }
                chips(isExpanded || others.count <= Self.collapsedLimit
                      ? others
                      : Array(others.prefix(Self.collapsedLimit)))
                if others.count > Self.collapsedLimit {
                    Button(isExpanded ? "收起" : "显示全部（\(others.count)）") { isExpanded.toggle() }
                        .font(.footnote)
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private func chips(_ list: [DeadlineTag]) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(list) { tag in
                let isSelected = selectedIDs.contains(tag.id)
                CatalogChip(
                    title: tag.name,
                    tint: nil,
                    isSelected: isSelected,
                    accessibilityHint: isSelected || !isAtLimit ? nil : "已选满 \(DeadlineTag.maxPerDeadline) 个标签"
                ) {
                    tags.toggle(tag)
                }
                // 达到上限后其余标签必须禁用，而不是点了没反应。
                .disabled(!isSelected && isAtLimit)
                .opacity(!isSelected && isAtLimit ? 0.4 : 1)
            }
        }
    }

}

// MARK: - 布局

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var height: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth + size.width > width, rowWidth > 0 {
                height += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + (rowWidth == 0 ? 0 : spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? rowWidth, height: height + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var point = bounds.origin
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if point.x + size.width > bounds.maxX, point.x > bounds.minX {
                point.x = bounds.minX
                point.y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: point, proposal: ProposedViewSize(size))
            point.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
