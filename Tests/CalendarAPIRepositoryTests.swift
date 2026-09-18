import Foundation
import Testing
@testable import AI0506_Reminders

/// 用 `URLProtocol` 把 Calendar 的响应假装出来，覆盖真实 API 通路。
///
/// 这一层此前完全没有被执行过：DTO 解码、`{ok, data, error}` 信封、创建请求实际发出去的
/// 字段名，全靠人读代码确认。字段名写错的后果是上真机才 400，本地一点征兆都没有。
/// 响应形状照 `Calendar/API_DOC.md` 写。
@MainActor
@Suite(.serialized)
struct CalendarAPIRepositoryTests {
    // MARK: 假的传输层

    /// URLProtocol 的两个坑：路由表是静态的（所以这个 suite 必须串行跑），
    /// 以及 URLSession 会把请求体挪进 `httpBodyStream`，`httpBody` 读出来是 nil。
    private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        struct Response { let status: Int; let body: Data }
        struct Recorded { let method: String; let url: URL; let headers: [String: String]; let body: Data }

        nonisolated(unsafe) private static var routes: [String: Response] = [:]
        nonisolated(unsafe) private static var recorded: [Recorded] = []
        private static let lock = NSLock()

        static func reset(_ routes: [String: Response]) {
            lock.lock(); defer { lock.unlock() }
            Self.routes = routes
            Self.recorded = []
        }

        static var requests: [Recorded] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let url = request.url!
            Self.lock.lock()
            Self.recorded.append(Recorded(
                method: request.httpMethod ?? "GET",
                url: url,
                headers: request.allHTTPHeaderFields ?? [:],
                body: Self.bodyData(of: request)
            ))
            let match = Self.routes[url.path] ?? Response(status: 404, body: Data("{\"ok\":false,\"error\":{\"message\":\"no stub for \(url.path)\"}}".utf8))
            Self.lock.unlock()

            let response = HTTPURLResponse(url: url, statusCode: match.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: match.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        private static func bodyData(of request: URLRequest) -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }

    // MARK: 固定装置

    private static let baseURL = URL(string: "https://calendar.test.invalid")!

