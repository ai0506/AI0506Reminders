import SwiftUI
import WidgetKit

struct DeadlineWidgetEntry: TimelineEntry {
    let date: Date
    let upcoming: [WidgetDeadlineItem]
}

struct DeadlineWidgetProvider: TimelineProvider {
    // 画廊里的占位和预览可以用示例数据，真实的 timeline 不行。
    func placeholder(in context: Context) -> DeadlineWidgetEntry { sample }
    func getSnapshot(in context: Context, completion: @escaping (DeadlineWidgetEntry) -> Void) {
        completion(context.isPreview ? sample : entry())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<DeadlineWidgetEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .after(.now.addingTimeInterval(30 * 60))))
    }

    /// 读不到快照就显示空态。绝不能回落到示例数据——那会让主屏上出现
    /// 用户从来没建过的"提交研究计划书"，看起来像真的。
    private func entry() -> DeadlineWidgetEntry {
        guard let snapshot = SharedDeadlineCache.load() else {
            return .init(date: .now, upcoming: [])
        }
        return .init(date: snapshot.updatedAt, upcoming: snapshot.upcoming)
    }

    private var sample: DeadlineWidgetEntry {
        .init(date: .now, upcoming: [
            .init(id: "demo-1", title: "提交研究计划书", dueDate: .now, allDay: false, category: "Research", colorHex: "#7F5FB5", priority: .high),
            .init(id: "demo-2", title: "完成光学复习", dueDate: .now.addingTimeInterval(86_400), allDay: true, category: "Academics", colorHex: "#655F58", priority: .default),
            .init(id: "demo-3", title: "整理研讨课笔记", dueDate: .now.addingTimeInterval(172_800), allDay: true, category: "Research", colorHex: "#7F5FB5", priority: .low)
        ])
    }
}

struct DeadlineWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DeadlineWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("未来截止事项").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if !entry.upcoming.isEmpty {
                    // 表头写实际条数，不写死"最近 3 项"——小尺寸只显示一条时那是假的。
                    Text("\(entry.upcoming.count) 项").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if entry.upcoming.isEmpty {
                ContentUnavailableView("未来暂无截止事项", systemImage: "checkmark.circle")
            } else if family == .systemSmall, let first = entry.upcoming.first {
                DeadlineWidgetRow(item: first, compact: false)
                if entry.upcoming.count > 1 {
                    Text("另有 \(entry.upcoming.count - 1) 项即将到期").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                // 中号是多行的，每行必须各自可点。整块共用一个 widgetURL 的话，
                // 点第二、三行也只会跳到第一条。
                ForEach(entry.upcoming, id: \.id) { item in
                    Link(destination: RemindersRoute.deadlineURL(id: item.id)) {
                        DeadlineWidgetRow(item: item, compact: true)
                    }
                }
            }
        }
        .containerBackground(for: .widget) { RemindersTheme.paper }
        // 小尺寸整块只有一个点击目标，只有它用 widgetURL。
        .widgetURL(family == .systemSmall ? entry.upcoming.first.map { RemindersRoute.deadlineURL(id: $0.id) } : nil)
    }
}

private struct DeadlineWidgetRow: View {
    let item: WidgetDeadlineItem
    let compact: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: item.colorHex)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(dayText).font(compact ? .caption.weight(.medium) : .headline).foregroundStyle(RemindersTheme.ink)
                Text(item.title).font(compact ? .caption2 : .caption).lineLimit(compact ? 1 : 2).foregroundStyle(RemindersTheme.muted)
            }
            Spacer(minLength: 0)
            if item.priority == .high {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(RemindersTheme.danger).imageScale(.small)
            }
        }
    }

    private var dayText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(item.dueDate) { return item.allDay ? "今天 · 全天" : "今天 · \(item.dueDate.formatted(.dateTime.hour().minute()))" }
        if calendar.isDateInTomorrow(item.dueDate) { return item.allDay ? "明天 · 全天" : "明天 · \(item.dueDate.formatted(.dateTime.hour().minute()))" }
        return item.allDay ? item.dueDate.formatted(.dateTime.month().day()) + " · 全天" : item.dueDate.formatted(.dateTime.month().day().hour().minute())
    }
}

struct DeadlineWidget: Widget {
    let kind = "DeadlineWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DeadlineWidgetProvider()) { DeadlineWidgetView(entry: $0) }
            .configurationDisplayName("未来截止事项")
            .description("仅显示最近的未来截止事项，并优先展示高优先级事项。")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct DeadlineWidgets: WidgetBundle { var body: some Widget { DeadlineWidget() } }
