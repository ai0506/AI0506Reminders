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
        let calendar = Calendar.current
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
        let calendar = Calendar.current
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

    func parseMockAI(_ input: String) async -> AIParseResult {
        // 解析本身是纯本地计算，没有理由等。这一步的可见时长由 AIComposerSheet
        // 的最短停留控制，不在这里人造延迟。
        return MockAIDeadlineParser.parse(input: input, categories: categories, tags: availableTags, subjects: subjects)
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
