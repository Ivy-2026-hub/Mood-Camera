import SwiftUI

/// 产品骨架中由页面内按钮切换的两个一级页面。
enum AppTab: Hashable {
    case capture
    case gallery
}

/// 产品中从拍摄页可进入的二级页面路由。
enum CaptureRoute: Hashable {
    case card(UUID)
}

/// 产品的根页面，不使用底部标签栏，串起拍摄页、卡片页和照片墙。
struct RootView: View {
    @EnvironmentObject private var store: MoodEntryStore
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    let aiService: any AIService
    @State private var selectedTab: AppTab = .capture
    @State private var capturePath: [CaptureRoute] = []

    var body: some View {
        NavigationStack(path: $capturePath) {
            Group {
                switch selectedTab {
                case .capture:
                    CaptureView(
                        aiService: aiService,
                        openGallery: showGallery,
                        showCard: showCard
                    )
                case .gallery:
                    GalleryView(aiService: aiService, openCapture: showCapture)
                }
            }
            .navigationDestination(for: CaptureRoute.self) { route in
                switch route {
                case let .card(entryID):
                    if let entry = store.entries.first(where: { $0.id == entryID }) {
                        CardView(
                            entry: entry,
                            openGallery: showGallery,
                            playsDevelopmentAnimation: entry.cameraStyle == .polaroid
                        )
                    } else {
                        ContentUnavailableView("找不到这条记录", systemImage: "exclamationmark.triangle")
                    }
                }
            }
        }
        .task {
            await resumePendingEntries()
        }
        .onChange(of: networkMonitor.isConnected) { _, isConnected in
            guard isConnected else { return }
            Task {
                await resumePendingEntries()
            }
        }
    }

    private func showCapture() {
        capturePath.removeAll()
        selectedTab = .capture
    }

    private func showGallery() {
        capturePath.removeAll()
        selectedTab = .gallery
    }

    private func showCard(_ entry: MoodEntry) {
        capturePath.append(.card(entry.id))
    }

    @MainActor
    private func resumePendingEntries() async {
        let pendingIDs = store.entries
            .filter { $0.cardState == .pending }
            .map(\.id)

        await withTaskGroup(of: Void.self) { group in
            for entryID in pendingIDs {
                group.addTask { @MainActor in
                    await generateMoodCard(
                        entryID: entryID,
                        using: aiService,
                        store: store,
                        isNetworkConnected: networkMonitor.isConnected
                    )
                }
            }
        }
    }
}
