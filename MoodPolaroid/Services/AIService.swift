import Foundation
import Network

/// 产品中一次情绪卡片生成返回的情绪判断与一句话总结。
struct AIResult: Sendable {
    let emotion: Emotion
    let summary: String
    let moodCode: String
    let encouragement: String
    let psychologyNote: String
    let palette: String
}

/// 产品中生成情绪卡片内容的抽象接口，页面与存储不依赖具体模型供应商。
protocol AIService: Sendable {
    var requiresNetwork: Bool { get }
    func generate(for entry: MoodEntry) async throws -> AIResult
}

extension AIService {
    var requiresNetwork: Bool { true }
}

/// 产品中真实 AI 服务可抛出的可恢复网络错误与不可恢复生成错误。
enum AIServiceError: Error {
    case networkUnavailable
    case generationFailed
}

/// 产品当前用于跑通生成链路的本地假 AI；它不会联网，也不会调用任何模型。
struct DummyAIService: AIService {
    let requiresNetwork = false

    func generate(for entry: MoodEntry) async throws -> AIResult {
        try await Task.sleep(for: .seconds(1.5))
        return AIResult(
            emotion: .calm,
            summary: "今天的光看起来很温柔",
            moodCode: "靠窗的一小块太阳",
            encouragement: "把这点亮光带在身上再走一会儿",
            psychologyNote: "具身认知会让明亮的环境轻轻托住当下的心情",
            palette: "sunny"
        )
    }
}

/// 产品中持续观察网络状态，并在网络恢复时触发待生成记录重试。
@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isConnected = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "MoodPolaroid.network.monitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

/// 产品中唯一的情绪生成入口：开始请求前无网络时保留待生成；请求开始后的所有错误均标记失败。
@MainActor
func generateMoodCard(
    entryID: MoodEntry.ID,
    using service: any AIService,
    store: MoodEntryStore,
    isNetworkConnected: Bool
) async {
    guard store.beginGeneration(id: entryID) else { return }
    defer { store.endGeneration(id: entryID) }

    guard !service.requiresNetwork || isNetworkConnected else {
        return
    }
    guard let entry = store.entries.first(where: { $0.id == entryID }),
          entry.cardState == .pending else { return }

    do {
        let result = try await service.generate(for: entry)
        guard var latestEntry = store.entries.first(where: { $0.id == entryID }) else { return }
        latestEntry.aiEmotion = result.emotion
        latestEntry.aiSummary = result.summary
        latestEntry.moodCode = result.moodCode
        latestEntry.encouragement = result.encouragement
        latestEntry.psychologyNote = result.psychologyNote
        latestEntry.palette = result.palette
        latestEntry.cardState = .generated
        store.update(latestEntry)
    } catch {
        guard var latestEntry = store.entries.first(where: { $0.id == entryID }) else { return }
        latestEntry.cardState = .failed
        store.update(latestEntry)
    }
}
