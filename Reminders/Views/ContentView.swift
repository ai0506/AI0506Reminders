import SwiftUI

struct ContentView: View {
    @Bindable var store: DeadlineStore
    @Bindable var connection: CalendarConnectionStore
    @State private var showingCreate = false
    @State private var showingAI = false
    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store, onSettings: { showingSettings = true })
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 300)
        } content: {
            DeadlineListView(
                store: store,
                onCreate: { showingCreate = true },
                onAI: { showingAI = true }
            )
                .navigationSplitViewColumnWidth(min: 360, ideal: 460, max: 560)
        } detail: {
            DeadlineDetailView(store: store)
                .navigationSplitViewColumnWidth(min: 380, ideal: 480, max: 620)
        }
        .tint(RemindersTheme.accent)
        .background(RemindersTheme.paper)
        .sheet(isPresented: $showingCreate) {
            DeadlineEditorSheet(title: "新建截止事项", categories: store.categories, subjects: store.subjects, availableTags: store.availableTags, tagSuggestions: store.tagSuggestions) { draft in
                let created = await store.create(draft)
                if created { showingCreate = false }
                return created
            }
        }
        .sheet(isPresented: $showingAI) {
            AIComposerSheet(store: store, categories: store.categories, subjects: store.subjects, availableTags: store.availableTags) { draft in
                let created = await store.create(draft)
                if created { showingAI = false }
                return created
            }
        }
        .sheet(isPresented: $showingSettings) {
            AppSettingsSheet(store: store, connection: connection)
        }
        .alert("无法更新截止事项", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

private struct SidebarView: View {
    @Bindable var store: DeadlineStore
    let onSettings: () -> Void

    var body: some View {
        List(selection: $store.selectedFilter) {
            Section {
                filterRow(.today, icon: "sun.max")
                filterRow(.upcoming, icon: "calendar")
                filterRow(.overdue, icon: "exclamationmark.circle")
                filterRow(.all, icon: "tray.full")
            }

            Section("分类") {
                ForEach(store.categories) { category in
                    Label {
                        Text(category.name)
                    } icon: {
                        Circle().fill(category.tint).frame(width: 10, height: 10)
                    }
                    .tag(DeadlineFilter.category(category.id))
                }
            }

            if !store.subjects.isEmpty {
                Section("学科") {
                    ForEach(store.subjects) { subject in
                        Label(subject.name, systemImage: "book.closed")
                            .tag(DeadlineFilter.subject(subject.id))
                    }
                }
            }

            if !store.availableTags.isEmpty {
            Section("标签") {
                    ForEach(store.availableTags) { tag in
                        Label(tag.name, systemImage: "tag")
                            .tag(DeadlineFilter.tag(tag.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .reminderCanvas()
        .navigationTitle("提醒事项")
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Circle().fill(RemindersTheme.success).frame(width: 7, height: 7)
                Text(store.isDemoMode ? "演示工作区" : "已连接 Calendar")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("提醒事项设置")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    @ViewBuilder
    private func filterRow(_ filter: DeadlineFilter, icon: String) -> some View {
        Label(filter.title, systemImage: icon)
            .tag(filter)
    }
}

/// 冷启动时演示 / 缓存数据大约 100ms 就到位了，这段时间直接放 `ProgressView`
/// 会闪一个转圈再跳成内容，读起来比什么都不显示还慢。超过 250ms 仍在加载才显示，
/// 真的慢（比如首屏就在等真实 API）时反馈照常出现。
private struct DelayedProgressView: View {
    @State private var isVisible = false

    var body: some View {
        Group {
            if isVisible { ProgressView() } else { Color.clear }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: .milliseconds(250))
            isVisible = true
        }
    }
}

private struct DeadlineListView: View {
    @Bindable var store: DeadlineStore
    let onCreate: () -> Void
    let onAI: () -> Void

    var body: some View {
        Group {
            if store.isLoading && store.deadlines.isEmpty {
                DelayedProgressView()
            } else if store.groups.isEmpty {
                ContentUnavailableView(
                    "这里没有截止事项",
                    systemImage: "checkmark.circle",
                    description: Text("没有符合当前视图的截止事项。")
                )
            } else {
                List(selection: $store.selectedDeadlineID) {
                    ForEach(store.groups) { group in
                        Section(group.title) {
                            ForEach(group.deadlines) { deadline in
                                DeadlineRow(deadline: deadline)
                                    .tag(deadline.id)
                                    .listRowBackground(RemindersTheme.card)
                                    .contentShape(Rectangle())
                                    .contextMenu {
                                        Button(deadline.isCompleted ? "重新打开" : "完成") {
                                            Task { await store.toggleCompletion(deadline) }
                                        }
                                    }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .reminderCanvas()
                .refreshable { await store.refresh() }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.selectedFilterTitle())
                        .font(.title2.weight(.semibold))
                    Text(store.syncNote ?? " ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .opacity(store.syncNote == nil ? 0 : 1)
                }
                Spacer()
                Button(action: onAI) {
                    Image(systemName: "sparkles")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .background(RemindersTheme.pale, in: Circle())
                .accessibilityLabel("用 AI 创建截止事项")
                Button(action: onCreate) {
                    Image(systemName: "plus")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RemindersTheme.actionForeground)
                .background(RemindersTheme.ink, in: Circle())
                .accessibilityLabel("新建截止事项")
            }
            .padding(.horizontal, 22)
            .frame(height: 62)
            .background(.background.opacity(0.96))
        }
    }
}

struct DeadlineRow: View {
    let deadline: Deadline

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(deadline.category.tint)
                .frame(width: 9, height: 9)
                .opacity(deadline.isCompleted ? 0.35 : 1)

            VStack(alignment: .leading, spacing: 5) {
                Text(deadline.title)
                    .font(.body.weight(.medium))
                    .strikethrough(deadline.isCompleted, color: .secondary)
                    .foregroundStyle(deadline.isCompleted ? RemindersTheme.muted : RemindersTheme.ink)
                    .lineLimit(1)
                HStack(spacing: 7) {
                    Text(dueText)
                    if deadline.priority == .high {
                        Text("高优先级")
                            .foregroundStyle(RemindersTheme.danger)
                    }
                    if !deadline.tags.isEmpty {
                        Text(deadline.tags.map(\.name).joined(separator: " · "))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if deadline.isOverdue && !deadline.isCompleted {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(RemindersTheme.danger)
                    .imageScale(.small)
            }
        }
        .padding(.vertical, 5)
    }

    private var dueText: String {
        if deadline.allDay { return deadline.dueDate.formatted(.dateTime.month(.abbreviated).day()) }
        if Calendar.current.isDateInToday(deadline.dueDate) { return deadline.dueDate.formatted(.dateTime.hour().minute()) }
        return deadline.dueDate.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

private struct DeadlineDetailView: View {
    @Bindable var store: DeadlineStore

    var body: some View {
        Group {
            if let deadline = store.selectedDeadline {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(alignment: .top) {
                            statusMark(deadline)
                            Spacer()
                            Button(deadline.isCompleted ? "重新打开" : "完成") {
                                Task { await store.toggleCompletion(deadline) }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(deadline.isCompleted ? .secondary : RemindersTheme.ink)
                            .foregroundStyle(deadline.isCompleted ? .white : RemindersTheme.actionForeground)
                        }

                        Text(deadline.title)
                            .font(.system(size: 31, weight: .semibold, design: .rounded))
                            .strikethrough(deadline.isCompleted)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 16) {
                            DetailLine(icon: "calendar", title: "截止", value: dueText(deadline))
                            DetailLine(icon: "circle.fill", title: "分类", value: deadline.category.name, tint: deadline.category.tint)
                            if let subject = deadline.subject { DetailLine(icon: "book.closed", title: "学科", value: subject.name, tint: subject.tint) }
                            DetailLine(icon: "flag", title: "优先级", value: deadline.priority.title)
                            if !deadline.tags.isEmpty {
                                DetailLine(icon: "tag", title: "标签", value: deadline.tags.map(\.name).joined(separator: "、"))
                            }
                        }
                        .padding(18)
                        .paperCard()

                        if !deadline.detail.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("备注")
                                    .font(.headline)
                                Text(deadline.detail)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(18)
                            .paperCard()
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 560, alignment: .leading)
                }
                .background(RemindersTheme.paper.opacity(0.45))
                .navigationTitle("截止事项")
            } else {
                ContentUnavailableView("选择一个截止事项", systemImage: "checkmark.circle", description: Text("详细信息会显示在这里。"))
            }
        }
    }

    private func statusMark(_ deadline: Deadline) -> some View {
        HStack(spacing: 7) {
            Circle().fill(deadline.isCompleted ? RemindersTheme.success : deadline.isOverdue ? RemindersTheme.danger : deadline.category.tint).frame(width: 8, height: 8)
            Text(deadline.isCompleted ? "已完成" : deadline.isOverdue ? "已逾期" : "进行中")
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
    }

    private func dueText(_ deadline: Deadline) -> String {
        if deadline.allDay { return deadline.dueDate.formatted(.dateTime.weekday(.wide).month(.wide).day()) + " · 全天" }
        return deadline.dueDate.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute())
    }
}

private struct DetailLine: View {
    let icon: String
    let title: String
    let value: String
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(tint ?? RemindersTheme.muted)
            Text(title).foregroundStyle(RemindersTheme.muted)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).foregroundStyle(RemindersTheme.ink)
        }
        .font(.subheadline)
    }
}
