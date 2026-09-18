import SwiftUI

struct AIComposerSheet: View {
    @Bindable var store: DeadlineStore
    let categories: [DeadlineCategory]
    let subjects: [DeadlineSubject]
    let availableTags: [DeadlineTag]
    let onCreate: (DeadlineDraft) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 输入原文、等待解析、确认草稿是三件不同的事，各占一屏。
    /// 用一个枚举承载，保证任何时候只有一步在屏幕上。
    private enum Phase { case input, parsing, draft }

    @State private var phase: Phase = .input
    @State private var prompt = ""
    @State private var result: AIParseResult?
    @State private var isCreating = false
    @State private var parseTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .input: inputStep
                case .parsing: parsingStep
                case .draft: draftStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(RemindersTheme.paper)
            .navigationTitle(stepTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        parseTask?.cancel()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var stepTitle: String {
        switch phase {
        case .input: "AI 创建"
        case .parsing: "正在分析"
        case .draft: "确认草稿"
        }
    }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 第一步：写下要做的事

    private var inputStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("用自然语言描述要做的事。下一步会生成一个可调整的截止事项草稿，再由你确认创建。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(minHeight: 168)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(RemindersTheme.pale, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityLabel("要分析的原文")

                HStack(spacing: 7) {
                    Image(systemName: "wand.and.stars")
                    Text("本地演示解析 · 不会发送 AI 请求")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                Button("分析这段话") { startParsing() }
                    .buttonStyle(.borderedProminent)
                    .tint(RemindersTheme.accent)
                    .foregroundStyle(RemindersTheme.actionForeground)
                    .disabled(trimmedPrompt.isEmpty)
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
        }
    }

    // MARK: - 第二步：解析进行中

    private var parsingStep: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)

            ParsingIndicator(reduceMotion: reduceMotion)

            VStack(spacing: 8) {
                // 动画不是唯一的状态来源：文字始终说明现在在做什么。
                Text("正在分析这段话…")
                    .font(.headline)
                Text("本地演示解析 · 不会发送 AI 请求")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text(trimmedPrompt)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 32)

            Button("取消") {
                parseTask?.cancel()
                parseTask = nil
                phase = .input
            }
            .buttonStyle(.plain)
            .font(.subheadline)
            .foregroundStyle(RemindersTheme.accent)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 680)
        .padding(24)
    }

    // MARK: - 第三步：检查并修改草稿

    private var draftStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let result {
                    originalTextCard(result.originalText)

                    AIDraftEditor(
                        result: Binding(get: { result }, set: { self.result = $0 }),
                        categories: categories,
                        subjects: subjects,
                        availableTags: availableTags
                    )

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
                }
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
        }
    }

    /// 草稿是对原文的解读，所以原文要留在同一屏上供核对；
    /// 「修改原文」退回第一步，输入框里的文字原样保留。
    private func originalTextCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("原文")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("修改原文") { phase = .input }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                    .disabled(isCreating)
            }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(RemindersTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    private func startParsing() {
        let text = trimmedPrompt
        guard !text.isEmpty else { return }
        phase = .parsing
        parseTask?.cancel()
        parseTask = Task {
            let startedAt = Date()
            let parsed = await store.parseMockAI(text)
            // 本地解析只要半秒左右，动画一闪而过反而像故障。给这一步一个
            // 最短停留时间，让「正在分析」读得出来；真实 AI 接入后本来就更慢，
            // 这段等待会自然消失。
            let minimumDwell: TimeInterval = 0.9
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed < minimumDwell {
                try? await Task.sleep(for: .seconds(minimumDwell - elapsed))
            }
            guard !Task.isCancelled else { return }
            result = parsed
            phase = .draft
            parseTask = nil
        }
    }
}

/// 安静的三点呼吸指示器。位移和缩放一概不用，只改透明度，
/// 开启「减少动态效果」时退化为静态圆点。
private struct ParsingIndicator: View {
    let reduceMotion: Bool
    @State private var animating = false

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(RemindersTheme.accent)
                    .frame(width: 10, height: 10)
                    .opacity(reduceMotion ? 0.55 : (animating ? 1 : 0.2))
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.66)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.18),
                        value: animating
                    )
            }
        }
        .frame(height: 24)
        .onAppear { animating = true }
        .accessibilityHidden(true)
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
