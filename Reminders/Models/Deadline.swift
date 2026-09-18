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

    /// Widget target 用得到的兜底目录，必须与 `Resources/sample-workspace.json` 里未归档的分类一致
    /// （`SharedFixtureTests` 会核对）。真实目录以 `GET /api/categories` 为准。
    ///
    /// 注意别照 `Calendar/production/FRONTEND_SPEC.md` §6 抄名字——那份文档写的是
    /// "AI0506 Project" / "Personal"，而迁移 0001+0003 里实际叫 Projects / Leisure。
    /// 数据库是真相，文档不是。
    static let all: [DeadlineCategory] = [
        .init(id: "cat-academics", name: "Academics", colorHex: "#655f58", kind: "academics"),
        .init(id: "cat-research", name: "Research", colorHex: "#7f5fb5"),
        .init(id: "cat-project", name: "Projects", colorHex: "#c07043"),
        .init(id: "cat-personal", name: "Leisure", colorHex: "#bd5f86"),
        .init(id: "cat-other", name: "Tech", colorHex: "#64748b")
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
