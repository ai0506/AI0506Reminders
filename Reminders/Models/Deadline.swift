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

    static let all: [DeadlineCategory] = [
        .init(id: "academics", name: "学业", colorHex: "#78716C", kind: "academics"),
        .init(id: "research", name: "研究", colorHex: "#54A9A3"),
        .init(id: "projects", name: "项目", colorHex: "#E69A58"),
        .init(id: "leisure", name: "生活", colorHex: "#999A9F"),
        .init(id: "tech", name: "技术", colorHex: "#6395D6")
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
