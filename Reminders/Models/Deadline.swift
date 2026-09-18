import Foundation
import SwiftUI

enum DeadlinePriority: String, Codable, CaseIterable, Identifiable {
    case high
    case `default`
    case low

    var id: String { rawValue }
    var title: String {
        switch self {
        case .high: "高"
        case .default: "普通"
        case .low: "低"
        }
    }
}

enum DeadlineStatus: String, Codable {
    case open
    case overdue
    case completed
}

struct DeadlineTag: Identifiable, Codable, Hashable {
    let id: String
    var name: String
}

struct DeadlineCategory: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var colorHex: String
    var kind: String = "normal"

    /// 分类名与配色照抄 Calendar 后端的真实目录（见 `Calendar/production/FRONTEND_SPEC.md` §6）。
    /// 分类是后端数据，不在 iPad 侧翻译——翻译会让同一条 Deadline 在 iPad 和 Web 上显示不同名字。
    static let all: [DeadlineCategory] = [
        .init(id: "academics", name: "Academics", colorHex: "#655F58", kind: "academics"),
        .init(id: "research", name: "Research", colorHex: "#7F5FB5"),
        .init(id: "projects", name: "AI0506 Project", colorHex: "#C07043"),
        .init(id: "leisure", name: "Personal", colorHex: "#BD5F86"),
        .init(id: "tech", name: "Tech", colorHex: "#64748B")
    ]

    var tint: Color { Color(hex: colorHex) }
}

struct DeadlineSubject: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var categoryID: String
    var colorHex: String

    var tint: Color { Color(hex: colorHex) }
}

struct Deadline: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var detail: String
    var dueDate: Date
    var allDay: Bool
    var category: DeadlineCategory
    var subject: DeadlineSubject?
    var subjectID: String? { subject?.id }
    var tags: [DeadlineTag]
    var priority: DeadlinePriority
    var status: DeadlineStatus
    var updatedAt: Date

    var isCompleted: Bool { status == .completed }
    var isOverdue: Bool { status == .overdue || (!isCompleted && dueDate < Date()) }
}

struct DeadlineDraft: Hashable {
    var title = ""
    var detail = ""
    var dueDate = Date().addingTimeInterval(86_400)
    var allDay = false
    var category = DeadlineCategory.all[0]
    var subject: DeadlineSubject?
    var tags: [DeadlineTag] = []
    var priority: DeadlinePriority = .default
}

struct AIParseResult: Hashable {
    var originalText: String
    var draft: DeadlineDraft
    var confidence: Double
}

enum DeadlineFilter: Hashable, Identifiable {
    case today
    case upcoming
    case overdue
    case all
    case category(String)
    case tag(String)
    case subject(String)

    var id: String {
        switch self {
        case .today: "today"
        case .upcoming: "upcoming"
        case .overdue: "overdue"
        case .all: "all"
        case .category(let id): "category-\(id)"
        case .tag(let id): "tag-\(id)"
        case .subject(let id): "subject-\(id)"
        }
    }

    var title: String {
        switch self {
        case .today: "今天"
        case .upcoming: "即将到期"
        case .overdue: "已逾期"
        case .all: "全部截止事项"
        case .category(let id): DeadlineCategory.all.first(where: { $0.id == id })?.name ?? id
        case .tag: "标签"
        case .subject: "学科"
        }
    }
}

struct DeadlineGroup: Identifiable {
    let date: Date
    let title: String
    let deadlines: [Deadline]
    var id: Date { date }
}

extension Color {
    init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var number: UInt64 = 0
        Scanner(string: value).scanHexInt64(&number)
        self.init(
            .sRGB,
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255,
            opacity: 1
        )
    }
}
