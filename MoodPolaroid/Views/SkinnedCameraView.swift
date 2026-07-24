import SwiftUI
import UIKit

/// 调试皮肤自动热区时使用的总开关；打开后会显示红框与功能名。
let DEBUG_HOTSPOTS = false

/// 真机 A/B：默认交叉淡化；Scheme 加启动参数 `-flash-patch-slide` 即切到拨杆平移版。
private let FLASH_PATCH_ANIMATION_STYLE: FlashPatchAnimationStyle =
    ProcessInfo.processInfo.arguments.contains("-flash-patch-slide")
        ? .slide
        : .crossfade

/// 产品中闪光灯状态贴片可现场对比的两种反馈方式。
private enum FlashPatchAnimationStyle {
    case crossfade
    case slide
}

/// 产品中机身图片在相机槽中的实际尺寸与原点。
private struct CameraBodyLayout {
    let size: CGSize
    let origin: CGPoint
}

/// 产品中把流水线生成的皮肤配置渲染为可操作原生相机的通用三层视图。
struct SkinnedCameraView<PreviewPlaceholder: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let skin: CameraSkin
    let camera: CameraController
    let frozenImage: UIImage?
    let countdown: Int?
    let timerIsEnabled: Bool
    /// 当前设定的定时秒数，用于倒计时未开始时在 HUD 上显示"⏱ 3s"。
    let timerSeconds: Int
    let paperHintColor: Color?
    let actions: [CameraSkinControlFunction: () -> Void]
    let isControlEnabled: (CameraSkinControlFunction) -> Bool
    private let previewPlaceholder: () -> PreviewPlaceholder

    init(
        skin: CameraSkin,
        camera: CameraController,
        frozenImage: UIImage?,
        countdown: Int?,
        timerIsEnabled: Bool,
        timerSeconds: Int,
        paperHintColor: Color?,
        actions: [CameraSkinControlFunction: () -> Void],
        isControlEnabled: @escaping (CameraSkinControlFunction) -> Bool,
        @ViewBuilder previewPlaceholder: @escaping () -> PreviewPlaceholder
    ) {
        self.skin = skin
        self.camera = camera
        self.frozenImage = frozenImage
        self.countdown = countdown
        self.timerIsEnabled = timerIsEnabled
        self.timerSeconds = timerSeconds
        self.paperHintColor = paperHintColor
        self.actions = actions
        self.isControlEnabled = isControlEnabled
        self.previewPlaceholder = previewPlaceholder
    }

    var body: some View {
        GeometryReader { proxy in
            let bodyLayout = displayedBodyLayout(availableSize: proxy.size)
            let bodySize = bodyLayout.size
            let bodyOrigin = bodyLayout.origin
            let viewfinder = rect(
                x: skin.viewfinderRect.x,
                y: skin.viewfinderRect.y,
                width: skin.viewfinderRect.width,
                height: skin.viewfinderRect.height,
                bodyOrigin: bodyOrigin,
                bodySize: bodySize
            )
            let cornerRadius = skin.viewfinderRect.cornerRadiusWidth * bodySize.width

            ZStack(alignment: .topLeading) {
                // 底层：实时原生相机流，只占据配置中的透明取景框。
                previewLayer(
                    frame: viewfinder,
                    cornerRadius: cornerRadius
                )

                // 中层：裁掉背景后的机身 PNG，始终按实际显示宽度等比缩放。
                Image(skin.bodyImage)
                    .resizable()
                    .interpolation(.high)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: skin.bodyImage)
                    .frame(width: bodySize.width, height: bodySize.height)
                    .position(
                        x: bodyOrigin.x + bodySize.width / 2,
                        y: bodyOrigin.y + bodySize.height / 2
                    )
                    .allowsHitTesting(false)

                if let paperHintColor {
                    RoundedRectangle(
                        cornerRadius: cornerRadius,
                        style: .continuous
                    )
                    .stroke(paperHintColor.opacity(0.92), lineWidth: 2)
                    .frame(width: viewfinder.width, height: viewfinder.height)
                    .position(x: viewfinder.midX, y: viewfinder.midY)
                    .allowsHitTesting(false)
                }

                if DEBUG_HOTSPOTS {
                    RoundedRectangle(
                        cornerRadius: cornerRadius,
                        style: .continuous
                    )
                    .stroke(.red, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .overlay(alignment: .topLeading) {
                        Text("VIEWFINDER")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.red)
                            .offset(y: -18)
                    }
                    .frame(width: viewfinder.width, height: viewfinder.height)
                    .position(x: viewfinder.midX, y: viewfinder.midY)
                    .allowsHitTesting(false)
                }

                // 状态层：贴片严格使用和机身、热区相同的百分比坐标。
                ForEach(skin.controls) { control in
                    stateControlPatch(
                        control,
                        bodyOrigin: bodyOrigin,
                        bodySize: bodySize
                    )
                }

                // 顶层：百分比坐标相对机身图片，而不是屏幕或安全区。
                ForEach(skin.hotspots) { hotspot in
                    hotspotButton(
                        hotspot,
                        bodyOrigin: bodyOrigin,
                        bodySize: bodySize
                    )
                }

                viewfinderHUD(frame: viewfinder)

                if let countdown {
                    Text("\(countdown)")
                        .font(.system(size: 82, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.55), radius: 8, y: 4)
                        .position(x: viewfinder.midX, y: viewfinder.midY)
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(skin.displayName)相机")
    }

    private func displayedBodyLayout(
        availableSize: CGSize
    ) -> CameraBodyLayout {
        let sourceWidth = max(1, skin.pixelWidth)
        let sourceHeight = max(1, skin.pixelHeight)
        // 机身必须整台可见：一律 scaledToFit（取较小缩放比），不允许裁掉边缘按键。
        // 竖直方向多出来的空档由 canvasColor 衬底填满，与顶条/底条同色因此不可见。
        let scale = min(
            max(1, availableSize.width) / sourceWidth,
            max(1, availableSize.height) / sourceHeight
        )
        let originY = (
            availableSize.height - sourceHeight * scale
        ) / 2

        let size = CGSize(
            width: sourceWidth * scale,
            height: sourceHeight * scale
        )
        return CameraBodyLayout(
            size: size,
            origin: CGPoint(
                x: (availableSize.width - size.width) / 2,
                y: originY
            )
        )
    }

    private func rect(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        bodyOrigin: CGPoint,
        bodySize: CGSize
    ) -> CGRect {
        CGRect(
            x: bodyOrigin.x + x * bodySize.width,
            y: bodyOrigin.y + y * bodySize.height,
            width: width * bodySize.width,
            height: height * bodySize.height
        )
    }

    @ViewBuilder
    private func previewLayer(
        frame: CGRect,
        cornerRadius: CGFloat
    ) -> some View {
        ZStack {
            Color.black

            FilteredCameraPreview(
                camera: camera,
                parameters: skin.filter
            )
                .opacity(
                    camera.isReady
                        && frozenImage == nil
                        ? 1
                        : 0
                )

            if let frozenImage {
                Image(uiImage: frozenImage)
                    .resizable()
                    .scaledToFill()
            } else if !camera.isReady {
                previewPlaceholder()
            }

        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .position(x: frame.midX, y: frame.midY)
    }

    @ViewBuilder
    private func stateControlPatch(
        _ control: CameraSkinControl,
        bodyOrigin: CGPoint,
        bodySize: CGSize
    ) -> some View {
        let frame = rect(
            x: control.rect.x,
            y: control.rect.y,
            width: control.rect.width,
            height: control.rect.height,
            bodyOrigin: bodyOrigin,
            bodySize: bodySize
        )

        if control.role == .flash,
           let onPatch = control.statePatches["on"],
           let offPatch = control.statePatches["off"] {
            Group {
                if reduceMotion {
                    Image(camera.isFlashEnabled ? onPatch : offPatch)
                        .resizable()
                        .interpolation(.high)
                } else {
                    ZStack {
                        Image(offPatch)
                            .resizable()
                            .interpolation(.high)
                            .opacity(camera.isFlashEnabled ? 0 : 1)
                            .offset(
                                x: FLASH_PATCH_ANIMATION_STYLE == .slide
                                    && camera.isFlashEnabled
                                    ? frame.width * 0.12
                                    : 0
                            )

                        Image(onPatch)
                            .resizable()
                            .interpolation(.high)
                            .opacity(camera.isFlashEnabled ? 1 : 0)
                            .offset(
                                x: FLASH_PATCH_ANIMATION_STYLE == .slide
                                    && !camera.isFlashEnabled
                                    ? -frame.width * 0.12
                                    : 0
                            )
                    }
                    .animation(
                        .easeInOut(duration: 0.15),
                        value: camera.isFlashEnabled
                    )
                }
            }
            .frame(width: frame.width, height: frame.height)
            .clipped()
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func viewfinderHUD(frame: CGRect) -> some View {
        if camera.isFlashEnabled || timerIsEnabled {
            HStack(spacing: 6) {
                if camera.isFlashEnabled {
                    statusHUDIcon(systemName: "bolt.fill")
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }

                if timerIsEnabled {
                    // 倒计时中显示实时剩余秒数，平时显示设定值，光看图标看不出设了几秒。
                    HStack(spacing: 3) {
                        statusHUDIcon(systemName: "timer")
                        Text("\(countdown ?? timerSeconds)s")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(.black.opacity(0.42), in: Capsule())
            .frame(
                width: max(0, frame.width - 16),
                alignment: .trailing
            )
            .position(
                x: frame.midX,
                y: frame.minY + 18
            )
            .animation(
                reduceMotion
                    ? nil
                    : .spring(response: 0.28, dampingFraction: 0.58),
                value: camera.isFlashEnabled
            )
            .animation(
                reduceMotion
                    ? nil
                    : .spring(response: 0.28, dampingFraction: 0.58),
                value: timerIsEnabled
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func statusHUDIcon(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .black, design: .rounded))
            .foregroundStyle(Color(red: 1, green: 0.94, blue: 0.68))
            .rotationEffect(.degrees(systemName == "bolt.fill" ? -7 : 4))
            .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
    }

    private func hotspotButton(
        _ hotspot: CameraSkinHotspot,
        bodyOrigin: CGPoint,
        bodySize: CGSize
    ) -> some View {
        let frame = rect(
            x: hotspot.centerX - hotspot.width / 2,
            y: hotspot.centerY - hotspot.height / 2,
            width: hotspot.width,
            height: hotspot.height,
            bodyOrigin: bodyOrigin,
            bodySize: bodySize
        )

        return Button {
            UIImpactFeedbackGenerator(
                style: hotspot.function == .flash ? .rigid : .light
            )
            .impactOccurred()
            actions[hotspot.function]?()
        } label: {
            ZStack {
                Color.clear

                if DEBUG_HOTSPOTS {
                    Rectangle()
                        .fill(.red.opacity(0.12))
                        .overlay {
                            Rectangle()
                                .stroke(.red, lineWidth: 1.5)
                        }
                    Text(hotspot.function.rawValue)
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundStyle(.red)
                }
            }
            .contentShape(Rectangle())
            .frame(width: frame.width, height: frame.height)
        }
        .buttonStyle(
            RuntimeCropHotspotButtonStyle(
                bodyImage: skin.bodyImage,
                bodySize: bodySize,
                bodyCenterOffset: CGSize(
                    width: bodyOrigin.x + bodySize.width / 2 - frame.midX,
                    height: bodyOrigin.y + bodySize.height / 2 - frame.midY
                )
            )
        )
        .disabled(!isControlEnabled(hotspot.function))
        .opacity(isControlEnabled(hotspot.function) ? 1 : 0.42)
        .position(x: frame.midX, y: frame.midY)
        .accessibilityLabel(accessibilityLabel(for: hotspot.function))
    }

    private func accessibilityLabel(
        for function: CameraSkinControlFunction
    ) -> String {
        switch function {
        case .shutter: countdown == nil ? "拍照" : "取消倒计时"
        case .album: "打开照片收藏"
        case .flip: "切换前后摄像头"
        case .flash: camera.isFlashEnabled ? "关闭闪光灯" : "打开闪光灯"
        case .timer: "选择定时拍摄"
        case .zoom: "切换焦段"
        case .drawer: "打开相机与相纸选择"
        }
    }
}

/// 产品中模拟实体按键按下与弹起手感的透明热区按钮样式。
private struct RuntimeCropHotspotButtonStyle: ButtonStyle {
    let bodyImage: String
    let bodySize: CGSize
    let bodyCenterOffset: CGSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                if configuration.isPressed {
                    Image(bodyImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: bodySize.width, height: bodySize.height)
                        .offset(
                            x: bodyCenterOffset.width,
                            y: bodyCenterOffset.height
                        )
                        .brightness(-0.08)
                        .allowsHitTesting(false)
                }
            }
            .clipped()
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(
                .spring(response: 0.23, dampingFraction: 0.62),
                value: configuration.isPressed
            )
    }
}
