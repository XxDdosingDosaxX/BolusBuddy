import SwiftUI
import UserNotifications

@main
struct BolusBuddyApp: App {
    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    var body: some Scene {
        WindowGroup {
            PhoneContentView()
        }
    }
}
