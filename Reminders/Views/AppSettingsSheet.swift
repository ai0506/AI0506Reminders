import SwiftUI

struct AppSettingsSheet: View {
    @Bindable var store: DeadlineStore
    @Bindable var connection: CalendarConnectionStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("deadline-alerts-enabled") private var alertsEnabled = false
    @State private var notificationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://calendar.example.com", text: $connection.baseURLText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField(connection.hasSavedToken ? "访问令牌（已安全保存）" : "访问令牌", text: $connection.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if store.isDemoMode {
                        Button(connection.isConnecting ? "正在连接…" : "连接 Calendar") {
                            Task { await connection.connect(store: store) }
                        }
                        .disabled(connection.isConnecting)
                    } else {
                        LabeledContent("状态") {
                            Label("已连接", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(RemindersTheme.success)
                        }
                        Button(connection.isConnecting ? "正在重新连接…" : "重新连接 Calendar") {
                            Task { await connection.connect(store: store) }
                        }
                        .disabled(connection.isConnecting)
                        Button("断开并使用演示工作区", role: .destructive) {
                            Task { await connection.disconnect(store: store) }
                        }
                    }

                    if let message = connection.connectionMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(store.isDemoMode ? RemindersTheme.danger : .secondary)
                    }
                } header: {
                    Text("Calendar 连接")
                } footer: {
                    Text("访问令牌只保存在 iPad 钥匙串中。本应用仅读取和写入 Calendar Deadline API，不会访问 Apple 日历或 Apple 提醒事项。")
                }

                Section("截止事项提醒") {
                    Toggle("在截止前通知我", isOn: $alertsEnabled)
                    Text("定时截止事项会在 15 分钟前提醒；全天事项在当天上午 9 点提醒。最近的 48 个事项会在本地排程。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let notificationMessage {
                        Text(notificationMessage)
                            .font(.footnote)
                            .foregroundStyle(RemindersTheme.danger)
                    }
                }
            }
            .reminderCanvas()
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onChange(of: alertsEnabled) { _, enabled in
                Task {
                    if enabled {
                        let granted = await DeadlineNotificationScheduler.shared.requestAuthorization()
                        if granted {
                            DeadlineNotificationScheduler.shared.scheduleIfPermitted(for: store.deadlines)
                            notificationMessage = nil
                        } else {
                            alertsEnabled = false
                            notificationMessage = "未获得通知权限。你可以稍后在 iPad 设置中开启。"
                        }
                    } else {
                        DeadlineNotificationScheduler.shared.removeAllDeadlineAlerts()
                        notificationMessage = nil
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
