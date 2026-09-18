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
    @State private var revealTask: Task<Void, Never>?
    @State private var isParsing = false

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
                        cancelParsing()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        // 用户打字的这几秒正好用来加载模型，别等他点「分析这段话」才开始。
        .task { store.prewarmAI() }
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

    /// 这行字是隐私承诺，必须说实话：接上设备端模型之后「不会发送 AI 请求」
    /// 已经不成立了，但推理仍在这台 iPad 上完成，内容不离开设备——
    /// 对用户来说后者才是真正关心的那件事。
    private var privacyNote: String {
        store.isOnDeviceModelAvailable
            ? "设备端 Apple 智能 · 内容不离开这台 iPad"
            : "本地规则解析 · 内容不离开这台 iPad"
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
                    Text(privacyNote)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                Button(isParsing ? "正在分析…" : "分析这段话") { startParsing() }
                    .buttonStyle(.borderedProminent)
                    .tint(RemindersTheme.accent)
                    .foregroundStyle(RemindersTheme.actionForeground)
                    .disabled(isParsing || trimmedPrompt.isEmpty)
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
                Text(privacyNote)
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
                cancelParsing()
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
                    if let note = store.aiNote {
                        // 回退发生时要说出来：草稿的质量确实不一样，
                        // 不说的话用户会以为设备端模型就是这个水平。
                        Label(note, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    originalTextCard(result.originalText)

                    // `get` 必须读 `self.result`，**不能捕获 `if let` 解包出来的快照**。
                    //
                    // 捕获快照的话，同一个事件里连着改几个字段就会互相覆盖：SwiftUI 在
                    // 一次事件内不重算 body，于是每次 `get()` 都返回同一份旧值，第二次
                    // 写回会把第一次的修改带回来。「清除课程」要清 courseID / courseName /
                    // courseBasis 三个字段，实机上的表现就是点 X 完全没反应。
                    AIDraftEditor(
                        result: Binding(get: { self.result ?? result }, set: { self.result = $0 }),
                        categories: categories,
                        subjects: subjects,
                        availableTags: availableTags,
                        tagSuggestions: store.tagSuggestions
                    )
                }
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
        }
        // 草稿字段比一屏长，主操作跟着内容滚就会掉到折叠线以下：横屏下要先滚到底
        // 才看得见「创建截止事项」，看起来像这一步没有出口。固定在底部常驻。
        .safeAreaInset(edge: .bottom) { createBar }
    }

    @ViewBuilder
    private var createBar: some View {
        if let result {
            VStack(spacing: 0) {
                Divider()
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
                .frame(maxWidth: 680)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            }
            .background(.bar)
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
        cancelParsing()
        isParsing = true
        // 「正在分析」这一屏只在解析真的慢到会被察觉时才出现。本地演示解析是纯计算、
        // 瞬间返回，先切过去再切回来，用户看到的不是进度，而是一次多余的转场加一段
        // 人为等待——这一步原本还有 0.45 秒的最短停留，正是那段等待让「AI 创建」
        // 显得卡住。输入屏在这段窗口里靠按钮文案「正在分析…」表示已经接收（§7.1）。
        // 真实 AI 的请求本来就超过这个阈值，这一屏会自然回来，三步结构不变。
        revealTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            phase = .parsing
        }
        parseTask = Task {
            let parsed = await store.parseAI(text)
            revealTask?.cancel()
            revealTask = nil
            guard !Task.isCancelled else { return }
            isParsing = false
            result = parsed
            phase = .draft
            parseTask = nil
        }
    }

    /// 取消解析：两个 task 必须一起停。只停 `parseTask` 的话，那个还在睡的
    /// `revealTask` 会在 180ms 后把界面推进「正在分析」，而解析早就被放弃了。
    private func cancelParsing() {
        revealTask?.cancel()
        revealTask = nil
        parseTask?.cancel()
        parseTask = nil
        isParsing = false
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
                            : .easeInOut(duration: 0.42)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.12),
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
    let tagSuggestions: [String: [String]]

    private var suggestedTagIDs: [String] {
        TagSuggestions.ids(in: tagSuggestions, category: result.draft.category, subject: result.draft.subject)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 这里曾经有一行「解析置信度 90%」。去掉了：那个数字是模型自评的，
            // 实测基本只在 0.9 / 0.7 之间跳，既说不出哪一格可能错，也不随证据变化。
            // 要给用户的是「凭什么这么填、该检查哪一项」，不是一个百分比。
            HStack {
                Text("草稿")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .frame(height: 28)

            VStack(spacing: 0) {
                DraftField(title: "标题") {
                    TextField("标题", text: $result.draft.title).multilineTextAlignment(.trailing)
                }
                Divider()
                draftRow {
                    CategoryPicker(categories: categories, selection: $result.draft.category)
                }
                Divider()
                if result.draft.category.kind == "academics" {
                    draftRow {
                        SubjectPicker(
                            subjects: subjects.filter { $0.categoryID == result.draft.category.id },
                            selection: $result.draft.subject
                        )
                    }
                    Divider()
                    // 课程是**只读归属**，不是第四个导航维度（Frontend_spec §18.4）：
                    // 这里只说明这条作业被挂到了哪门课、凭什么挂的，用户能清除但不能
                    // 在这里翻整本课程目录——course_id 只能来自 Calendar 的课程目录。
                    if let name = result.courseName {
                        DraftField(title: "课程") {
                            HStack(spacing: 8) {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(name)
                                    if let basis = result.courseBasis {
                                        Text(basis)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Button { clearCourse() } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("清除关联课程")
                            }
                        }
                        Divider()
                    }
                }
                DraftField(title: "截止") {
                    DatePicker("截止", selection: $result.draft.dueDate, displayedComponents: result.draft.allDay ? .date : [.date, .hourAndMinute])
                        .labelsHidden()
                }
                Divider()
                // 「全天」必须紧挨着「截止」：它其实是那一行的开关——关掉之后
                // 上面才会出现时间选择器。之前它放在卡片外面、标签选择器上方，
                // 实机反馈是「草稿填不了具体截止时间」，用户根本没把两者联系起来。
                DraftField(title: "全天") {
                    Toggle("全天", isOn: $result.draft.allDay)
                        .labelsHidden()
                }
                Divider()
                DraftField(title: "优先级") {
                    Picker("优先级", selection: $result.draft.priority) {
                        ForEach(DeadlinePriority.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }
            .padding(.horizontal, 16)
            .paperCard()

            TagPicker(tags: $result.draft.tags, availableTags: availableTags, suggestedIDs: suggestedTagIDs)
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
            // 后端要求 course_id 只能挂在 Academics 且与 subject_id 一致，
            // 换到别的分类后课程必须跟着走，否则提交时才吃 400。
            if category.kind != "academics" { clearCourse() }
        }
        .onChange(of: result.draft.subject) { _, _ in
            // 换了学科，原来那门课多半就对不上了。这里不猜新课程，交还给用户。
            clearCourse()
        }
    }
}

private extension AIDraftEditor {
    /// 分类 / 学科的胶囊要横向铺开，塞不进 `DraftField` 那个 290pt 的右对齐槽，
    /// 所以这两行整行给选择器用（标题由选择器自己的 `FieldCaption` 给），
    /// 其余字段仍是 `DraftField` 的「左标题 + 右值」。
    @ViewBuilder
    func draftRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }

    /// 三个字段**一次写回**，不要连写三次。
    ///
    /// 逐个写的话每次都是一轮 get/set，而 SwiftUI 在同一个事件里不重算 body，
    /// 上游 binding 的 `get` 只要有一点滞后就会把前一次的清除覆盖掉。
    /// 合成一次写入，这条路就不依赖上游 binding 的实现细节了。
    ///
    /// 也不再用 `courseID != nil` 做前置判断：课程行是按 `courseName` 显示的，
    /// 万一两者不同步，那个 guard 会让按钮彻底失效——而用户看得见的是那一行还在。
    func clearCourse() {
        guard result.draft.courseID != nil || result.courseName != nil else { return }
        var updated = result
        updated.draft.courseID = nil
        updated.courseName = nil
        updated.courseBasis = nil
        result = updated
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
