// 此文件由 add_camera.py 自动生成；请勿手改。
import SwiftUI

/// 产品中生成皮肤热区允许触发的相机功能。
enum CameraSkinControlFunction: String, CaseIterable {
    case shutter
    case album
    case flip
    case flash
    case timer
    case zoom
    case drawer
}

/// 产品中生成皮肤上的一个百分比点击热区。
struct CameraSkinHotspot: Identifiable {
    let id: String
    let function: CameraSkinControlFunction
    let centerX: CGFloat
    let centerY: CGFloat
    let width: CGFloat
    let height: CGFloat
}

/// 产品中皮肤状态控件支持的交互类型。
enum CameraSkinControlType: String {
    case toggle
}

/// 产品中状态贴片相对整张机身图的百分比矩形。
struct CameraSkinControlRect {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}

/// 产品中会随功能状态更换贴片的实体控件。
struct CameraSkinControl: Identifiable {
    let id: String
    let role: CameraSkinControlFunction
    let type: CameraSkinControlType
    let rect: CameraSkinControlRect
    let statePatches: [String: String]
}

/// 产品中生成皮肤自动检测出的透明取景框。
struct CameraSkinViewfinderRect {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let cornerRadiusWidth: CGFloat
}

/// 产品中一套 CameraSkin 的 Core Image 调色参数，实时预览与成片共用。
struct CameraSkinFilterParameters {
    /// CIColorControls 饱和度；建议 0...2，1 为原图。
    let saturation: Double
    /// CIColorControls 对比度；建议 0.5...1.5，1 为原图。
    let contrast: Double
    /// CIColorControls 亮度；建议 -0.2...0.2，0 为原图。
    let brightness: Double
    /// CITemperatureAndTint 色温偏移；建议 -2000...2000 K，正值偏暖。
    let temperatureShift: Double
    /// CIColorMatrix 褪色量；建议 0...0.25，0 为关闭。
    let fade: Double
    /// CIVignette 暗角强度；建议 0...2，0 为关闭。
    let vignetteIntensity: Double
    /// CIVignette 暗角半径；Core Image 合理范围 0...2。
    let vignetteRadius: Double
    /// CIRandomGenerator 颗粒混合强度；建议 0...0.15，0 为关闭。
    let grainIntensity: Double
    /// 颗粒尺寸倍率；建议 0.5...3。
    let grainSize: Double
    /// CIBloom 高光溢出强度；建议 0...1，0 为关闭。
    let bloomIntensity: Double
    /// CIBloom 半径占短边比例；建议 0...0.05。
    let bloomRadiusFraction: Double
}

/// 产品中一套相机皮肤可提供的相纸选项。
struct CameraSkinPaper: Identifiable {
    let id: String
    let displayName: String
    let colorHex: String
    /// 相框叠加图（PNG，中间照片窗口透明）的 Assets 资源名。
    /// 为空时用 colorHex 的纯色边；非空时把这张框叠在照片四周（Ivy 的 SVG 相框转成的 PNG）。
    var frameImage: String? = nil

    init(id: String, displayName: String, colorHex: String, frameImage: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.colorHex = colorHex
        self.frameImage = frameImage
    }
}

/// 产品中一套可直接显示并响应实体按键的完整相机皮肤。
struct CameraSkin: Identifiable {
    let id: String
    let displayName: String
    let thumbnailImage: String
    let bodyImage: String
    let pixelWidth: CGFloat
    let pixelHeight: CGFloat
    /// 顶条、机身槽、底条和抽屉共用的无缝画布色。
    let canvasColor: Color
    let viewfinderRect: CameraSkinViewfinderRect
    let hotspots: [CameraSkinHotspot]
    let controls: [CameraSkinControl]
    let filter: CameraSkinFilterParameters
    let papers: [CameraSkinPaper]
}

