import SwiftUI

struct DeadlineEditorSheet: View {
    let title: String
    let categories: [DeadlineCategory]
    let subjects: [DeadlineSubject]
    let availableTags: [DeadlineTag]
    /// 标签推荐表（分类 id / 科目 id -> 标签 id），来自 `DeadlineStore`。
    let tagSuggestions: [String: [String]]
    let onSave: (DeadlineDraft) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var draft = DeadlineDraft()
    @State private var isSaving = false

    private var suggestedTagIDs: [String] {
        TagSuggestions.ids(in: tagSuggestions, category: draft.category, subject: draft.subject)
    }

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

                Section("分类与标签") {
                    CategoryPicker(categories: categories, selection: $draft.category)
                    if draft.category.kind == "academics" {
                        SubjectPicker(
                            subjects: subjects.filter { $0.categoryID == draft.category.id },
                            selection: $draft.subject
                        )
                    }
                    // 优先级只有三档、互斥且顺序固定，分段控件一次点击就到位；
                    // 这是系统原生控件，不属于 §9.3 的例外。
                    VStack(alignment: .leading, spacing: 8) {
                        FieldCaption(text: "优先级")
                        Picker("优先级", selection: $draft.priority) {
                            ForEach(DeadlinePriority.allCases) { priority in
                                Text(priority.title).tag(priority)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    TagPicker(tags: $draft.tags, availableTags: availableTags, suggestedIDs: suggestedTagIDs)
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