    private func makeRepository(_ routes: [String: StubURLProtocol.Response]) -> CalendarAPIRepository {
        StubURLProtocol.reset(routes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return CalendarAPIRepository(
            configuration: .init(baseURL: Self.baseURL, bearerToken: "test-token"),
            session: URLSession(configuration: configuration)
        )
    }

    private func ok(_ json: String) -> StubURLProtocol.Response {
        .init(status: 200, body: Data(json.utf8))
    }

    /// 一条定时 Deadline，字段照 API_DOC 的形状。
    private let deadlineJSON = """
    {"ok":true,"data":[{
      "id":"ddl-1","title":"Submit optics revision","description":"check part 4",
      "due_time":"2026-09-18T15:00:00+08:00","all_day":false,
      "category":"Research","subject_id":"sub-physics","color":null,
      "priority":"high","status":"open","is_overdue":false,"completed_at":null,
      "tags":[{"id":"exam","name":"exam"}],"updated_at":"2026-09-17T10:00:00+08:00"
    }]}
    """

    private let catalogRoutes: [String: String] = [
        "/api/categories": """
        {"ok":true,"data":[
          {"id":"cat-academics","name":"Academics","color":"#655f58","sort_order":1,"kind":"academics","archived":0},
          {"id":"cat-research","name":"Research","color":"#7f5fb5","sort_order":2,"kind":"normal","archived":0}
        ]}
        """,
        "/api/tags": """
        {"ok":true,"data":[{"id":"exam","name":"exam","color":"#ff0000"}]}
        """,
        "/api/subjects": """
        {"ok":true,"data":[{"id":"sub-physics","name":"Physics","category_id":"cat-academics","color":"#32ade6","sort_order":1,"active":1}]}
        """
    ]

    // MARK: 读取

    @Test
    func decodesATimedDeadlineFromTheEnvelope() async throws {
        let repository = makeRepository(["/api/deadlines": ok(deadlineJSON)])
        let deadlines = try await repository.fetchDeadlines()

        let deadline = try #require(deadlines.first)
        #expect(deadline.id == "ddl-1")
        #expect(deadline.title == "Submit optics revision")
        #expect(deadline.detail == "check part 4")
        #expect(!deadline.allDay)
        #expect(deadline.priority == .high)
        #expect(deadline.status == .open)
        #expect(deadline.tags.map(\.id) == ["exam"])
    }

    /// 记录既有行为：DTO 拿不到真实分类 id，只能给占位值，学科也只有 id。
    /// 这正是 `DeadlineStore.applyCatalog` 必须回填的原因——
    /// 哪天后端开始返回真实 id，这条会红，提醒把回填逻辑一起改掉。
    @Test
    func leavesCategoryAndSubjectAsPlaceholdersForTheStoreToBackfill() async throws {
        let repository = makeRepository(["/api/deadlines": ok(deadlineJSON)])
        let deadline = try #require(try await repository.fetchDeadlines().first)

        #expect(deadline.category.id == "uncatalogued")
        #expect(deadline.category.name == "Research")
        #expect(deadline.subject?.id == "sub-physics")
        #expect(deadline.subject?.name == "")
    }

    @Test
    func sendsBearerTokenAndTheExpectedQuery() async throws {
        let repository = makeRepository(["/api/deadlines": ok(deadlineJSON)])
        _ = try await repository.fetchDeadlines()

        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.headers["Authorization"] == "Bearer test-token")
        let query = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains { $0.name == "include_completed" && $0.value == "true" })
        #expect(query.contains { $0.name == "from" })
        #expect(query.contains { $0.name == "to" })
    }

    @Test
    func decodesTheCatalogIncludingAcademicsKind() async throws {
        var routes: [String: StubURLProtocol.Response] = [:]
        for (path, json) in catalogRoutes { routes[path] = ok(json) }
        let repository = makeRepository(routes)

        let catalog = try await repository.fetchCatalog()
        #expect(catalog.categories.map(\.name) == ["Academics", "Research"])
        #expect(catalog.categories.first?.kind == "academics")
        #expect(catalog.categories.last?.kind == "normal")
        #expect(catalog.subjects.first?.categoryID == "cat-academics")
        #expect(catalog.tags.map(\.name) == ["exam"])
    }

    // MARK: 写入

    /// 创建请求发出去的字段名是后端合法性校验的直接输入，写错就是 400。
    @Test
    func createSendsTheFieldNamesTheBackendValidates() async throws {
        let repository = makeRepository(["/api/deadlines": .init(status: 201, body: Data("""
        {"ok":true,"data":{"id":"new","title":"t","due_time":"2026-09-20T09:00:00+08:00","all_day":false,
        "category":"Research","priority":"default","tags":[],"updated_at":"2026-09-18T09:00:00+08:00"}}
        """.utf8))])

        var draft = DeadlineDraft()
        draft.title = "  Submit optics revision  "
        draft.detail = ""
        draft.category = .init(id: "cat-research", name: "Research", colorHex: "#7f5fb5")
        draft.tags = [.init(id: "exam", name: "exam")]
        draft.priority = .high
        _ = try await repository.create(draft)

        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.method == "POST")
        let body = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        // category 送的是名字而不是 id——后端就是按名字校验的。
        #expect(body["category"] as? String == "Research")
        #expect(body["title"] as? String == "Submit optics revision")
        #expect(body["priority"] as? String == "high")
        #expect(body["tag_ids"] as? [String] == ["exam"])
        #expect(body["all_day"] as? Bool == false)
        #expect(body["due_time"] != nil)
        // 空备注不能送空字符串。
        #expect(body["description"] == nil || body["description"] is NSNull)
    }

    @Test
    func allDayCreateSendsADateOnlyDueTime() async throws {
        let repository = makeRepository(["/api/deadlines": .init(status: 201, body: Data("""
        {"ok":true,"data":{"id":"new","title":"t","due_time":"2026-09-20","all_day":true,
        "category":"Research","priority":"default","tags":[],"updated_at":"2026-09-18T09:00:00+08:00"}}
        """.utf8))])

        var draft = DeadlineDraft()
        draft.title = "Reading week"
        draft.allDay = true
        draft.category = .init(id: "cat-research", name: "Research", colorHex: "#7f5fb5")
        _ = try await repository.create(draft)

        let request = try #require(StubURLProtocol.requests.first)
        let body = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let dueTime = try #require(body["due_time"] as? String)
        // 全天必须是 YYYY-MM-DD，带时间的 ISO 串会被后端拒掉。
        #expect(dueTime.count == 10)
        #expect(!dueTime.contains("T"))
    }

    @Test
    func completionHitsTheCompleteAndReopenPaths() async throws {
        let payload = Data("""
        {"ok":true,"data":{"id":"ddl-1","title":"t","due_time":"2026-09-18T15:00:00+08:00","all_day":false,
        "category":"Research","priority":"default","tags":[],"completed_at":"2026-09-18T12:00:00+08:00",
        "updated_at":"2026-09-18T12:00:00+08:00"}}
        """.utf8)
        let repository = makeRepository([
            "/api/deadlines/ddl-1/complete": .init(status: 200, body: payload),
            "/api/deadlines/ddl-1/reopen": .init(status: 200, body: payload)
        ])
        let deadline = Deadline(id: "ddl-1", title: "t", detail: "", dueDate: .now, allDay: false,
                                category: DeadlineCategory.all[0], subject: nil, tags: [],
                                priority: .default, status: .open, updatedAt: .now)

        let completed = try await repository.setCompletion(deadline, completed: true)
        #expect(completed.status == .completed)
        #expect(StubURLProtocol.requests.last?.url.path == "/api/deadlines/ddl-1/complete")

        _ = try await repository.setCompletion(deadline, completed: false)
        #expect(StubURLProtocol.requests.last?.url.path == "/api/deadlines/ddl-1/reopen")
    }

    // MARK: 课程上下文

    @Test
    func decodesTheCourseCatalogIncludingRetiredCourses() async throws {
        let repository = makeRepository(["/api/course-catalog": ok("""
        {"ok":true,"data":[
          {"id":"course-g11-09","name":"ESL 1层雅思写作","subject_id":"sub-english","active":1},
          {"id":"course-old","name":"Speaking L1A","subject_id":"sub-english","active":0}
        ]}
        """)])

        let courses = try await repository.fetchCourseCatalog()
        #expect(courses.map(\.id) == ["course-g11-09", "course-old"])
        // active 是 0/1 不是布尔；停用课程必须留在目录里，否则历史课程名就命不中了。
        #expect(courses.first?.active == true)
        #expect(courses.last?.active == false)
    }

    @Test
    func courseScheduleSendsTheRequiredRangeAndParsesWallClockTimes() async throws {
        let repository = makeRepository(["/api/course-schedule": ok("""
        {"ok":true,"data":[{
          "id":"course:slot-9:2026-09-18","date":"2026-09-18","course_id":"course-g11-09",
          "course_slot_id":"slot-9","title":"ESL 1层雅思写作","subject_id":"sub-english",
          "start_time":"2026-09-18T14:00:00+08:00","end_time":"2026-09-18T14:45:00+08:00","status":"scheduled"
        }]}
        """)])

        let occurrences = try await repository.fetchCourseSchedule(
            from: Date(timeIntervalSince1970: 1_789_000_000),
            to: Date(timeIntervalSince1970: 1_789_600_000)
        )
        let occurrence = try #require(occurrences.first)
        #expect(occurrence.courseID == "course-g11-09")
        #expect(occurrence.end.timeIntervalSince(occurrence.start) == 45 * 60)

        // from / to 是必填，少一个后端直接 400。
        let request = try #require(StubURLProtocol.requests.first)
        let query = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains { $0.name == "from" })
        #expect(query.contains { $0.name == "to" })
    }

    /// 课程上下文这一条读取**不能**带日期窗口：逾期未交的作业仍是未完成作业，
    /// 加了窗口它就从上下文里消失了。普通列表照旧带范围。
    @Test
    func openDeadlinesForCourseContextAreFetchedWithoutADateWindow() async throws {
        let repository = makeRepository(["/api/deadlines": ok("""
        {"ok":true,"data":[{
          "id":"ddl-2","title":"Read Chapter 4","due_time":"2026-09-10","all_day":true,
          "category":"Academics","subject_id":"sub-english","course_id":"course-g11-10",
          "priority":"default","status":"overdue","is_overdue":true,"completed_at":null,
          "tags":[{"id":"tag-homework","name":"Homework"}],"updated_at":"2026-09-09T10:00:00+08:00"
        }]}
        """)])

        let deadlines = try await repository.fetchOpenDeadlinesForCourseContext()
        #expect(deadlines.first?.courseID == "course-g11-10")

        let request = try #require(StubURLProtocol.requests.first)
        let query = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains { $0.name == "include_completed" && $0.value == "false" })
        #expect(!query.contains { $0.name == "from" })
        #expect(!query.contains { $0.name == "to" })
    }

    @Test
    func createSendsCourseIDOnlyAlongsideASubject() async throws {
        let created = """
        {"ok":true,"data":{"id":"new","title":"t","due_time":"2026-09-20T09:00:00+08:00","all_day":false,
        "category":"Academics","subject_id":"sub-english","course_id":"course-g11-09","priority":"default",
        "tags":[],"updated_at":"2026-09-18T09:00:00+08:00"}}
        """
        var repository = makeRepository(["/api/deadlines": .init(status: 201, body: Data(created.utf8))])

        var draft = DeadlineDraft()
        draft.title = "把作文改完"
        draft.category = .init(id: "cat-academics", name: "Academics", colorHex: "#655f58", kind: "academics")
        draft.subject = .init(id: "sub-english", name: "English", categoryID: "cat-academics", colorHex: "#ff9f0a")
        draft.courseID = "course-g11-09"
        let deadline = try await repository.create(draft)

        var request = try #require(StubURLProtocol.requests.first)
        var body = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["course_id"] as? String == "course-g11-09")
        #expect(body["subject_id"] as? String == "sub-english")
        #expect(deadline.courseID == "course-g11-09")

        // 没有 subject 的草稿带 course_id 必然被后端 400，所以客户端就不送。
        repository = makeRepository(["/api/deadlines": .init(status: 201, body: Data(created.utf8))])
        draft.subject = nil
        _ = try await repository.create(draft)
        request = try #require(StubURLProtocol.requests.first)
        body = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["course_id"] == nil || body["course_id"] is NSNull)
    }

    // MARK: 错误

    /// 后端的错误信封要被拆开取 message，不能把整个响应体抛给用户（规格 §7.3）。
    @Test
    func surfacesTheBackendErrorMessageNotTheRawBody() async throws {
        let repository = makeRepository(["/api/deadlines": .init(
            status: 400,
            body: Data("""
            {"ok":false,"error":{"code":"validation_error","message":"category not found"}}
            """.utf8)
        )])

        await #expect(throws: (any Error).self) { try await repository.fetchDeadlines() }
        do {
            _ = try await repository.fetchDeadlines()
        } catch {
            #expect(error.localizedDescription == "category not found")
            #expect(!error.localizedDescription.contains("validation_error"))
        }
    }
}