/// 产品中由 add_camera.py 重建的全部生成相机皮肤注册表。
enum CameraSkins {
    static let all: [CameraSkin] = [
        CameraSkin(
            id: "ccd",
            displayName: "CCD",
            thumbnailImage: "skin_ccd_body",
            bodyImage: "skin_ccd_body",
            pixelWidth: 910,
            pixelHeight: 1377,
            canvasColor: Color(red: 0.956863, green: 0.956863, blue: 0.956863),
            viewfinderRect: CameraSkinViewfinderRect(
                x: 0.1687033,
                y: 0.073069,
                width: 0.4782857,
                height: 0.4726449,
                cornerRadiusWidth: 0.0154286
            ),
            hotspots: [
                CameraSkinHotspot(
                    id: "ccd.shutter.0",
                    function: .shutter,
                    centerX: 0.3787692,
                    centerY: 0.7635323,
                    width: 0.1756484,
                    height: 0.1163108
                ),
                CameraSkinHotspot(
                    id: "ccd.zoom.1",
                    function: .zoom,
                    centerX: 0.3787692,
                    centerY: 0.6525084,
                    width: 0.1103736,
                    height: 0.065557
                ),
                CameraSkinHotspot(
                    id: "ccd.timer.2",
                    function: .timer,
                    centerX: 0.2126154,
                    centerY: 0.7635323,
                    width: 0.1044396,
                    height: 0.0687291
                ),
                CameraSkinHotspot(
                    id: "ccd.flip.3",
                    function: .flip,
                    centerX: 0.5449231,
                    centerY: 0.7635323,
                    width: 0.1044396,
                    height: 0.0687291
                ),
                CameraSkinHotspot(
                    id: "ccd.flash.4",
                    function: .flash,
                    centerX: 0.3787692,
                    centerY: 0.8724415,
                    width: 0.1044396,
                    height: 0.0687291
                ),
                CameraSkinHotspot(
                    id: "ccd.album.5",
                    function: .album,
                    centerX: 0.595956,
                    centerY: 0.68,
                    width: 0.1424176,
                    height: 0.094106
                ),
            ],
            controls: [
            ],
            filter: CameraSkinFilterParameters(
                saturation: 1.24,
                contrast: 1.08,
                brightness: 0.012,
                temperatureShift: -520.0,
                fade: 0.0,
                vignetteIntensity: 0.0,
                vignetteRadius: 1.0,
                grainIntensity: 0.085,
                grainSize: 1.2,
                bloomIntensity: 0.28,
                bloomRadiusFraction: 0.018
            ),
            papers: [
            ]
        ),
        CameraSkin(
            id: "mood_camera",
            displayName: "Mood 手绘",
            thumbnailImage: "thumb_mood_camera",
            bodyImage: "skin_mood_camera_body",
            pixelWidth: 828,
            pixelHeight: 1388,
            canvasColor: Color(red: 0.956863, green: 0.956863, blue: 0.956863),
            viewfinderRect: CameraSkinViewfinderRect(
                x: 0.155,
                y: 0.128,
                width: 0.696,
                height: 0.437,
                cornerRadiusWidth: 0.019
            ),
            hotspots: [
                CameraSkinHotspot(
                    id: "mood_camera.shutter.0",
                    function: .shutter,
                    centerX: 0.501,
                    centerY: 0.842,
                    width: 0.326,
                    height: 0.195
                ),
                CameraSkinHotspot(
                    id: "mood_camera.timer.1",
                    function: .timer,
                    centerX: 0.103,
                    centerY: 0.685,
                    width: 0.109,
                    height: 0.065
                ),
                CameraSkinHotspot(
                    id: "mood_camera.album.2",
                    function: .album,
                    centerX: 0.156,
                    centerY: 0.839,
                    width: 0.145,
                    height: 0.086
                ),
                CameraSkinHotspot(
                    id: "mood_camera.flip.3",
                    function: .flip,
                    centerX: 0.864,
                    centerY: 0.841,
                    width: 0.145,
                    height: 0.086
                ),
                CameraSkinHotspot(
                    id: "mood_camera.flash.4",
                    function: .flash,
                    centerX: 0.878,
                    centerY: 0.696,
                    width: 0.157,
                    height: 0.058
                ),
            ],
            controls: [
                CameraSkinControl(
                    id: "mood_camera.flash.state.0",
                    role: .flash,
                    type: .toggle,
                    rect: CameraSkinControlRect(
                        x: 0.781,
                        y: 0.666,
                        width: 0.182,
                        height: 0.053
                    ),
                    statePatches: ["off": "patch_mood_flash_off", "on": "patch_mood_flash_on"]
                ),
            ],
            filter: CameraSkinFilterParameters(
                saturation: 0.9,
                contrast: 0.88,
                brightness: 0.018,
                temperatureShift: 680.0,
                fade: 0.12,
                vignetteIntensity: 0.58,
                vignetteRadius: 1.12,
                grainIntensity: 0.018,
                grainSize: 1.0,
                bloomIntensity: 0.04,
                bloomRadiusFraction: 0.006
            ),
            papers: [
                CameraSkinPaper(
                    id: "classic",
                    displayName: "经典白",
                    colorHex: "#FFFFFF",
                    frameImage: "frame_classic"
                ),
                CameraSkinPaper(
                    id: "pink",
                    displayName: "粉",
                    colorHex: "#F7A8C6"
                ),
                CameraSkinPaper(
                    id: "lemon",
                    displayName: "柠檬黄",
                    colorHex: "#FCE147"
                ),
            ]
        ),
        CameraSkin(
            id: "polaroid",
            displayName: "拍立得",
            thumbnailImage: "skin_polaroid_body",
            bodyImage: "skin_polaroid_body",
            pixelWidth: 814,
            pixelHeight: 1377,
            canvasColor: Color(red: 0.956863, green: 0.956863, blue: 0.956863),
            viewfinderRect: CameraSkinViewfinderRect(
                x: 0.1498771,
                y: 0.1263617,
                width: 0.7039312,
                height: 0.4400871,
                cornerRadiusWidth: 0.014742
            ),
            hotspots: [
                CameraSkinHotspot(
                    id: "polaroid.album.0",
                    function: .album,
                    centerX: 0.1418851,
                    centerY: 0.8372764,
                    width: 0.1571867,
                    height: 0.0964183
                ),
                CameraSkinHotspot(
                    id: "polaroid.shutter.1",
                    function: .shutter,
                    centerX: 0.5042529,
                    centerY: 0.8518731,
                    width: 0.3248526,
                    height: 0.1928366
                ),
                CameraSkinHotspot(
                    id: "polaroid.flip.2",
                    function: .flip,
                    centerX: 0.8654681,
                    centerY: 0.8372764,
                    width: 0.1571867,
                    height: 0.0964183
                ),
                CameraSkinHotspot(
                    id: "polaroid.flash.3",
                    function: .flash,
                    centerX: 0.8918919,
                    centerY: 0.6971678,
                    width: 0.1498771,
                    height: 0.0551924
                ),
                CameraSkinHotspot(
                    id: "polaroid.timer.4",
                    function: .timer,
                    centerX: 0.0909091,
                    centerY: 0.6928105,
                    width: 0.1179361,
                    height: 0.0653595
                ),
            ],
            controls: [
            ],
            filter: CameraSkinFilterParameters(
                saturation: 0.94,
                contrast: 0.92,
                brightness: 0.012,
                temperatureShift: 420.0,
                fade: 0.075,
                vignetteIntensity: 0.42,
                vignetteRadius: 1.18,
                grainIntensity: 0.0,
                grainSize: 1.0,
                bloomIntensity: 0.0,
                bloomRadiusFraction: 0.0
            ),
            papers: [
                CameraSkinPaper(
                    id: "classic",
                    displayName: "经典白",
                    colorHex: "#FFFFFF",
                    frameImage: "frame_classic"
                ),
                CameraSkinPaper(
                    id: "barbie",
                    displayName: "芭比粉",
                    colorHex: "#F573B3"
                ),
                CameraSkinPaper(
                    id: "lemon",
                    displayName: "柠檬黄",
                    colorHex: "#FCE147"
                ),
                CameraSkinPaper(
                    id: "sky",
                    displayName: "晴空蓝",
                    colorHex: "#66E8FA"
                ),
                CameraSkinPaper(
                    id: "noir",
                    displayName: "夜幕黑",
                    colorHex: "#1C1A17"
                ),
            ]
        ),
    ]

    static func named(_ name: String?) -> CameraSkin? {
        guard let name else { return nil }
        return all.first { $0.id == name }
    }
}
