import SwiftUI

@main
struct AI0506RemindersApp: App {
    @UIApplicationDelegateAdaptor(RemindersAppDelegate.self) private var appDelegate
    @State private var store = DeadlineStore(repository: MockDeadlineRepository())
    @State private var connection = CalendarConnectionStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, connection: connection)
                .preferredColorScheme(nil)
                .task {
                    guard let configuration = connection.savedConfiguration else { return }
                    await store.restoreConnection(configuration)
                }
                .onOpenURL { url in
                    store.open(url: url)
                }
                .onReceive(NotificationCenter.default.publisher(for: .openDeadlineRoute)) { notification in
                    guard let deadlineID = notification.object as? String else { return }
                    store.open(deadlineID: deadlineID)
                }
        }
    }
}
