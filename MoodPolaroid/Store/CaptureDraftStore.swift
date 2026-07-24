import Foundation

/// 产品中一张“已拍下但用户尚未确认保存”的照片。
///
/// 它的照片文件已经落盘（复用 PhotoFileStore），但没有进入 MoodEntryStore，
/// 因此不会出现在图钉墙、相簿或任何相册入口里。只有用户在编辑页点“保存到相册”，
/// 它才会被转成正式的 MoodEntry；点“重拍/返回放弃”则连同照片文件一起删除。
struct CaptureDraft: Codable, Equatable {
    let id: UUID
    let createdAt: Date
    let imageFileName: String
    let cameraStyle: CameraStyle
    let cameraSkinID: String?
    let paperID: String?
    /// 用户在编辑页已经写下的内容，随输入实时回写，App 被杀也不丢。
    var note: String
    var userEmotion: Emotion?
}

/// 产品中暂存草稿的持久化入口：只保存一条，拍新的会覆盖旧的。
///
/// 存在的唯一理由是防止丢照片——用户拍完还没保存时如果 App 被系统杀掉、
/// 来电打断或误触返回，下次启动要能回到编辑页继续填，而不是静默丢失这一刻。
struct CaptureDraftStore {
    private let fileName = "capture_draft.json"

    private var fileURL: URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent(fileName)
    }

    func load() -> CaptureDraft? {
        guard let fileURL,
              FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CaptureDraft.self, from: data)
    }

    @discardableResult
    func save(_ draft: CaptureDraft) -> Bool {
        guard let fileURL else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(draft) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
