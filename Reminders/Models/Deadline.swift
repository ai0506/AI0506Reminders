import Foundation
import SwiftUI

extension Calendar {
    /// 项目里判「今天」「明天」「逾期」和一切相对日期的唯一时区锚点。
    ///
    /// 后端就是按 Asia/Shanghai 定义这些概念的（见 `CLAUDE.md`），跟着设备时区走的话，
    /// 人换个地区、或模拟器地区不是中国，「明天」就会落到错误的自然日上。实测过一次：
    /// 设备设成洛杉矶时，「周五下午三点」被算到了周六。
    ///
    /// 放在 Models 里是因为 Widget target 也编译这个目录，两边必须用同一把尺子。
    static let shanghai: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }()
}

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
    /// 关联的具体课程（Calendar 的 `deadlines.course_id`，migration 0015）。
    /// 与 `subject`（学科）和 `tags`（任务性质）三者互不替代：English 是学科，
    /// Homework 是性质，「ESL 1层雅思写作」才是课程。后端只在写入时校验它与
    /// `subject_id` 一致，不看课程是否停用，所以历史归属不会随学期消失。
    var courseID: String?
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
    var courseID: String?
    var tags: [DeadlineTag] = []
    var priority: DeadlinePriority = .default
}

struct AIParseResult: Hashable {
    var originalText: String
    var draft: DeadlineDraft
    /// 草稿里的课程叫什么、凭什么挂上去，给确认页显示。
    ///
    /// 存成现成的文案而不是解析出来的类型：这个文件被 Widget target 一起编译，
    /// 不能引用 `Reminders/Services` 里的东西（见 CLAUDE.md）。
    var courseName: String?
    var courseBasis: String?
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
