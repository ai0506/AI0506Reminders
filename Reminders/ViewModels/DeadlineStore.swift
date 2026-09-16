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
        isLoading = true
        defer { isLoading = false }
        do {
            let catalog = try? await repository.fetchCatalog()
            let fetchedDeadlines = try await repository.fetchDeadlines()
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
            deadlines.insert(created, at: 0)
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
        try? await Task.sleep(for: .milliseconds(560))
        return MockAIDeadlineParser.parse(input: input, categories: categories, tags: availableTags, subjects: subjects)
    }

    func connect(to configuration: CalendarAPIRepository.Configuration) async -> Bool {
        let previousRepository = repository
        let previousMode = isDemoMode
        repository = CalendarAPIRepository(configuration: configuration)
        isDemoMode = false
        await refresh()
        if errorMessage != nil {
            repository = previousRepository
            isDemoMode = previousMode
            return false
        }
        return true
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
