import Foundation

/// 产品中一条情绪照片记录可选择的拍摄风格。
enum CameraStyle: String, Codable, CaseIterable, Identifiable {
    case original
    case polaroid
    case ccd

    var id: Self { self }

    var displayName: String {
        switch self {
        case .original: "原相机"
        case .polaroid: "拍立得"
        case .ccd: "CCD"
        }
    }
}

/// 产品中用户或 AI 可为一条记录标注的情绪类别。
enum Emotion: String, Codable, CaseIterable, Identifiable {
    case happy
    case calm
    case tired
    case sad
    case other

    var id: Self { self }

    var displayName: String {
        switch self {
        case .happy: "开心"
        case .calm: "平静"
        case .tired: "疲惫"
        case .sad: "难过"
        case .other: "其他"
        }
    }
}

/// 产品中情绪卡片从等待生成到成功或失败的状态。
enum CardState: String, Codable, CaseIterable, Identifiable {
    case pending
    case generated
    case failed

    var id: Self { self }

    var displayName: String {
        switch self {
        case .pending: "待生成"
        case .generated: "已生成"
        case .failed: "生成失败"
        }
    }
}

/// 产品中一次拍摄与情绪卡片所共享的完整本地记录。
struct MoodEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let createdAt: Date
    var imageFileName: String
    var cameraStyle: CameraStyle
    var cameraSkinID: String?
    var paperID: String?
    var note: String?
    var userEmotion: Emotion?
    var aiEmotion: Emotion?
    var aiSummary: String?
    var cardState: CardState
    var wallPositionX: Double?
    var wallPositionY: Double?
    var wallRotation: Double?
    var wallZIndex: Double?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        imageFileName: String,
        cameraStyle: CameraStyle,
        cameraSkinID: String? = nil,
        paperID: String? = nil,
        note: String? = nil,
        userEmotion: Emotion? = nil,
        aiEmotion: Emotion? = nil,
        aiSummary: String? = nil,
        cardState: CardState = .pending,
        wallPositionX: Double? = nil,
        wallPositionY: Double? = nil,
        wallRotation: Double? = nil,
        wallZIndex: Double? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.imageFileName = imageFileName
        self.cameraStyle = cameraStyle
        self.cameraSkinID = cameraSkinID
        self.paperID = paperID
        self.note = note
        self.userEmotion = userEmotion
        self.aiEmotion = aiEmotion
        self.aiSummary = aiSummary
        self.cardState = cardState
        self.wallPositionX = wallPositionX
        self.wallPositionY = wallPositionY
        self.wallRotation = wallRotation
        self.wallZIndex = wallZIndex
    }
}
