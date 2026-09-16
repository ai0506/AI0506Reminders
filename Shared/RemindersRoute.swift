import Foundation

enum RemindersRoute {
    static let scheme = "ai0506reminders"

    static func deadlineURL(id: String) -> URL {
        URL(string: "\(scheme)://deadline/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)")!
    }

    static func deadlineID(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == "deadline" else { return nil }
        let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return id.isEmpty ? nil : id.removingPercentEncoding ?? id
    }
}

extension Notification.Name {
    static let openDeadlineRoute = Notification.Name("open-deadline-route")
}
