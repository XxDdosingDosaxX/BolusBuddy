import SwiftUI

@main
struct BolusBuddyWatchApp: App {
    @StateObject private var detector = EatingDetector.shared

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(detector)
        }
    }
}
