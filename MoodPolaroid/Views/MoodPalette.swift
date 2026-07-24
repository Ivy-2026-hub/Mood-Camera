import SwiftUI

/// 情绪卡片按模型 palette 统一取用的纸张、口令字和胶囊颜色。
enum MoodPalette: String, CaseIterable {
    case sunny
    case calm
    case dusk
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

    var paper: Color {
        switch self {
        case .sunny: color(from: "#FFF8E7")
        case .calm: color(from: "#F2F7F7")
        case .dusk: color(from: "#FBF0EE")
        case .rain: color(from: "#F1F2F6")
        case .neutral: color(from: "#FBFAF7")
        }
    }

    var ink: Color {
        switch self {
        case .sunny: color(from: "#B4761E")
        case .calm: color(from: "#3D6C72")
        case .dusk: color(from: "#A5566A")
        case .rain: color(from: "#4A5670")
        case .neutral: color(from: "#4A4A4A")
        }
    }

    var capsule: Color {
        switch self {
        case .sunny: color(from: "#FFE2A8")
        case .calm: color(from: "#CFE5E6")
        case .dusk: color(from: "#F5D3D8")
        case .rain: color(from: "#D6DAE6")
        case .neutral: color(from: "#E6E4DF")
        }
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
