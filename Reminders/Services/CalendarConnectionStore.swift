import Foundation
import Observation
import Security

@MainActor
@Observable
final class CalendarConnectionStore {
    private static let baseURLKey = "calendar-api-base-url"

    var baseURLText: String
    var token = ""
    var hasSavedToken: Bool
    var isConnecting = false
    var connectionMessage: String?

    init() {
        baseURLText = UserDefaults.standard.string(forKey: Self.baseURLKey) ?? ""
        token = ""
        hasSavedToken = CalendarCredentialVault.readToken() != nil
    }

    var savedConfiguration: CalendarAPIRepository.Configuration? {
        guard let baseURL = validBaseURL(from: baseURLText), let token = CalendarCredentialVault.readToken() else { return nil }
        return .init(baseURL: baseURL, bearerToken: token)
    }

    func connect(store: DeadlineStore) async {
        connectionMessage = nil
        do {
            let configuration = try configuration()
            isConnecting = true
            defer { isConnecting = false }
            // 只有探测成功才走到下面这行，令牌也只有到这里才会落盘。
            try await store.connect(to: configuration)
            try CalendarCredentialVault.saveToken(configuration.bearerToken)
            UserDefaults.standard.set(configuration.baseURL.absoluteString, forKey: Self.baseURLKey)
            token = ""
            hasSavedToken = true
            connectionMessage = "已连接到你的 Calendar 截止事项。"
        } catch {
            // 光给系统原文（"A TLS error caused..."）不够：用户要知道自己填的东西
            // 有没有被保存、接下来能做什么。
            connectionMessage = "无法连接 Calendar：\(error.localizedDescription)\n地址和令牌都没有保存，修改后可以重试；当前仍在演示工作区。"
        }
    }

    func disconnect(store: DeadlineStore) async {
        CalendarCredentialVault.deleteToken()
        UserDefaults.standard.removeObject(forKey: Self.baseURLKey)
        token = ""
        baseURLText = ""
        hasSavedToken = false
        connectionMessage = nil
        await store.useDemoWorkspace()
    }

    private func configuration() throws -> CalendarAPIRepository.Configuration {
        guard let baseURL = validBaseURL(from: baseURLText) else { throw CalendarConnectionError.invalidURL }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedToken = trimmedToken.isEmpty ? CalendarCredentialVault.readToken() ?? "" : trimmedToken
        guard !resolvedToken.isEmpty else { throw CalendarConnectionError.missingToken }
        return .init(baseURL: baseURL, bearerToken: resolvedToken)
    }

    private func validBaseURL(from input: String) -> URL? {
        let trimmedURL = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let baseURL = URL(string: trimmedURL), let scheme = baseURL.scheme?.lowercased(), ["https", "http"].contains(scheme), baseURL.host != nil else { return nil }
        return baseURL
    }
}

private enum CalendarConnectionError: LocalizedError {
    case invalidURL
    case missingToken

    var errorDescription: String? {
        switch self {
        case .invalidURL: "请输入完整的 Calendar API 地址，例如 https://calendar.example.com。"
        case .missingToken: "请输入 Calendar API 访问令牌。"
        }
    }
}

private enum CalendarCredentialVault {
    private static let service = "com.ai0506.reminders.calendar-api"
    private static let account = "deadline-bearer-token"

    static func readToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var creation = query
            creation[kSecValueData as String] = data
            let createStatus = SecItemAdd(creation as CFDictionary, nil)
            guard createStatus == errSecSuccess else { throw CalendarCredentialError.unavailable }
        } else if status != errSecSuccess {
            throw CalendarCredentialError.unavailable
        }
    }

    static func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private enum CalendarCredentialError: LocalizedError {
    case unavailable
    var errorDescription: String? { "iPad 钥匙串无法保存此令牌。" }
}
