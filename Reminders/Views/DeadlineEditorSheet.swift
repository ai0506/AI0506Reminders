import SwiftUI

struct DeadlineEditorSheet: View {
    let title: String
    let categories: [DeadlineCategory]
    let subjects: [DeadlineSubject]
    let availableTags: [DeadlineTag]
    let onSave: (DeadlineDraft) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var draft = DeadlineDraft()
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("要完成什么？", text: $draft.title, axis: .vertical)
                        .lineLimit(1...3)
                    TextField("备注", text: $draft.detail, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section("时间") {
                    DatePicker("截止日期", selection: $draft.dueDate, displayedComponents: .date)
                    Toggle("全天", isOn: $draft.allDay)
                    if !draft.allDay {
                        DatePicker("时间", selection: $draft.dueDate, displayedComponents: .hourAndMinute)
                    } else {
                        Color.clear.frame(height: 38)
                    }
                }

                Section("分类") {
                    Picker("分类", selection: $draft.category) {
                        ForEach(categories) { category in
                            Text(category.name).tag(category)
                        }
                    }
                    if draft.category.kind == "academics" {
                        Picker("学科", selection: $draft.subject) {
                            Text("未指定").tag(DeadlineSubject?.none)
                            ForEach(subjects.filter { $0.categoryID == draft.category.id }) { subject in
                                Text(subject.name).tag(DeadlineSubject?.some(subject))
                            }
                        }
                    }
                    Picker("优先级", selection: $draft.priority) {
                        ForEach(DeadlinePriority.allCases) { priority in
                            Text(priority.title).tag(priority)
                        }
                    }
                    TagPicker(tags: $draft.tags, availableTags: availableTags)
                }
            }
            .reminderCanvas()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "正在创建…" : "创建") {
                        Task {
                            isSaving = true
                            let saved = await onSave(draft)
                            isSaving = false
                            if saved { dismiss() }
                        }
                    }
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            if !categories.contains(draft.category), let first = categories.first { draft.category = first }
        }
        .onChange(of: draft.category) { _, category in
            if draft.subject?.categoryID != category.id { draft.subject = nil }
        }
    }
}

struct TagPicker: View {
    @Binding var tags: [DeadlineTag]
    let availableTags: [DeadlineTag]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("标签")
            FlowLayout(spacing: 8) {
                ForEach(availableTags) { tag in
                    Button(tag.name) {
                        if tags.contains(tag) { tags.removeAll { $0 == tag } }
                        else { tags.append(tag) }
                    }
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(tags.contains(tag) ? RemindersTheme.ink : RemindersTheme.pale, in: Capsule())
                    .foregroundStyle(tags.contains(tag) ? RemindersTheme.actionForeground : RemindersTheme.ink)
                    // Form otherwise treats every tag button in this row as one row-level action.
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

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
