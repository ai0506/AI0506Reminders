import Foundation

/// Production transport for the existing Calendar Deadline API. The app stays
/// in demo mode until a private base URL and bearer token are supplied through
/// a future settings/keychain flow; neither value is hard-coded in the app.
@MainActor
final class CalendarAPIRepository: DeadlineRepository {
    struct Configuration {
        let baseURL: URL
        let bearerToken: String
    }

    private let configuration: Configuration
    private let session: URLSession

    init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func fetchDeadlines() async throws -> [Deadline] {
        let calendar = Calendar.current
        let from = calendar.date(byAdding: .day, value: -30, to: .now) ?? .now
        let to = calendar.date(byAdding: .day, value: 120, to: .now) ?? .now
        var components = URLComponents(url: configuration.baseURL.appending(path: "api/deadlines"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "from", value: DeadlineAPI.dateOnly.string(from: from)),
            .init(name: "to", value: DeadlineAPI.dateOnly.string(from: to)),
            .init(name: "include_completed", value: "true")
        ]
        let response: APIEnvelope<[DeadlineDTO]> = try await request(url: components.url!, method: "GET")
        return try response.requireData().map { $0.model }
    }

    func fetchCatalog() async throws -> DeadlineCatalog {
        let categoryResponse: APIEnvelope<[CategoryDTO]> = try await request(
            url: configuration.baseURL.appending(path: "api/categories"),
            method: "GET"
        )
        let tagResponse: APIEnvelope<[TagDTO]> = try await request(
            url: configuration.baseURL.appending(path: "api/tags"),
            method: "GET"
        )
        let subjectResponse: APIEnvelope<[SubjectDTO]> = try await request(
            url: configuration.baseURL.appending(path: "api/subjects"),
            method: "GET"
        )
        let categories = try categoryResponse.requireData().map(\.model)
        let tags = try tagResponse.requireData().map(\.model)
        let subjects = try subjectResponse.requireData().map(\.model)
        return DeadlineCatalog(categories: categories, tags: tags, subjects: subjects)
    }

    func create(_ draft: DeadlineDraft) async throws -> Deadline {
        let body = CreateDeadlineBody(draft: draft)
        let response: APIEnvelope<DeadlineDTO> = try await request(
            url: configuration.baseURL.appending(path: "api/deadlines"),
            method: "POST",
            body: body
        )
        return try response.requireData().model
    }

    func setCompletion(_ deadline: Deadline, completed: Bool) async throws -> Deadline {
        let endpoint = completed ? "complete" : "reopen"
        let response: APIEnvelope<DeadlineDTO> = try await request(
            url: configuration.baseURL.appending(path: "api/deadlines/\(deadline.id)/\(endpoint)"),
            method: "POST"
        )
        return try response.requireData().model
    }

    private func request<T: Decodable, Body: Encodable>(url: URL, method: String, body: Body? = nil) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let apiError = try? JSONDecoder().decode(APIEnvelope<EmptyPayload>.self, from: data).error?.message
            throw CalendarAPIError.requestFailed(apiError ?? "Calendar service returned an error.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func request<T: Decodable>(url: URL, method: String) async throws -> T {
        try await request(url: url, method: method, body: Optional<EmptyPayload>.none)
    }
}

private enum CalendarAPIError: LocalizedError {
    case requestFailed(String)

    var errorDescription: String? {
        switch self { case .requestFailed(let message): message }
    }
}

private struct EmptyPayload: Codable {}

private struct APIEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let data: T?
    let error: APIError?

    enum CodingKeys: String, CodingKey {
        case ok, data, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decodeIfPresent(T.self, forKey: .data)
        error = try container.decodeIfPresent(APIError.self, forKey: .error)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? (data != nil)
    }

    func requireData() throws -> T {
        guard ok, let data else { throw CalendarAPIError.requestFailed(error?.message ?? "Calendar service returned no data.") }
        return data
    }
}

private struct APIError: Decodable {
    let code: String?
    let message: String

    enum CodingKeys: String, CodingKey {
        case code, message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeIfPresent(String.self, forKey: .code)
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? "Calendar service returned an error."
    }
}

