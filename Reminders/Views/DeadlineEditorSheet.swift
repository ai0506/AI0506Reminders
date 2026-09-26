import SwiftUI

struct DeadlineEditorSheet: View {
    let title: String
    let categories: [DeadlineCategory]
    let subjects: [DeadlineSubject]
    let availableTags: [DeadlineTag]
    /// 标签推荐表（分类 id / 科目 id -> 标签 id），来自 `DeadlineStore`。
    let tagSuggestions: [String: [String]]
    /// 成功返回 nil，失败返回要给用户看的错误说明。
    let onSave: (DeadlineDraft) async -> String?
    /// 由父视图关掉这个 sheet。确认框还在屏幕上时，sheet 自己的 `dismiss()` 只会关掉
    /// 最上层的确认框（模拟器实测：点「放弃」表单纹丝不动）；从父视图撤掉 sheet，
    /// 会把 sheet 连同上面的确认框一起收走。
    let onDiscard: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = DeadlineDraft()
    @State private var isSaving = false
    /// 打开时的草稿，用来判断用户有没有动过。默认截止时间取的是「打开那一刻」，
    /// 所以只能和快照比，不能和 `DeadlineDraft()` 比。
    @State private var baseline: DeadlineDraft?
    @State private var confirmingDiscard = false
    @State private var saveError: String?

    private var hasChanges: Bool {
        guard let baseline else { return false }
        return draft != baseline
    }

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
                    Button("取消") {
                        if hasChanges { confirmingDiscard = true } else { dismiss() }
                    }
                    .disabled(isSaving)
                    .confirmationDialog("放弃这个截止事项？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                        Button("放弃", role: .destructive) { onDiscard() }
                        Button("继续编辑", role: .cancel) {}
                    } message: {
                        Text("填写的内容不会保存。")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "正在创建…" : "创建") {
                        Task {
                            isSaving = true
                            let failure = await onSave(draft)
                            isSaving = false
                            if let failure { saveError = failure } else { dismiss() }
                        }
                    }
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
        }
        .presentationDetents([.large])
        // iPad 上的 sheet 点外面、往下拖都会直接关掉。动过内容就只能走「取消」，
        // 由它来问一句，不然手一滑填的东西就没了。
        .interactiveDismissDisabled(hasChanges || isSaving)
        .alert("无法创建截止事项", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("好", role: .cancel) { saveError = nil }
        } message: {
            Text((saveError ?? "") + "\n填写的内容还在，可以直接重试。")
        }
        .onAppear {
            if !categories.contains(draft.category), let first = categories.first { draft.category = first }
            if baseline == nil { baseline = draft }
        }
        .onChange(of: draft.category) { _, category in
            if draft.subject?.categoryID != category.id { draft.subject = nil }
        }
    }
}
