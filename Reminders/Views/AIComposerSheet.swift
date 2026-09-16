import SwiftUI

struct AIComposerSheet: View {
    @Bindable var store: DeadlineStore
    let categories: [DeadlineCategory]
    let subjects: [DeadlineSubject]
    let availableTags: [DeadlineTag]
    let onCreate: (DeadlineDraft) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var result: AIParseResult?
    @State private var isParsing = false
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("用自然语言描述要做的事。我会生成一个可调整的截止事项草稿，再由你确认创建。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 12) {
                        TextEditor(text: $prompt)
                            .font(.body)
                            .frame(minHeight: 124)
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .background(RemindersTheme.pale, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        Button(isParsing ? "正在分析…" : "分析这段话") {
                            Task {
                                isParsing = true
                                result = await store.parseMockAI(prompt)
                                isParsing = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(RemindersTheme.accent)
                        .foregroundStyle(RemindersTheme.actionForeground)
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isParsing)
                    }

                    if let result {
                        Divider().padding(.vertical, 3)
                        AIDraftEditor(result: Binding(
                            get: { result },
                            set: { self.result = $0 }
                        ), categories: categories, subjects: subjects, availableTags: availableTags)
                        Button(isCreating ? "正在创建…" : "创建截止事项") {
                            Task {
                                isCreating = true
                                let created = await onCreate(result.draft)
                                isCreating = false
                                if created { dismiss() }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(RemindersTheme.accent)
                        .foregroundStyle(RemindersTheme.actionForeground)
                        .disabled(isCreating || result.draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        HStack(spacing: 7) {
                            Image(systemName: "wand.and.stars")
                            Text("本地演示解析 · 不会发送 AI 请求")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: 680, alignment: .leading)
            }
            .navigationTitle("AI 创建")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

private struct AIDraftEditor: View {
    @Binding var result: AIParseResult
    let categories: [DeadlineCategory]
    let subjects: [DeadlineSubject]
    let availableTags: [DeadlineTag]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("草稿")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("解析置信度 \(Int(result.confidence * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 28)

            VStack(spacing: 0) {
                DraftField(title: "标题") {
                    TextField("标题", text: $result.draft.title).multilineTextAlignment(.trailing)
                }
                Divider()
                DraftField(title: "分类") {
                    Picker("分类", selection: $result.draft.category) {
                        ForEach(categories) { Text($0.name).tag($0) }
                    }.labelsHidden()
                }
                Divider()
                if result.draft.category.kind == "academics" {
                    DraftField(title: "学科") {
                        Picker("学科", selection: $result.draft.subject) {
                            Text("未指定").tag(DeadlineSubject?.none)
                            ForEach(subjects.filter { $0.categoryID == result.draft.category.id }) { subject in Text(subject.name).tag(DeadlineSubject?.some(subject)) }
                        }.labelsHidden()
                    }
                    Divider()
                }
                DraftField(title: "截止") {
                    DatePicker("截止", selection: $result.draft.dueDate, displayedComponents: result.draft.allDay ? .date : [.date, .hourAndMinute])
                        .labelsHidden()
                }
                Divider()
                DraftField(title: "优先级") {
                    Picker("优先级", selection: $result.draft.priority) {
                        ForEach(DeadlinePriority.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden()
                }
            }
            .padding(.horizontal, 16)
            .paperCard()

            Toggle("全天", isOn: $result.draft.allDay)
                .font(.subheadline)
                .padding(.horizontal, 4)

            TagPicker(tags: $result.draft.tags, availableTags: availableTags)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 7) {
                Text("备注").font(.subheadline.weight(.medium))
                TextEditor(text: $result.draft.detail)
                    .frame(minHeight: 76)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RemindersTheme.pale, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .onChange(of: result.draft.category) { _, category in
            if result.draft.subject?.categoryID != category.id { result.draft.subject = nil }
        }
    }
}

private struct DraftField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            content
                .frame(maxWidth: 290, alignment: .trailing)
        }
        .font(.subheadline)
        .frame(minHeight: 52)
    }
}