private struct DeadlineDTO: Decodable {
    let id: String
    let title: String
    let description: String?
    let dueTime: String
    let allDay: Bool
    let category: String?
    let subjectID: String?
    let color: String?
    let priority: DeadlinePriority
    let status: DeadlineStatus?
    let isOverdue: Bool
    let completedAt: String?
    let tags: [TagDTO]
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, title, description, category, color, priority, status, tags
        case subjectID = "subject_id"
        case dueTime = "due_time"
        case allDay = "all_day"
        case isOverdue = "is_overdue"
        case completedAt = "completed_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        dueTime = try container.decodeIfPresent(String.self, forKey: .dueTime) ?? DeadlineAPI.isoString(from: .now)
        allDay = try container.decodeIfPresent(Bool.self, forKey: .allDay) ?? false
        category = try container.decodeIfPresent(String.self, forKey: .category)
        subjectID = try container.decodeIfPresent(String.self, forKey: .subjectID)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        priority = try container.decodeIfPresent(DeadlinePriority.self, forKey: .priority) ?? .default
        status = try container.decodeIfPresent(DeadlineStatus.self, forKey: .status)
        isOverdue = try container.decodeIfPresent(Bool.self, forKey: .isOverdue) ?? false
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
        tags = try container.decodeIfPresent([TagDTO].self, forKey: .tags) ?? []
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? DeadlineAPI.isoString(from: .now)
    }

    var model: Deadline {
        let category = DeadlineCategory(id: "uncatalogued", name: self.category ?? "Other", colorHex: color ?? "#999A9F")
        let dueDate = DeadlineAPI.parse(dueTime, allDay: allDay) ?? .now
        let computedStatus: DeadlineStatus = completedAt != nil ? .completed : (isOverdue ? .overdue : (status ?? .open))
        return Deadline(
            id: id,
            title: title,
            detail: description ?? "",
            dueDate: dueDate,
            allDay: allDay,
            category: category, subject: subjectID.map { .init(id: $0, name: "", categoryID: "", colorHex: "#999A9F") },
            tags: tags.map { .init(id: $0.id, name: $0.name) },
            priority: priority,
            status: computedStatus,
            updatedAt: DeadlineAPI.isoDate(from: updatedAt) ?? .now
        )
    }
}

private struct TagDTO: Decodable {
    let id: String
    let name: String

    var model: DeadlineTag { .init(id: id, name: name) }
}

private struct CategoryDTO: Decodable {
    let id: String
    let name: String
    let color: String
    let kind: String?

    enum CodingKeys: String, CodingKey {
        case id, name, color, kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        color = try container.decodeIfPresent(String.self, forKey: .color) ?? "#999A9F"
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
    }

    var model: DeadlineCategory { .init(id: id, name: name, colorHex: color, kind: kind ?? "normal") }
}

private struct SubjectDTO: Decodable {
    let id: String
    let name: String
    let categoryID: String
    let color: String

    enum CodingKeys: String, CodingKey {
        case id, name, color
        case categoryID = "category_id"
    }

    var model: DeadlineSubject { .init(id: id, name: name, categoryID: categoryID, colorHex: color) }
}

private struct CreateDeadlineBody: Encodable {
    let title: String
    let description: String?
    let dueTime: String
    let allDay: Bool
    let category: String
    let subjectID: String?
    let priority: DeadlinePriority
    let tagIDs: [String]
    let source = "ipad"

    enum CodingKeys: String, CodingKey {
        case title, description, category, priority, source
        case subjectID = "subject_id"
        case dueTime = "due_time"
        case allDay = "all_day"
        case tagIDs = "tag_ids"
    }

    init(draft: DeadlineDraft) {
        title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        description = draft.detail.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        dueTime = draft.allDay ? DeadlineAPI.dateOnly.string(from: draft.dueDate) : DeadlineAPI.isoString(from: draft.dueDate)
        allDay = draft.allDay
        category = draft.category.name
        subjectID = draft.subject?.id
        priority = draft.priority
        tagIDs = draft.tags.map(\.id)
    }
}

private enum DeadlineAPI {
    static let dateOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func parse(_ value: String, allDay: Bool) -> Date? {
        if allDay { return dateOnly.date(from: value) }
        return isoDate(from: value)
    }

    static func isoDate(from value: String) -> Date? { ISO8601DateFormatter().date(from: value) }
    static func isoString(from value: Date) -> String { ISO8601DateFormatter().string(from: value) }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
