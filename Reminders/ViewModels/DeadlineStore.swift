import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class DeadlineStore {
    private var repository: any DeadlineRepository
    private let offlineCache: DeadlineOfflineCache
    var deadlines: [Deadline] = []
    var categories = DeadlineCatalog.demo.categories
    var availableTags = DeadlineCatalog.demo.tags
    var subjects = DeadlineCatalog.demo.subjects
    var selectedFilter: DeadlineFilter? = .today {
        didSet { reconcileSelectionWithFilter() }
    }
    var selectedDeadlineID: String?
    var isLoading = false
    var errorMessage: String?
    var isDemoMode = true
    var syncNote: String?
    private var pendingDeadlineID: String?
    /// 每次 refresh 领一个号。冷启动的演示 refresh 和 `.task` 里恢复真实连接后的
    /// refresh 会并发跑，两者都要写 `deadlines`；没有这个号的话，先发起、后返回的
    /// 那个会把真实数据覆盖成演示数据，而且此时 `isDemoMode` 已经是 false，
    /// 演示数据还会被写进真实的离线缓存。
    private var refreshGeneration = 0
    private let aiParser = FoundationModelsDeadlineParser()
    /// 课程上下文的本地副本，`prewarmAI()` 时取回。空着也能用，只是推不出 course_id。
    private var courseCatalog: [Course] = []
    private var courseOccurrences: [CourseOccurrence] = []
    private var courseworkDeadlines: [Deadline] = []
    /// 课程与「今天」的时区锚点一律是上海，不是设备时区。
    private static let shanghai = TimeZone(identifier: "Asia/Shanghai") ?? .current
    /// 模型不可用或这次回退到本地规则时给用户的一句说明；正常走通时为 nil。
    var aiNote: String?

    init(repository: any DeadlineRepository, offlineCache: DeadlineOfflineCache = .shared) {
        self.repository = repository
        self.offlineCache = offlineCache
        deadlines = offlineCache.load()
        if !deadlines.isEmpty {
            syncNote = "正在显示已保存的截止事项"
            SharedDeadlineCache.save(deadlines: deadlines)
            selectedDeadlineID = visibleDeadlines.first?.id
        }
        Task { await refresh() }
    }

    var selectedDeadline: Deadline? {
        deadlines.first(where: { $0.id == selectedDeadlineID })
    }

    var visibleDeadlines: [Deadline] {
        let now = Date()
        let calendar = Calendar.shanghai
        let filter = selectedFilter ?? .today
        return deadlines.filter { deadline in
            switch filter {
            case .today:
                return calendar.isDateInToday(deadline.dueDate) && !deadline.isCompleted
            case .upcoming:
                return deadline.dueDate >= now && !deadline.isCompleted
            case .overdue:
                return deadline.isOverdue && !deadline.isCompleted
            case .all:
                return true
            case .category(let id):
                return deadline.category.id == id
            case .tag(let id):
                return deadline.tags.contains(where: { $0.id == id })
            case .subject(let id):
                return deadline.subject?.id == id
            }
        }.sorted { lhs, rhs in
            if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }
            return lhs.dueDate < rhs.dueDate
        }
    }

    var groups: [DeadlineGroup] {
        let calendar = Calendar.shanghai
        let groups = Dictionary(grouping: visibleDeadlines) { calendar.startOfDay(for: $0.dueDate) }
        return groups.keys.sorted().map { date in
            let title: String
            if calendar.isDateInToday(date) { title = "今天" }
            else if calendar.isDateInTomorrow(date) { title = "明天" }
            else { title = date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) }
            return DeadlineGroup(date: date, title: title, deadlines: groups[date]!.sorted { $0.dueDate < $1.dueDate })
        }
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        // 仓库可能在这次刷新进行中被换掉（连接 / 断开），所以整趟只认一开始拿到的那个。
        let activeRepository = repository
        isLoading = true
        defer { if generation == refreshGeneration { isLoading = false } }
        do {
            let catalog = try? await activeRepository.fetchCatalog()
            let fetchedDeadlines = try await activeRepository.fetchDeadlines()
            guard generation == refreshGeneration else { return }
            if let catalog, !catalog.categories.isEmpty {
                categories = catalog.categories
                availableTags = catalog.tags
                subjects = catalog.subjects
            }
            deadlines = applyCatalog(to: fetchedDeadlines)
            SharedDeadlineCache.save(deadlines: deadlines)
            if !isDemoMode { offlineCache.replace(with: deadlines) }
            DeadlineNotificationScheduler.shared.scheduleIfPermitted(for: deadlines)
            if let pendingDeadlineID, deadlines.contains(where: { $0.id == pendingDeadlineID }) {
                selectedDeadlineID = pendingDeadlineID
                self.pendingDeadlineID = nil
            } else {
                selectedDeadlineID = selectedDeadlineID ?? visibleDeadlines.first?.id
            }
            errorMessage = nil
            syncNote = isDemoMode ? "演示工作区" : "已同步"
        } catch {
            guard generation == refreshGeneration else { return }
            if deadlines.isEmpty {
                errorMessage = error.localizedDescription
                syncNote = nil
            } else {
                errorMessage = nil
                syncNote = "离线 · 正在显示已保存的截止事项"
            }
        }
    }

    func create(_ draft: DeadlineDraft) async -> Bool {
        do {
            let created = try await repository.create(draft)
            // API 返回的 DTO 里 category id 是占位的 "uncatalogued"、subject 只有 id
            // 没有名字，得跟刷新走同一条回填路径，否则新建的这条在分类筛选里立刻消失、
            // 学科名也是空的，要等下一次 refresh 才恢复。
            deadlines.insert(contentsOf: applyCatalog(to: [created]), at: 0)
            SharedDeadlineCache.save(deadlines: deadlines)
            if !isDemoMode { offlineCache.replace(with: deadlines) }
            DeadlineNotificationScheduler.shared.scheduleIfPermitted(for: deadlines)
            selectedDeadlineID = created.id
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func toggleCompletion(_ deadline: Deadline) async {
        let previous = deadlines
        guard let index = deadlines.firstIndex(where: { $0.id == deadline.id }) else { return }
        deadlines[index].status = deadline.isCompleted ? (deadline.dueDate < Date() ? .overdue : .open) : .completed
        do {
            let remote = try await repository.setCompletion(deadline, completed: !deadline.isCompleted)
            if let updatedIndex = deadlines.firstIndex(where: { $0.id == deadline.id }) { deadlines[updatedIndex] = remote }
            SharedDeadlineCache.save(deadlines: deadlines)
            if !isDemoMode { offlineCache.replace(with: deadlines) }
            DeadlineNotificationScheduler.shared.scheduleIfPermitted(for: deadlines)
        } catch {
            deadlines = previous
            errorMessage = error.localizedDescription
        }
    }

    /// AI 面板出现时就调，别等用户点「分析这段话」。
    /// 首次推理要加载模型，那段成本正好用用户打字的几秒吃掉；课程上下文也一并在
    /// 这段时间里取回来，免得解析时再等三个请求。
    func prewarmAI() {
        aiParser.prewarm()
        Task { await loadCourseContext() }
    }

    /// 课程上下文只有 AI 创建用得上，所以不在冷启动的 refresh 里取，等 AI 面板打开再说。
    ///
    /// 三个请求全部失败也只是让 `course_id` 保持 nil，草稿其余部分照常——课程是增强，
    /// 不是必需品。演示仓库不提供这些接口（协议给了返回空的默认实现），所以演示模式下
    /// 这里自然就是空的。
    private func loadCourseContext() async {
        guard !isDemoMode else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.shanghai
        let today = Date()
        let start = calendar.startOfDay(for: today)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start

        // 顺序取，不用 async let：`DeadlineRepository` 不是 Sendable，并发派三个请求
        // 过不了 Swift 6 的并发检查。这段跑在用户打字的时候，串行也不会被察觉。
        courseCatalog = (try? await repository.fetchCourseCatalog()) ?? []
        // 课表要往后取一周：候选要带「下一次上课」，只取今天是算不出来的。
        courseOccurrences = (try? await repository.fetchCourseSchedule(from: start, to: end)) ?? []
        courseworkDeadlines = (try? await repository.fetchOpenDeadlinesForCourseContext()) ?? []
    }

    /// 设备端模型优先，失败一律回退到本地规则解析。
    ///
    /// 回退不是可有可无的兜底：Apple 智能可能没开、模型可能还在下载、端侧护栏
    /// 也可能对正常输入误触发。这些情况下用户点了「分析」总得看到一份草稿，
    /// 而不是一个错误弹窗——`MockAIDeadlineParser` 至少能解出时间和标题。
    func parseAI(_ input: String) async -> AIParseResult {
        aiNote = nil
        do {
            let context = CourseContextBuilder().build(
                input: input,
                catalog: courseCatalog,
                occurrences: courseOccurrences,
                openDeadlines: courseworkDeadlines
            )
            return try await aiParser.parse(
                input: input,
                categories: categories,
                tags: availableTags,
                subjects: subjects,
                courseContext: context,
                courseCatalog: courseCatalog
            )
        } catch {
            if let unavailable = error as? FoundationModelsDeadlineParser.Unavailable {
                aiNote = unavailable.message
            } else {
                aiNote = "设备端模型这次没能给出结果，已改用本地规则解析。"
            }
            return MockAIDeadlineParser.parse(input: input, categories: categories, tags: availableTags, subjects: subjects)
        }
    }

    /// 设备端模型此刻是否可用，决定 AI 面板上那行隐私说明的措辞。
    var isOnDeviceModelAvailable: Bool {
        FoundationModelsDeadlineParser.availability == nil
    }

    /// 连接必须自己发一次请求并让错误抛出来。
    ///
    /// 不能拿 `refresh()` 的结果判断连通性：本地只要已经有数据（冷启动的演示数据、
    /// 或上次的离线缓存），`refresh()` 就会把请求失败降级成「离线」提示并清掉
    /// `errorMessage`。于是填错地址或令牌也会被判定成连接成功——界面显示「已连接」、
    /// 错误的令牌被写进钥匙串、列表里还是演示数据，用户完全分辨不出来。
    func connect(to configuration: CalendarAPIRepository.Configuration) async throws {
        let candidate = CalendarAPIRepository(configuration: configuration)
        _ = try await candidate.fetchDeadlines()
        repository = candidate
        isDemoMode = false
        errorMessage = nil
        await refresh()
    }

    /// 启动时恢复已保存的连接。这份配置在保存时已经探测过，所以这里不再探测，
    /// 直接采用并交给 `refresh()` 按离线规则降级——否则一开机没网就会退回演示工作区，
    /// 把用户真实的缓存数据藏起来。
    func restoreConnection(_ configuration: CalendarAPIRepository.Configuration) async {
        repository = CalendarAPIRepository(configuration: configuration)
        isDemoMode = false
        await refresh()
    }

    func useDemoWorkspace() async {
        repository = MockDeadlineRepository()
        isDemoMode = true
        syncNote = "演示工作区"
        await refresh()
    }

    func open(url: URL) {
        guard let deadlineID = RemindersRoute.deadlineID(from: url) else { return }
        open(deadlineID: deadlineID)
    }

    func open(deadlineID: String) {
        selectedFilter = .all
        if deadlines.contains(where: { $0.id == deadlineID }) {
            selectedDeadlineID = deadlineID
        } else {
            pendingDeadlineID = deadlineID
        }
    }

    func selectedFilterTitle() -> String {
        guard let filter = selectedFilter else { return "截止事项" }
        if case .category(let id) = filter {
            return categories.first(where: { $0.id == id })?.name ?? filter.title
        }
        if case .tag(let id) = filter {
            return availableTags.first(where: { $0.id == id })?.name ?? filter.title
        }
        if case .subject(let id) = filter {
            return subjects.first(where: { $0.id == id })?.name ?? filter.title
        }
        return filter.title
    }

    private func applyCatalog(to deadlines: [Deadline]) -> [Deadline] {
        deadlines.map { deadline in
            var updated = deadline
            if let category = categories.first(where: { $0.name.caseInsensitiveCompare(deadline.category.name) == .orderedSame }) {
                updated.category = category
            }
            if let subjectID = deadline.subject?.id {
                updated.subject = subjects.first(where: { $0.id == subjectID })
            }
            return updated
        }
    }

    private func reconcileSelectionWithFilter() {
        guard let selectedDeadlineID else {
            self.selectedDeadlineID = visibleDeadlines.first?.id
            return
        }
        if !visibleDeadlines.contains(where: { $0.id == selectedDeadlineID }) {
            self.selectedDeadlineID = visibleDeadlines.first?.id
        }
    }
}
