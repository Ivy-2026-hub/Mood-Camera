import SwiftUI

/// MoodPolaroid 的应用入口，负责创建并向页面注入本地 Store。
@main
struct MoodPolaroidApp: App {
    @StateObject private var store = MoodEntryStore()
    @StateObject private var networkMonitor = NetworkMonitor()

    var body: some Scene {
        WindowGroup {
            RootView(aiService: QwenVisionService())
                .environmentObject(store)
                .environmentObject(networkMonitor)
        }
    }
}
