import SwiftUI

/// 情绪卡片按当前情绪统一取用的一整套视觉：纸张、口令字、胶囊，
/// 以及卡片背面专用的渐变底、装饰符号和强调色。每种情绪一套辨识度分明的模板。
enum MoodPalette: String, CaseIterable {
    case sunny
    case calm
    case dusk
    case slate
    case rain
    case neutral

    static func isSupported(_ rawValue: String) -> Bool {
        Self(rawValue: rawValue) != nil
    }

    static func resolve(_ rawValue: String?) -> Self {
        guard let rawValue, let palette = Self(rawValue: rawValue) else {
            return .neutral
        }
        return palette
    }

    /// 情绪 → 配色映射。卡片配色跟着“当前情绪”走，所以用户在卡片上改了心情，
    /// 纸张、口令字、胶囊和背面模板会立刻跟着一起变。六种情绪各不相同。
    static func forEmotion(_ emotion: Emotion?) -> Self {
        guard let emotion else { return .neutral }
        switch emotion {
        case .happy: return .sunny
        case .calm: return .calm
        case .tired: return .dusk
        case .bored: return .slate
        case .sad: return .rain
        case .other: return .neutral
        }
    }

    /// 卡片正面纸张色：保持淡雅，让照片当主角。
    var paper: Color {
        switch self {
        case .sunny: color(from: "#FFF8E7")
        case .calm: color(from: "#F2F7F7")
        case .dusk: color(from: "#FBF0EE")
        case .slate: color(from: "#EFF2ED")
        case .rain: color(from: "#F1F2F6")
        case .neutral: color(from: "#FBFAF7")
        }
    }

    /// 口令字 / 强调色：足够深，压在渐变底上也清晰。
    var ink: Color {
        switch self {
        case .sunny: color(from: "#8A5410")
        case .calm: color(from: "#1F565C")
        case .dusk: color(from: "#8C3F55")
        case .slate: color(from: "#42513F")
        case .rain: color(from: "#33456A")
        case .neutral: color(from: "#5A4A38")
        }
    }

    var capsule: Color {
        switch self {
        case .sunny: color(from: "#FFDE97")
        case .calm: color(from: "#BFE2DE")
        case .dusk: color(from: "#F3C6D0")
        case .slate: color(from: "#CBD6C6")
        case .rain: color(from: "#C6D2E6")
        case .neutral: color(from: "#E6E4DF")
        }
    }

    // MARK: 卡片背面专用（比正面纸张更饱和、更有个性，翻过来一眼能区分）

    /// 背面渐变底：从上到下两个色，明显偏色，各情绪各不相同。
    var backGradient: [Color] {
        switch self {
        case .sunny: [color(from: "#FFEBB8"), color(from: "#F6C56A")]
        case .calm: [color(from: "#D4EEE8"), color(from: "#98D2C9")]
        case .dusk: [color(from: "#F7DADF"), color(from: "#D897AB")]
        case .slate: [color(from: "#DCE3D9"), color(from: "#A6B5A2")]
        case .rain: [color(from: "#D3DDEE"), color(from: "#93A6C6")]
        case .neutral: [color(from: "#F3EDE3"), color(from: "#D8CDBD")]
        }
    }

    /// 背面右上角的装饰符号（SF Symbol），点出这份情绪的气质。
    var motif: String {
        switch self {
        case .sunny: "sun.max.fill"
        case .calm: "leaf.fill"
        case .dusk: "moon.stars.fill"
        case .slate: "hourglass"
        case .rain: "cloud.rain.fill"
        case .neutral: "sparkles"
        }
    }

    /// 背面大幅水印装饰的淡描边色。
    var motifTint: Color {
        ink.opacity(0.14)
    }

    private func color(from hex: String) -> Color {
        let value = UInt64(hex.dropFirst(), radix: 16) ?? 0
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
