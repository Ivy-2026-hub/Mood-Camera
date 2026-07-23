import SwiftUI

/// MoodPolaroid 的应用入口，负责创建并向页面注入本地 Store。
@main
struct MoodPolaroidApp: App {
    @StateObject private var store = MoodEntryStore()
    @StateObject private var networkMonitor = NetworkMonitor()

    var body: some Scene {
        WindowGroup {
            // Day 5 在这里替换成真实模型：把 DummyAIService() 改成真实 AIService 实现。
            RootView(aiService: DummyAIService())
                .environmentObject(store)
                .environmentObject(networkMonitor)
        }
    }
}
