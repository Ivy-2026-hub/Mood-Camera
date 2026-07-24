import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

/// 产品中拍立得模式可选择的相纸颜色；当前只影响拍摄页的选择标记。
private enum PolaroidPaperStyle: String, CaseIterable, Identifiable {
    case classic
    case barbie
    case lemon
    case sky
    case noir

    var id: Self { self }

    var displayName: String {
        switch self {
        case .classic: "经典白"
        case .barbie: "芭比粉"
        case .lemon: "柠檬黄"
        case .sky: "晴空蓝"
        case .noir: "夜幕黑"
        }
    }

    var color: Color {
        switch self {
        case .classic: .white
        case .barbie: Color(red: 0.96, green: 0.45, blue: 0.70)
        case .lemon: Color(red: 0.99, green: 0.88, blue: 0.28)
        case .sky: Color(red: 0.40, green: 0.91, blue: 0.98)
        case .noir: Color(red: 0.11, green: 0.10, blue: 0.09)
        }
    }
}

/// 产品中拍立得模式可选择的滤镜标记；当前不会修改照片像素。
private enum PolaroidFilterStyle: String, CaseIterable, Identifiable {
    case natural
    case warm
    case dreamy
    case retro
    case noir

    var id: Self { self }

    var displayName: String {
        switch self {
        case .natural: "自然"
        case .warm: "暖调"
        case .dreamy: "梦幻"
        case .retro: "复古"
        case .noir: "黑白"
        }
    }
}

/// 产品中快门可选择的关闭、5 秒和 10 秒自拍倒计时。
private enum CaptureTimerOption: Int, CaseIterable, Identifiable {
    case off = 0
    case fiveSeconds = 5
    case tenSeconds = 10

    var id: Self { self }

    var displayName: String {
        switch self {
        case .off: "关闭"
        case .fiveSeconds: "5 秒"
        case .tenSeconds: "10 秒"
        }
    }

    var compactName: String {
        switch self {
        case .off: "OFF"
        case .fiveSeconds: "5s"
        case .tenSeconds: "10s"
        }
    }
}

/// 产品中相机选择抽屉从关闭、选择相机到选择相纸的三个明确状态。
private enum CameraDrawerState: Equatable {
    case closed
    case cameraSelect
    case paperSelect
}

/// 产品中一体机竖柱各段的集中布局尺寸。
private enum LayoutConstants {
    /// T：不含顶部安全区的标题栏高度。
    static let topBarHeight: CGFloat = 80
    /// B：不含底部安全区的功能栏高度。
    static let bottomBarHeight: CGFloat = 100
    /// H1：相机选择行高度。
    static let cameraRowHeight: CGFloat = 170
    /// H2：相纸选择行高度。
    static let paperRowHeight: CGFloat = 130
}

/// 产品中机械抽屉唯一允许使用的归位动效参数。
private enum MotionConstants {
    static let drawerDuration: Double = 0.30
    static let drawerCurve = Animation.easeInOut(duration: drawerDuration)
}

/// 产品中不作用于抽屉位移的视觉切换时长。
private enum TransitionConstants {
    static let skinCrossfadeDuration: Double = 0.25
    static let reducedMotionFadeDuration: Double = 0.14
}

/// 产品中读取整根相机竖柱动画实际位置的偏好值。
private struct DrawerPresentationOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 产品中随原相机、拍立得和 CCD 模式一起变化的整套机身视觉参数。
private struct BuiltInCameraAppearance {
    let modelName: String
    let bodyColors: [Color]
    let accentColor: Color
    let labelColor: Color
    let lensFrameColor: Color
    let bodyCornerRadius: CGFloat
    let viewfinderSize: CGSize
    let viewfinderCornerRadius: CGFloat
    let hasPrinterSlot: Bool
}

/// 产品中的原生相机主页，主画面只保留取景机身、快门和照片墙入口。
struct CaptureView: View {
    @EnvironmentObject private var store: MoodEntryStore
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let aiService: any AIService
    let openGallery: () -> Void
    let showCard: (MoodEntry) -> Void

    @AppStorage("polaroidDateStyle") private var dateStyleRawValue = PolaroidDateStyle.localized.rawValue
    @AppStorage("polaroidDateFontStyle") private var dateFontStyleRawValue = PolaroidDateFontStyle.monospaced.rawValue

    @StateObject private var camera = CameraController()
    @State private var selectedCameraStyle: CameraStyle = .polaroid
    @State private var selectedPaperStyle: PolaroidPaperStyle = .classic
    @State private var selectedFilterStyle: PolaroidFilterStyle = .natural
    @State private var selectedTimer: CaptureTimerOption = .off
    @State private var permissionPhotoItem: PhotosPickerItem?
    @State private var frozenImage: UIImage?
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var isProcessing = false
    @State private var isShowingSettings = false
    @State private var isShowingTimerPicker = false
    @State private var drawerState: CameraDrawerState = .closed
    @State private var drawerOffset: CGFloat = 0
    @State private var drawerPresentationOffset: CGFloat = 0
    @State private var drawerDragStartOffset: CGFloat = 0
    @State private var isDraggingDrawer = false
    @State private var drawerContentOpacity: Double = 0
    @AppStorage("selectedCameraSkinID") private var selectedSkinID = "mood_camera"
    @AppStorage("selectedCameraPaperID") private var selectedSkinPaperID = "classic"
    @State private var isShowingScreenFlash = false
    @State private var brightnessBeforeScreenFlash: CGFloat?
    @State private var screenFlashTask: Task<Void, Never>?
    @State private var captureStyleSnapshot: CameraStyle?
    @State private var captureSkinIDSnapshot: String?
    @State private var capturePaperIDSnapshot: String?
    @State private var captureFilterSnapshot: CameraSkinFilterParameters?
    @State private var alertMessage: String?

    // MARK: 暂存流程（拍完先编辑，用户确认才入库）
    /// 已拍下但尚未确认保存的照片；非空时展示编辑页。
    @State private var pendingDraft: CaptureDraft?
    @State private var pendingImage: UIImage?
    @State private var draftNote = ""
    @State private var draftEmotion: Emotion?
    /// 用户是否手动改过情绪；改过之后 AI 结果不再覆盖他的选择。
    @State private var draftEmotionTouchedByUser = false
    /// 后台生成的结果：拍完立刻开始，用户填字的同时它在路上。
    @State private var draftAIResult: AIResult?
    @State private var draftAIDidFail = false
    @State private var draftAITask: Task<Void, Never>?
    @State private var isShowingDiscardConfirm = false

    private let photoFileStore = PhotoFileStore()
    private let draftStore = CaptureDraftStore()

    /// 读取真实窗口安全区；即使根视图边到边渲染，也不会让标题撞上刘海或灵动岛。
    private var activeWindowSafeAreaInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets ?? .zero
    }

    var body: some View {
        GeometryReader { proxy in
            let windowInsets = activeWindowSafeAreaInsets
            let safeAreaTop = max(
                proxy.safeAreaInsets.top,
                windowInsets.top
            )
            let safeAreaBottom = max(
                proxy.safeAreaInsets.bottom,
                windowInsets.bottom
            )
            let topHeight = LayoutConstants.topBarHeight
                + safeAreaTop
            let bottomHeight = LayoutConstants.bottomBarHeight
                + safeAreaBottom
            let cameraHeight = max(
                320,
                proxy.size.height - topHeight - bottomHeight
            )

            ZStack(alignment: .top) {
                activeCanvasColor
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    integratedTopBar(safeAreaTop: safeAreaTop)
                        .frame(height: topHeight)
                        .background(activeCanvasColor)

                    cameraBody(height: cameraHeight)
                        .frame(
                            width: proxy.size.width,
                            height: cameraHeight
                        )
                        .background(activeCanvasColor)
                        .clipped()

                    integratedBottomBar(
                        safeAreaBottom: safeAreaBottom
                    )
                    .frame(height: bottomHeight)
                    .background(activeCanvasColor)
                    .shadow(color: .black.opacity(0.16), radius: 4, y: 4)
                    .zIndex(2)

                    cameraSelectionDrawerRow
                        .frame(height: LayoutConstants.cameraRowHeight)
                        .opacity(drawerRowsOpacity)

                    paperSelectionDrawerRow
                        .frame(height: LayoutConstants.paperRowHeight)
                        .opacity(drawerRowsOpacity)
                }
                .frame(width: proxy.size.width, alignment: .top)
                .background {
                    GeometryReader { columnProxy in
                        Color.clear.preference(
                            key: DrawerPresentationOffsetKey.self,
                            value: max(
                                0,
                                -columnProxy.frame(
                                    in: .named("cameraDrawerViewport")
                                ).minY
                            )
                        )
                    }
                }
                .offset(y: -drawerOffset)
                .simultaneousGesture(drawerGesture)
            }
            .coordinateSpace(name: "cameraDrawerViewport")
            .onPreferenceChange(DrawerPresentationOffsetKey.self) { value in
                drawerPresentationOffset = clampedDrawerOffset(value)
            }
            .frame(
                width: proxy.size.width,
                height: proxy.size.height,
                alignment: .top
            )
            .clipped()
        }
        .ignoresSafeArea()
        .overlay {
            if isShowingScreenFlash {
                Color.white
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(1000)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isShowingSettings) {
            dateSettings
                .presentationDetents([.medium])
        }
        .confirmationDialog(
            "定时拍摄",
            isPresented: $isShowingTimerPicker,
            titleVisibility: .visible
        ) {
            ForEach(CaptureTimerOption.allCases) { option in
                Button {
                    selectedTimer = option
                } label: {
                    if selectedTimer == option {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前：\(selectedTimer.displayName)")
        }
        .onAppear {
            restoreLastCameraSelection()
            camera.prepare()
            restorePendingDraftIfNeeded()
        }
        .fullScreenCover(isPresented: Binding(
            get: { pendingDraft != nil },
            set: { if !$0 { pendingDraft = nil } }
        )) {
            draftEditorSheet
        }
        .onDisappear {
            cancelActiveCapture()
            camera.stop()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                camera.prepare()
            } else if newPhase == .background {
                cancelActiveCapture()
                camera.stop()
            }
        }
        .onChange(of: permissionPhotoItem) { _, item in
            guard let item else { return }
            Task {
                await importFromPermissionPage(item)
            }
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    /// 拍完之后的编辑页：写一句话、选一个心情，确认了才进相册。
    @ViewBuilder
    private var draftEditorSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let pendingImage {
                        Image(uiImage: pendingImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 320)
                            .padding(10)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .shadow(color: .black.opacity(0.14), radius: 10, y: 5)
                            .padding(.top, 8)
                    }

                    draftAIStatusRow

                    VStack(alignment: .leading, spacing: 8) {
                        Text("这一刻发生了什么")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)

                        TextEditor(text: $draftNote)
                            .frame(height: 110)
                            .padding(8)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(.black.opacity(0.08), lineWidth: 1)
                            }
                            .overlay(alignment: .topLeading) {
                                if draftNote.isEmpty {
                                    Text("写一句话，记住这一刻")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.secondary.opacity(0.55))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 16)
                                        .allowsHitTesting(false)
                                }
                            }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("当时的心情")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 9) {
                            ForEach(Emotion.allCases, id: \.self) { emotion in
                                Button {
                                    draftEmotion = emotion
                                    draftEmotionTouchedByUser = true
                                    persistDraftEdits()
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                } label: {
                                    Text(emotion.displayName)
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                        .foregroundStyle(
                                            draftEmotion == emotion ? .white : .primary.opacity(0.7)
                                        )
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(
                                            draftEmotion == emotion
                                                ? Color.black.opacity(0.82)
                                                : Color.black.opacity(0.06),
                                            in: Capsule()
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Text("保存后这张照片才会进入相册；点重拍会直接放弃它。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
            .background(Color(white: 0.96))
            .navigationTitle("记录这一刻")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("重拍", role: .destructive) { requestDiscardDraft() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存到相册") { commitDraft() }
                        .font(.system(size: 15, weight: .bold))
                        .disabled(!canCommitDraft)
                }
            }
            .onChange(of: draftNote) { _, _ in persistDraftEdits() }
            .alert("这张还没保存", isPresented: $isShowingDiscardConfirm) {
                Button("放弃这张", role: .destructive) { discardDraft() }
                Button("继续编辑", role: .cancel) {}
            } message: {
                Text("离开就会丢掉这张照片和已经写下的内容。")
            }
            .interactiveDismissDisabled(true)
        }
    }

    /// 保存条件：写了一句话，并且选了心情。
    private var canCommitDraft: Bool {
        !draftNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draftEmotion != nil
    }

    /// 编辑页顶部的一行 AI 状态：让用户知道分析在后台跑，不必干等。
    @ViewBuilder
    private var draftAIStatusRow: some View {
        HStack(spacing: 8) {
            if draftAIResult != nil {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color(red: 0.62, green: 0.44, blue: 0.16))
                Text("分析好了，保存后可以翻到卡片背面")
            } else if draftAIDidFail {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("这次没分析成功，保存后可以再试")
            } else if !networkMonitor.isConnected {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(.secondary)
                Text("现在没有网络，保存后再补上分析")
            } else {
                ProgressView().controlSize(.small)
                Text("正在分析这一刻…")
            }
            Spacer()
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func integratedTopBar(safeAreaTop: CGFloat) -> some View {
        VStack(spacing: 0) {
            // 单独保留系统状态栏高度，标题内容永远从刘海/灵动岛下方开始。
            Color.clear
                .frame(height: safeAreaTop)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("MoodPolaroid")
                        .font(.system(size: 25, weight: .black, design: .rounded))
                        .foregroundStyle(
                            Color(red: 0.93, green: 0.28, blue: 0.48)
                        )

                    Text("把这一刻打印出来")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(Date.now.formatted(date: .abbreviated, time: .omitted))
                    Text("\(store.entries.count) 张")
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.black.opacity(0.52))
            }
            .padding(.horizontal, 18)
            .frame(height: LayoutConstants.topBarHeight)
        }
        .background(activeCanvasColor)
    }

    private func integratedBottomBar(safeAreaBottom: CGFloat) -> some View {
        ZStack {
            DotMatrixDecoration()

            HStack {
                Spacer()

                Button(action: openSkinDrawer) {
                    HStack(spacing: 5) {
                        Image(systemName: "camera.fill")
                        Text("CAMERA")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .tracking(0.5)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .black))
                    }
                    .foregroundStyle(.black.opacity(0.72))
                    .padding(.horizontal, 13)
                    .frame(height: 42)
                    .background(.white.opacity(0.72), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isCaptureLocked)
                .opacity(isCaptureLocked ? 0.45 : 1)
                .accessibilityLabel("打开相机与相纸选择")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, safeAreaBottom)
        .background(activeCanvasColor)
    }

    /// 产品中从倒计时开始到照片完成落盘前统一使用的相机控制锁。
    private var isCaptureLocked: Bool {
        isProcessing || countdown != nil || isShowingScreenFlash
    }

    private var drawerRowsOpacity: Double {
        if reduceMotion {
            return drawerContentOpacity
        }
        // 直接由我们自己驱动的 drawerOffset 决定：抽屉一旦离开收起位就完全可见。
        // 早前用 GeometryReader 量出来的 drawerPresentationOffset 在 .offset 变换下
        // 恒为 0，会把两行内容的透明度算成 0，抽屉拉开后看起来是空的。
        return drawerOffset > 0.5 ? 1 : 0
    }

    private var maximumDrawerOffset: CGFloat {
        guard selectedCameraSkin?.papers.isEmpty == false else {
            return LayoutConstants.cameraRowHeight
        }
        return LayoutConstants.cameraRowHeight
            + LayoutConstants.paperRowHeight
    }

    private func drawerTargetOffset(for state: CameraDrawerState) -> CGFloat {
        switch state {
        case .closed:
            0
        case .cameraSelect:
            LayoutConstants.cameraRowHeight
        case .paperSelect:
            LayoutConstants.cameraRowHeight
                + LayoutConstants.paperRowHeight
        }
    }

    private func clampedDrawerOffset(_ rawOffset: CGFloat) -> CGFloat {
        min(maximumDrawerOffset, max(0, rawOffset))
    }

    private func setDrawerState(_ state: CameraDrawerState) {
        let resolvedState = state
        let targetOffset = drawerTargetOffset(for: resolvedState)

        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                drawerState = resolvedState
                drawerOffset = targetOffset
            }
            withAnimation(
                .easeInOut(duration: TransitionConstants.reducedMotionFadeDuration)
            ) {
                drawerContentOpacity = resolvedState == .closed ? 0 : 1
            }
            return
        }

        withAnimation(MotionConstants.drawerCurve) {
            drawerState = resolvedState
            drawerOffset = targetOffset
            drawerContentOpacity = resolvedState == .closed ? 0 : 1
        }
    }

    private var drawerGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard !isCaptureLocked,
                      abs(value.translation.height) > abs(value.translation.width) else {
                    return
                }
                if !isDraggingDrawer {
                    isDraggingDrawer = true
                    // 以当前真实位移为起点接管，动画中途插手也不会跳变。
                    drawerDragStartOffset = drawerOffset
                }

                let nextOffset = clampedDrawerOffset(
                    drawerDragStartOffset - value.translation.height
                )
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    drawerOffset = nextOffset
                    drawerContentOpacity = nextOffset > 0 ? 1 : 0
                }
            }
            .onEnded { value in
                guard !isCaptureLocked,
                      isDraggingDrawer,
                      abs(value.translation.height) > abs(value.translation.width) else {
                    isDraggingDrawer = false
                    return
                }
                isDraggingDrawer = false
                let legalStates: [CameraDrawerState] =
                    selectedCameraSkin?.papers.isEmpty == false
                        ? [.closed, .cameraSelect, .paperSelect]
                        : [.closed, .cameraSelect]

                // 用手指真实停下的位置判定，不用 predictedEndTranslation：
                // 惯性投射会把“往下轻拨一点”外推成一大段，导致抽屉整个被关掉。
                let releasedOffset = clampedDrawerOffset(drawerOffset)
                let startState = legalStates.min { lhs, rhs in
                    abs(drawerTargetOffset(for: lhs) - drawerDragStartOffset)
                        < abs(drawerTargetOffset(for: rhs) - drawerDragStartOffset)
                } ?? .closed
                let travelled = releasedOffset - drawerDragStartOffset

                // 只有越过相邻两档之间约三分之一的距离，才允许换档；
                // 否则一律弹回起始档位，一次手势最多移动一档。
                let nearestState: CameraDrawerState
                if let startIndex = legalStates.firstIndex(of: startState) {
                    let neighbourIndex = travelled > 0 ? startIndex + 1 : startIndex - 1
                    if legalStates.indices.contains(neighbourIndex) {
                        let span = abs(
                            drawerTargetOffset(for: legalStates[neighbourIndex])
                                - drawerTargetOffset(for: startState)
                        )
                        nearestState = abs(travelled) > span / 3
                            ? legalStates[neighbourIndex]
                            : startState
                    } else {
                        nearestState = startState
                    }
                } else {
                    nearestState = .closed
                }
                setDrawerState(nearestState)
            }
    }

    private var selectedCameraSkin: CameraSkin? {
        CameraSkins.selectableNamed(selectedSkinID)
            ?? CameraSkins.named("mood_camera")
            ?? CameraSkins.selectable.first
    }

    private var activeCanvasColor: Color {
        selectedCameraSkin?.canvasColor
            ?? Color(red: 0.956863, green: 0.956863, blue: 0.956863)
    }

    private var selectedPaperHintColor: Color? {
        guard selectedCameraStyle == .polaroid,
              let selectedCameraSkin,
              let paper = selectedCameraSkin.papers.first(
                where: { $0.id == selectedSkinPaperID }
              ) else {
            return nil
        }
        return color(for: paper.colorHex)
    }

    @ViewBuilder
    private func cameraBody(height: CGFloat) -> some View {
        if let selectedCameraSkin {
            if selectedCameraSkin.id == CameraSkins.original.id {
                builtInCameraBody(height: height)
                    .transition(.opacity)
            } else {
                ZStack {
                    SkinnedCameraView(
                        skin: selectedCameraSkin,
                        camera: camera,
                        frozenImage: frozenImage,
                        countdown: countdown,
                        timerIsEnabled: selectedTimer != .off,
                        timerSeconds: selectedTimer.rawValue,
                        paperHintColor: selectedPaperHintColor,
                        actions: skinControlActions,
                        isControlEnabled: isSkinControlEnabled
                    ) {
                        if isCameraDenied {
                            cameraPermissionMessage
                        } else {
                            cameraUnavailableMessage
                        }
                    }
                }
                .animation(
                    .easeInOut(
                        duration: reduceMotion
                            ? TransitionConstants.reducedMotionFadeDuration
                            : TransitionConstants.skinCrossfadeDuration
                    ),
                    value: selectedCameraSkin.id
                )
                .frame(height: height)
            }
        } else {
            builtInCameraBody(height: height)
        }
    }

    /// 产品中皮肤功能名到现有原生相机动作的唯一映射表。
    private var skinControlActions: [CameraSkinControlFunction: () -> Void] {
        [
            .shutter: shutterButtonTapped,
            .album: openGallery,
            .flip: camera.switchCamera,
            .flash: camera.toggleFlash,
            .timer: cycleCaptureTimer,
            .zoom: cycleZoom,
            .drawer: openSkinDrawer
        ]
    }

    private func isSkinControlEnabled(
        _ function: CameraSkinControlFunction
    ) -> Bool {
        switch function {
        case .shutter:
            camera.isReady && !camera.isSwitchingCamera && (!isCaptureLocked || countdown != nil)
        case .flash:
            camera.isFlashAvailable && !isCaptureLocked
        case .zoom:
            camera.zoomOptions.count > 1 && !isCaptureLocked
        case .flip:
            !camera.isSwitchingCamera && !isCaptureLocked
        case .album, .timer, .drawer:
            !isCaptureLocked
        }
    }

    /// 皮肤若提供实体抽屉按钮，也进入同一个一级相机选择状态。
    private func openSkinDrawer() {
        guard !isCaptureLocked else { return }
        setDrawerState(.cameraSelect)
    }

    private func cycleCaptureTimer() {
        guard !isCaptureLocked else { return }
        switch selectedTimer {
        case .off:
            selectedTimer = .fiveSeconds
        case .fiveSeconds:
            selectedTimer = .tenSeconds
        case .tenSeconds:
            selectedTimer = .off
        }
    }

    private func builtInCameraBody(height: CGFloat) -> some View {
        ZStack(alignment: .top) {
            if currentSkin.hasPrinterSlot {
                Capsule()
                    .fill(.black.opacity(0.86))
                    .frame(width: 220, height: 18)
                    .offset(y: -7)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            }

            RoundedRectangle(cornerRadius: currentSkin.bodyCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: currentSkin.bodyColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .black.opacity(0.20), radius: 18, y: 12)
                .overlay {
                    RoundedRectangle(cornerRadius: currentSkin.bodyCornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.75), lineWidth: 2)
                }

            cameraBodyDecoration

            VStack(spacing: 10) {
                HStack {
                    timerControl
                    Spacer()
                    Text(currentSkin.modelName)
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .tracking(1.5)
                        .foregroundStyle(currentSkin.labelColor.opacity(0.72))
                    Spacer()
                    flashControl
                }
                .padding(.horizontal, 28)
                .padding(.top, 20)

                viewfinder

                Spacer(minLength: 4)

                cameraHardwareControls

                Spacer(minLength: 0)

                Text(viewfinderStatusText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(currentSkin.labelColor.opacity(0.62))
                    .lineLimit(1)
                    .padding(.bottom, 14)
            }
        }
        .frame(height: height)
        .animation(.easeInOut(duration: 0.25), value: selectedCameraStyle)
    }

    private var viewfinder: some View {
        let previewSize = currentSkin.viewfinderSize
        let outerSize = CGSize(width: previewSize.width + 46, height: previewSize.height + 46)
        let middleSize = CGSize(width: previewSize.width + 20, height: previewSize.height + 20)

        return ZStack {
            RoundedRectangle(
                cornerRadius: currentSkin.viewfinderCornerRadius + 23,
                style: .continuous
            )
                .fill(currentSkin.lensFrameColor)
                .frame(width: outerSize.width, height: outerSize.height)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)

            RoundedRectangle(
                cornerRadius: currentSkin.viewfinderCornerRadius + 10,
                style: .continuous
            )
                .fill(.black)
                .frame(width: middleSize.width, height: middleSize.height)

            FilteredCameraPreview(
                camera: camera,
                parameters: selectedCameraSkin?.filter
                    ?? CameraSkins.original.filter
            )
                .frame(width: previewSize.width, height: previewSize.height)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: currentSkin.viewfinderCornerRadius,
                        style: .continuous
                    )
                )
                .opacity(camera.isReady && frozenImage == nil ? 1 : 0)

            if let frozenImage {
                Image(uiImage: frozenImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: previewSize.width, height: previewSize.height)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: currentSkin.viewfinderCornerRadius,
                            style: .continuous
                        )
                    )
            } else if isCameraDenied {
                cameraPermissionMessage
            } else if !camera.isReady {
                cameraUnavailableMessage
            }

            RoundedRectangle(
                cornerRadius: currentSkin.viewfinderCornerRadius,
                style: .continuous
            )
                .fill(
                    LinearGradient(
                        colors: [.purple.opacity(0.08), .clear, .cyan.opacity(0.10)],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    )
                )
                .frame(width: previewSize.width, height: previewSize.height)
                .allowsHitTesting(false)

            if let countdown {
                Text("\(countdown)")
                    .font(.system(size: 84, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
                    .transition(.scale.combined(with: .opacity))
            }

            Capsule()
                .fill(.white.opacity(0.28))
                .frame(width: 34, height: 10)
                .rotationEffect(.degrees(-35))
                .offset(x: previewSize.width * 0.27, y: -previewSize.height * 0.31)
                .blur(radius: 1)
                .allowsHitTesting(false)
        }
        .frame(height: 284)
    }

    @ViewBuilder
    private var cameraBodyDecoration: some View {
        switch selectedCameraStyle {
        case .original:
            HStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { _ in
                    Capsule()
                        .fill(.white.opacity(0.10))
                        .frame(width: 30, height: 4)
                }
            }
            .offset(y: 62)
        case .polaroid:
            HStack(spacing: 0) {
                Color.red
                Color.orange
                Color.yellow
                Color.green
                Color.blue
            }
            .frame(width: 138, height: 5)
            .clipShape(Capsule())
            .offset(y: 61)
        case .ccd:
            Capsule()
                .fill(.white.opacity(0.42))
                .frame(width: 190, height: 3)
                .offset(y: 63)
        }
    }

    private var timerControl: some View {
        Menu {
            ForEach(CaptureTimerOption.allCases) { option in
                Button {
                    selectedTimer = option
                } label: {
                    if selectedTimer == option {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
            }
        } label: {
            cameraTopControlLabel(
                icon: selectedTimer == .off ? "timer" : "timer.circle.fill",
                tint: selectedTimer == .off ? .secondary : .blue,
                isOn: selectedTimer != .off
            )
        }
        .disabled(isCaptureLocked)
        .accessibilityLabel("定时拍照，当前 \(selectedTimer.displayName)")
    }

    private var flashControl: some View {
        Button {
            camera.toggleFlash()
        } label: {
            cameraTopControlLabel(
                icon: camera.isFlashEnabled ? "bolt.fill" : "bolt.slash.fill",
                tint: camera.isFlashEnabled ? .orange : .secondary,
                isOn: camera.isFlashEnabled
            )
        }
        .buttonStyle(.plain)
        .disabled(!camera.isFlashAvailable || isCaptureLocked)
        .opacity(camera.isFlashAvailable ? 1 : 0.45)
        .accessibilityLabel(camera.isFlashEnabled ? "关闭闪光灯" : "打开闪光灯")
    }

    private func cameraTopControlLabel(icon: String, tint: Color, isOn: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))

            Circle()
                .fill(isOn ? tint : .gray.opacity(0.55))
                .frame(width: 6, height: 6)
                .offset(x: 2, y: 2)
        }
        .foregroundStyle(tint)
        .frame(width: 42, height: 34)
        .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 2)
    }

    @ViewBuilder
    private var cameraHardwareControls: some View {
        switch selectedCameraStyle {
        case .ccd:
            ccdHardwareControls
        case .original, .polaroid:
            instantHardwareControls
        }
    }

    private var instantHardwareControls: some View {
        HStack(spacing: 18) {
            Button(action: cycleZoom) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color(red: 0.30, green: 0.30, blue: 0.31), .black],
                                center: .topLeading,
                                startRadius: 2,
                                endRadius: 34
                            )
                        )
                        .frame(width: 58, height: 58)
                        .overlay(Circle().stroke(.white.opacity(0.20), lineWidth: 1))

                    Image(systemName: "camera.aperture")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)

                    Circle()
                        .fill(.white)
                        .frame(width: 5, height: 5)
                        .offset(y: -23)

                    HStack(spacing: 4) {
                        ForEach(camera.zoomOptions.indices, id: \.self) { index in
                            Circle()
                                .fill(isZoomIndexSelected(index) ? currentSkin.accentColor : .white.opacity(0.35))
                                .frame(width: 4, height: 4)
                        }
                    }
                    .offset(y: 37)
                }
                .shadow(color: .black.opacity(0.25), radius: 4, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(camera.zoomOptions.count < 2 || isCaptureLocked)
            .opacity(camera.zoomOptions.count < 2 ? 0.55 : 1)

            Button {
                camera.switchCamera()
            } label: {
                ZStack {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.22, green: 0.22, blue: 0.23), .black],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 86, height: 42)
                        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))

                    Circle()
                        .fill(.white.opacity(0.94))
                        .frame(width: 32, height: 32)
                        .overlay {
                            Image(systemName: camera.cameraPosition == .back ? "person.crop.circle" : "mountain.2.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.black)
                        }
                        .offset(x: camera.cameraPosition == .back ? -20 : 20)

                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.white.opacity(0.62))
                }
                .shadow(color: .black.opacity(0.25), radius: 4, y: 3)
                .animation(.spring(response: 0.28, dampingFraction: 0.75), value: camera.cameraPosition)
            }
            .buttonStyle(.plain)
            .disabled(!camera.isReady || isCaptureLocked)

            bodyShutterButton
            bodyGalleryButton
        }
        .frame(height: 78)
        .padding(.horizontal, 14)
    }

    private var ccdHardwareControls: some View {
        HStack(spacing: 12) {
            ccdZoomRocker
            ccdFunctionPad
            bodyShutterButton
            bodyGalleryButton
        }
        .frame(height: 88)
        .padding(.horizontal, 12)
    }

    private var ccdZoomRocker: some View {
        HStack(spacing: 0) {
            Button {
                stepZoom(direction: -1)
            } label: {
                Image(systemName: "mountain.2")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 34, height: 38)
            }

            Divider()
                .overlay(.white.opacity(0.22))

            Button {
                stepZoom(direction: 1)
            } label: {
                Image(systemName: "mountain.2.fill")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 34, height: 38)
            }
        }
        .foregroundStyle(.white)
        .background(
            LinearGradient(
                colors: [Color(red: 0.25, green: 0.34, blue: 0.38), Color(red: 0.08, green: 0.12, blue: 0.14)],
                startPoint: .top,
                endPoint: .bottom
            ),
            in: Capsule()
        )
        .overlay(Capsule().stroke(.white.opacity(0.24), lineWidth: 1))
        .disabled(camera.zoomOptions.count < 2 || isCaptureLocked)
        .opacity(camera.zoomOptions.count < 2 ? 0.45 : (isCaptureLocked ? 0.55 : 1))
        .accessibilityLabel("CCD 焦段摇杆")
    }

    private var ccdFunctionPad: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(red: 0.23, green: 0.34, blue: 0.37), Color(red: 0.06, green: 0.10, blue: 0.12)],
                        center: .topLeading,
                        startRadius: 2,
                        endRadius: 42
                    )
                )
                .frame(width: 76, height: 76)
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))

            Circle()
                .fill(.black.opacity(0.55))
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }

            Image(systemName: camera.isFlashEnabled ? "bolt.fill" : "bolt.slash.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(camera.isFlashEnabled ? .yellow : .white.opacity(0.65))
                .offset(y: -27)

            Image(systemName: "timer")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.65))
                .offset(x: -27)

            Image(systemName: "photo")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.65))
                .offset(x: 27)
        }
        .contentShape(Circle())
        .allowsHitTesting(!isCaptureLocked)
        .opacity(isCaptureLocked ? 0.5 : 1)
        .onTapGesture {
            guard !isCaptureLocked else { return }
            camera.switchCamera()
        }
        .accessibilityLabel("切换前后摄像头")
    }

    private var bodyShutterButton: some View {
        Button(action: shutterButtonTapped) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.34))
                    .frame(width: 66, height: 66)
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 58, height: 58)
                Circle()
                    .fill(countdown == nil ? currentSkin.accentColor : Color.red)
                    .frame(width: 48, height: 48)

                if countdown != nil {
                    Image(systemName: "xmark")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(.white)
                } else if isProcessing {
                    ProgressView()
                        .tint(.white)
                }
            }
            .shadow(color: currentSkin.accentColor.opacity(0.34), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(!camera.isReady || (isCaptureLocked && countdown == nil))
        .accessibilityLabel(countdown == nil ? "拍照" : "取消倒计时")
    }

    private var bodyGalleryButton: some View {
        Button(action: openGallery) {
            Image(systemName: "photo.stack.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 46, height: 46)
                .background(.white.opacity(0.90), in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 5, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(isCaptureLocked)
        .opacity(isCaptureLocked ? 0.45 : 1)
        .accessibilityLabel("打开照片收藏")
    }

    private var cameraPermissionMessage: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.fill")
                .font(.title2)
            Text("无法使用相机")
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Text(
                camera.authorizationStatus == .restricted
                    ? "此设备限制了相机使用，仍可从相册导入"
                    : "你可以前往设置授权，或继续从相册导入"
            )
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)

            if camera.authorizationStatus == .denied {
                Button("前往系统设置", action: openSystemSettings)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.93, green: 0.28, blue: 0.48))
            }

            HStack(spacing: 8) {
                PhotosPicker(selection: $permissionPhotoItem, matching: .images) {
                    Label("直接导入", systemImage: "photo.badge.plus")
                }
                .buttonStyle(.bordered)

                Button {
                    openGallery()
                } label: {
                    Label("照片收藏", systemImage: "photo.stack")
                }
                .buttonStyle(.bordered)
            }
            .font(.caption.weight(.semibold))
            .tint(.white)
        }
        .foregroundStyle(.white)
        .frame(width: 210)
    }

    private var cameraUnavailableMessage: some View {
        VStack(spacing: 8) {
            ProgressView()
                .tint(.white)
                .opacity(camera.errorMessage == nil ? 1 : 0)
            Text(camera.errorMessage ?? "正在启动相机…")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .frame(width: 190)
        }
    }

    private var styleSelector: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("CAMERAS", systemImage: "camera.fill")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .tracking(1.2)
                Spacer()
                Text("左右选择机型")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                ForEach([CameraStyle.polaroid]) { style in
                    Button {
                        selectedCameraStyle = style
                    } label: {
                        VStack(spacing: 7) {
                            cameraThumbnail(for: style)

                            Text(style.displayName)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(
                                    selectedCameraStyle == style
                                        ? skin(for: style).accentColor
                                        : .secondary
                                )
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 84)
                        .offset(y: selectedCameraStyle == style ? -4 : 0)
                    }
                    .buttonStyle(.plain)
                    .disabled(isCaptureLocked)
                    .opacity(isCaptureLocked ? 0.45 : 1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 9)
            .padding(.bottom, 4)
            .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func cameraThumbnail(for style: CameraStyle) -> some View {
        let styleSkin = skin(for: style)

        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: styleSkin.bodyColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 76, height: 48)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            selectedCameraStyle == style ? styleSkin.accentColor : .white.opacity(0.65),
                            lineWidth: selectedCameraStyle == style ? 3 : 1
                        )
                }
                .shadow(
                    color: selectedCameraStyle == style ? styleSkin.accentColor.opacity(0.28) : .black.opacity(0.10),
                    radius: selectedCameraStyle == style ? 7 : 3,
                    y: 3
                )

            Circle()
                .fill(styleSkin.lensFrameColor)
                .frame(width: 31, height: 31)
            Circle()
                .fill(.black)
                .frame(width: 22, height: 22)
            Circle()
                .fill(.blue.opacity(0.32))
                .frame(width: 13, height: 13)

            RoundedRectangle(cornerRadius: 3)
                .fill(.white.opacity(0.86))
                .frame(width: 13, height: 7)
                .offset(x: 25, y: -14)
        }
    }

    private var polaroidOptions: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(PolaroidPaperStyle.allCases) { paper in
                    Button(paper.displayName) {
                        selectedPaperStyle = paper
                    }
                }
            } label: {
                optionCapsule(
                    title: "相纸",
                    value: selectedPaperStyle.displayName,
                    swatch: selectedPaperStyle.color
                )
            }

            Menu {
                ForEach(PolaroidFilterStyle.allCases) { filter in
                    Button(filter.displayName) {
                        selectedFilterStyle = filter
                    }
                }
            } label: {
                optionCapsule(
                    title: "滤镜",
                    value: selectedFilterStyle.displayName,
                    swatch: Color(red: 0.87, green: 0.68, blue: 0.79)
                )
            }
        }
    }

    private func optionCapsule(title: String, value: String, swatch: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(swatch)
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(.black.opacity(0.12), lineWidth: 1))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
    }

    /// 产品中位于底条下方、由配置自动扩展的 H1 相机选择行。
    private var cameraSelectionDrawerRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("CAMERAS")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .tracking(1.4)
                Spacer()
                Capsule()
                    .fill(.black.opacity(0.18))
                    .frame(width: 38, height: 4)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            cameraSelectionRow
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(activeCanvasColor)
        .contentShape(Rectangle())
        .accessibilityLabel("相机选择抽屉")
    }

    /// 产品中位于相机行下方、继续拉开后出现的 H2 相纸选择行。
    @ViewBuilder
    private var paperSelectionDrawerRow: some View {
        if let selectedCameraSkin,
           !selectedCameraSkin.papers.isEmpty {
            paperSelectionRow(for: selectedCameraSkin)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(activeCanvasColor)
        } else {
            activeCanvasColor
        }
    }

    /// 相机抽屉直接由可选皮肤注册表驱动，新增相机只需增加配置。
    private var drawerCameraSkins: [CameraSkin] {
        CameraSkins.selectable
    }

    private var cameraSelectionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 18) {
                ForEach(drawerCameraSkins) { skin in
                    Button {
                        selectCameraSkin(skin)
                    } label: {
                        VStack(spacing: 3) {
                            if skin.id == CameraSkins.original.id {
                                cameraThumbnail(for: .original)
                                    .frame(width: 82, height: 68)
                            } else {
                                Image(skin.thumbnailImage)
                                    .resizable()
                                    .interpolation(.high)
                                    .scaledToFit()
                                    .frame(width: 82, height: 68)
                                    .shadow(
                                        color: .black.opacity(0.12),
                                        radius: 3,
                                        y: 2
                                    )
                            }

                            Text(skin.displayName)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(
                                    selectedSkinID == skin.id
                                        ? Color.white
                                        : Color.primary.opacity(0.72)
                                )
                                .padding(.horizontal, 11)
                                .padding(.vertical, 4)
                                .background(
                                    selectedSkinID == skin.id
                                        ? Color.black.opacity(0.82)
                                        : Color.clear,
                                    in: Capsule()
                                )
                        }
                        .frame(width: 96)
                    }
                    .buttonStyle(.plain)
                    .disabled(isCaptureLocked)
                    .opacity(isCaptureLocked ? 0.45 : 1)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
        .accessibilityLabel("选择相机")
    }

    private func paperSelectionRow(for skin: CameraSkin) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("PAPERS")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 29, height: 24)
                        .background(.black.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("卡片日期格式与字体")
            }
            .padding(.horizontal, 17)
            .padding(.top, 9)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(skin.papers) { paper in
                        Button {
                            selectedSkinPaperID = paper.id
                            if let legacyPaper = PolaroidPaperStyle(rawValue: paper.id) {
                                selectedPaperStyle = legacyPaper
                            }
                        } label: {
                            HStack(spacing: 7) {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(color(for: paper.colorHex))
                                    .frame(width: 27, height: 36)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .stroke(.black.opacity(0.13), lineWidth: 1)
                                    }
                                Text(paper.displayName)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10)
                            .frame(height: 50)
                            .background(
                                selectedSkinPaperID == paper.id
                                    ? Color.white
                                    : Color.white.opacity(0.48),
                                in: Capsule()
                            )
                            .overlay {
                                Capsule()
                                    .stroke(
                                        selectedSkinPaperID == paper.id
                                            ? Color(red: 0.93, green: 0.28, blue: 0.48)
                                            : Color.clear,
                                        lineWidth: 2
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 15)
            }
        }
    }

    private func selectCameraSkin(_ skin: CameraSkin) {
        guard !isCaptureLocked else { return }

        if selectedSkinID != skin.id {
            withAnimation(
                .easeInOut(
                    duration: reduceMotion
                        ? TransitionConstants.reducedMotionFadeDuration
                        : TransitionConstants.skinCrossfadeDuration
                )
            ) {
                selectedSkinID = skin.id
                selectedCameraStyle = cameraStyle(for: skin)
            }
        }

        if let firstPaper = skin.papers.first,
           !skin.papers.contains(where: { $0.id == selectedSkinPaperID }) {
            selectedSkinPaperID = firstPaper.id
        } else if skin.papers.isEmpty {
            selectedSkinPaperID = ""
        }
        setDrawerState(skin.papers.isEmpty ? .cameraSelect : .paperSelect)
    }

    private func cameraStyle(for skin: CameraSkin) -> CameraStyle {
        let identifier = skin.id.lowercased()
        if identifier.contains("polaroid")
            || identifier.contains("instant")
            || identifier == "mood_camera" {
            return .polaroid
        }
        if identifier.contains("ccd") || identifier.contains("digital") {
            return .ccd
        }
        return .original
    }

    /// 页面重建时从 AppStorage 恢复上一台相机，并迁移旧版拍立得标识。
    private func restoreLastCameraSelection() {
        if selectedSkinID == "polaroid" {
            selectedSkinID = "mood_camera"
        }
        guard let skin = CameraSkins.selectableNamed(selectedSkinID)
                ?? CameraSkins.named("mood_camera") else {
            return
        }
        selectedSkinID = skin.id
        selectedCameraStyle = cameraStyle(for: skin)
        if skin.papers.isEmpty {
            selectedSkinPaperID = ""
        } else if !skin.papers.contains(where: { $0.id == selectedSkinPaperID }) {
            selectedSkinPaperID = skin.papers.first?.id ?? ""
        }
    }

    private func color(for hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else {
            return .white
        }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    private var dateSettings: some View {
        NavigationStack {
            Form {
                Section("卡片日期外观") {
                    Picker("日期格式", selection: $dateStyleRawValue) {
                        ForEach(PolaroidDateStyle.allCases) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    }

                    Picker("日期字体", selection: $dateFontStyleRawValue) {
                        ForEach(PolaroidDateFontStyle.allCases) { style in
                            Text(style.displayName)
                                .font(style.font)
                                .tag(style.rawValue)
                        }
                    }

                    Text(selectedDateStyle.text(for: Date()))
                        .font(selectedDateFontStyle.font)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("卡片设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        isShowingSettings = false
                    }
                }
            }
        }
    }

    private var selectedDateStyle: PolaroidDateStyle {
        PolaroidDateStyle(rawValue: dateStyleRawValue) ?? .localized
    }

    private var selectedDateFontStyle: PolaroidDateFontStyle {
        PolaroidDateFontStyle(rawValue: dateFontStyleRawValue) ?? .monospaced
    }

    private var cameraPageBackground: Color {
        switch selectedCameraStyle {
        case .original:
            Color(red: 0.94, green: 0.94, blue: 0.95)
        case .polaroid:
            Color(red: 0.99, green: 0.96, blue: 0.97)
        case .ccd:
            Color(red: 0.92, green: 0.96, blue: 0.98)
        }
    }

    private var isCameraDenied: Bool {
        camera.authorizationStatus == .denied || camera.authorizationStatus == .restricted
    }

    private var viewfinderStatusText: String {
        if frozenImage != nil { return "PHOTO LOCKED · PRINTING" }
        if isCameraDenied { return "CAMERA ACCESS OFF" }
        if camera.isReady { return "READY · TAP THE SHUTTER" }
        return "STARTING CAMERA"
    }

    private var currentSkin: BuiltInCameraAppearance {
        skin(for: selectedCameraStyle)
    }

    private func skin(for style: CameraStyle) -> BuiltInCameraAppearance {
        switch style {
        case .original:
            BuiltInCameraAppearance(
                modelName: "MOOD ORIGINAL",
                bodyColors: [
                    Color(red: 0.18, green: 0.19, blue: 0.21),
                    Color(red: 0.07, green: 0.08, blue: 0.09)
                ],
                accentColor: Color(red: 0.96, green: 0.34, blue: 0.30),
                labelColor: .white,
                lensFrameColor: Color(red: 0.34, green: 0.35, blue: 0.37),
                bodyCornerRadius: 26,
                viewfinderSize: CGSize(width: 250, height: 224),
                viewfinderCornerRadius: 28,
                hasPrinterSlot: false
            )
        case .polaroid:
            BuiltInCameraAppearance(
                modelName: "MOOD INSTANT",
                bodyColors: [
                    Color(red: 1.0, green: 0.96, blue: 0.86),
                    Color(red: 0.97, green: 0.84, blue: 0.68)
                ],
                accentColor: Color(red: 0.93, green: 0.28, blue: 0.48),
                labelColor: .black,
                lensFrameColor: Color(red: 0.83, green: 0.82, blue: 0.78),
                bodyCornerRadius: 42,
                viewfinderSize: CGSize(width: 238, height: 238),
                viewfinderCornerRadius: 119,
                hasPrinterSlot: true
            )
        case .ccd:
            BuiltInCameraAppearance(
                modelName: "MOOD CCD 2000",
                bodyColors: [
                    Color(red: 0.82, green: 0.88, blue: 0.91),
                    Color(red: 0.40, green: 0.52, blue: 0.59)
                ],
                accentColor: Color(red: 0.10, green: 0.67, blue: 0.84),
                labelColor: Color(red: 0.05, green: 0.12, blue: 0.16),
                lensFrameColor: Color(red: 0.20, green: 0.28, blue: 0.32),
                bodyCornerRadius: 32,
                viewfinderSize: CGSize(width: 260, height: 190),
                viewfinderCornerRadius: 22,
                hasPrinterSlot: false
            )
        }
    }

    private func isSelectedZoom(_ option: CameraZoomOption) -> Bool {
        abs(camera.currentZoomFactor - option.factor) < 0.01
    }

    private func isZoomIndexSelected(_ index: Int) -> Bool {
        guard camera.zoomOptions.indices.contains(index) else { return false }
        return isSelectedZoom(camera.zoomOptions[index])
    }

    private func cycleZoom() {
        stepZoom(direction: 1)
    }

    private func stepZoom(direction: Int) {
        guard camera.zoomOptions.count > 1 else { return }
        let currentIndex = camera.zoomOptions.firstIndex(where: isSelectedZoom) ?? 0
        let nextIndex = (currentIndex + direction + camera.zoomOptions.count) % camera.zoomOptions.count
        camera.setZoom(camera.zoomOptions[nextIndex])
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    @MainActor
    private func importFromPermissionPage(_ item: PhotosPickerItem) async {
        isProcessing = true
        let entryID = UUID()
        var savedFileName: String?

        defer {
            permissionPhotoItem = nil
        }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw CaptureFlowError.cannotReadImportedImage
            }
            let fileName = try photoFileStore.saveImportedData(data, id: entryID)
            savedFileName = fileName
            let entry = MoodEntry(
                id: entryID,
                createdAt: Date(),
                imageFileName: fileName,
                cameraStyle: .polaroid,
                cameraSkinID: CameraSkins.named("polaroid")?.id,
                paperID: CameraSkins.named("polaroid")?.papers.first?.id,
                cardState: .pending
            )

            guard store.add(entry) else {
                throw CaptureFlowError.cannotSaveRecord
            }

            startAIGeneration(for: entry)
            isProcessing = false
            showCard(entry)
        } catch {
            if let savedFileName {
                try? photoFileStore.delete(fileName: savedFileName)
            }
            isProcessing = false
            alertMessage = "导入照片失败：\(error.localizedDescription)"
        }
    }

    private func shutterButtonTapped() {
        if countdown != nil {
            cancelCountdown()
        } else {
            takePhoto()
        }
    }

    private func takePhoto() {
        guard !isProcessing else { return }
        captureStyleSnapshot = selectedCameraStyle
        captureSkinIDSnapshot = selectedSkinID
        capturePaperIDSnapshot = selectedSkinPaperID
        captureFilterSnapshot = selectedCameraSkin?.filter
        setDrawerState(.closed)
        isProcessing = true

        if selectedTimer.rawValue > 0 {
            startCountdown(seconds: selectedTimer.rawValue)
        } else {
            captureNow()
        }
    }

    private func startCountdown(seconds: Int) {
        countdownTask?.cancel()
        countdown = seconds
        countdownTask = Task { @MainActor in
            for remaining in stride(from: seconds, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    countdown = remaining
                }

                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }

            countdown = nil
            countdownTask = nil
            captureNow()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
        captureStyleSnapshot = nil
        captureSkinIDSnapshot = nil
        capturePaperIDSnapshot = nil
        captureFilterSnapshot = nil
        isProcessing = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func captureNow() {
        if camera.usesScreenFlash {
            captureWithScreenFlash()
        } else {
            captureCameraImage()
        }
    }

    private func captureWithScreenFlash() {
        screenFlashTask?.cancel()
        brightnessBeforeScreenFlash = UIScreen.main.brightness
        UIScreen.main.brightness = 1
        withAnimation(.easeIn(duration: 0.12)) {
            isShowingScreenFlash = true
        }

        screenFlashTask = Task { @MainActor in
            // 前置补光先让眼睛与相机充分接收到整屏白光，再触发快门。
            do {
                try await Task.sleep(for: .milliseconds(420))
            } catch {
                return
            }
            captureCameraImage()
            // 拍摄后仍保持片刻最大亮度，模拟 iPhone 前置屏幕补光的余光。
            do {
                try await Task.sleep(for: .milliseconds(680))
            } catch {
                return
            }
            finishScreenFlash()
            screenFlashTask = nil
        }
    }

    private func finishScreenFlash() {
        if let brightnessBeforeScreenFlash {
            UIScreen.main.brightness = brightnessBeforeScreenFlash
            self.brightnessBeforeScreenFlash = nil
        }
        withAnimation(.easeOut(duration: 0.18)) {
            isShowingScreenFlash = false
        }
    }

    private func cancelActiveCapture() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
        screenFlashTask?.cancel()
        screenFlashTask = nil
        captureStyleSnapshot = nil
        captureSkinIDSnapshot = nil
        capturePaperIDSnapshot = nil
        captureFilterSnapshot = nil
        isProcessing = false
        finishScreenFlash()
    }

    private func captureCameraImage() {
        MoodSoundEffect.capture()
        camera.capture(
            filterParameters: captureFilterSnapshot
                ?? selectedCameraSkin?.filter
                ?? CameraSkins.original.filter
        ) { result in
            switch result {
            case let .success(image):
                freezeAndPrintImmediately(image)
            case let .failure(error):
                countdown = nil
                captureStyleSnapshot = nil
                captureSkinIDSnapshot = nil
                capturePaperIDSnapshot = nil
                captureFilterSnapshot = nil
                isProcessing = false
                alertMessage = "拍照失败：\(error.localizedDescription)"
            }
        }
    }

    /// 拍摄成功后先锁定画面走显影动画，然后进入编辑页——此时照片只是“暂存”。
    @MainActor
    private func freezeAndPrintImmediately(_ image: UIImage) {
        frozenImage = image
        let capturedAt = Date()

        Task {
            try? await Task.sleep(for: .milliseconds(280))
            stageCapture(image, capturedAt: capturedAt)
        }
    }

    /// 把刚拍的照片落到草稿区并进入编辑页；这一步不写入相册。
    @MainActor
    private func stageCapture(_ image: UIImage, capturedAt: Date) {
        let draftID = UUID()

        do {
            let fileName = try photoFileStore.save(image, id: draftID)
            let paperID = capturePaperIDSnapshot ?? selectedSkinPaperID
            let draft = CaptureDraft(
                id: draftID,
                createdAt: capturedAt,
                imageFileName: fileName,
                cameraStyle: captureStyleSnapshot ?? selectedCameraStyle,
                cameraSkinID: captureSkinIDSnapshot ?? selectedSkinID,
                paperID: paperID.isEmpty ? nil : paperID,
                note: "",
                userEmotion: nil
            )
            draftStore.save(draft)

            captureStyleSnapshot = nil
            captureSkinIDSnapshot = nil
            capturePaperIDSnapshot = nil
            captureFilterSnapshot = nil
            isProcessing = false

            let presentDelay = isShowingScreenFlash ? 760 : 80
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(presentDelay))
                presentDraftEditor(draft, image: image)
                frozenImage = nil
            }
        } catch {
            try? photoFileStore.delete(fileName: "\(draftID.uuidString).jpg")
            frozenImage = nil
            captureStyleSnapshot = nil
            captureSkinIDSnapshot = nil
            capturePaperIDSnapshot = nil
            captureFilterSnapshot = nil
            isProcessing = false
            alertMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    /// 打开编辑页，并立刻在后台开始 AI 生成——用户填字的同时卡片已经在路上。
    @MainActor
    private func presentDraftEditor(_ draft: CaptureDraft, image: UIImage?) {
        pendingImage = image
        draftNote = draft.note
        draftEmotion = draft.userEmotion
        draftEmotionTouchedByUser = draft.userEmotion != nil
        draftAIResult = nil
        draftAIDidFail = false
        pendingDraft = draft
        startDraftAIGeneration(for: draft)
    }

    /// 草稿阶段的生成：结果先留在内存，用户点保存时才和记录一起写入。
    @MainActor
    private func startDraftAIGeneration(for draft: CaptureDraft) {
        draftAITask?.cancel()
        guard !aiService.requiresNetwork || networkMonitor.isConnected else {
            draftAIDidFail = false
            return
        }

        let probeEntry = MoodEntry(
            id: draft.id,
            createdAt: draft.createdAt,
            imageFileName: draft.imageFileName,
            cameraStyle: draft.cameraStyle,
            cameraSkinID: draft.cameraSkinID,
            paperID: draft.paperID,
            cardState: .pending
        )

        draftAITask = Task { @MainActor in
            do {
                let result = try await aiService.generate(for: probeEntry)
                guard !Task.isCancelled, pendingDraft?.id == draft.id else { return }
                draftAIResult = result
                draftAIDidFail = false
                // 用户还没自己挑过情绪时，默认跟随 AI 的判断。
                if !draftEmotionTouchedByUser {
                    draftEmotion = result.emotion
                }
            } catch {
                guard !Task.isCancelled, pendingDraft?.id == draft.id else { return }
                draftAIDidFail = true
            }
        }
    }

    /// 用户点“保存到相册”：照片、笔记、情绪和 AI 结果一起写入。
    @MainActor
    private func commitDraft() {
        guard let draft = pendingDraft else { return }
        let trimmedNote = draftNote.trimmingCharacters(in: .whitespacesAndNewlines)

        var entry = MoodEntry(
            id: draft.id,
            createdAt: draft.createdAt,
            imageFileName: draft.imageFileName,
            cameraStyle: draft.cameraStyle,
            cameraSkinID: draft.cameraSkinID,
            paperID: draft.paperID,
            note: trimmedNote.isEmpty ? nil : trimmedNote,
            userEmotion: draftEmotion,
            cardState: .pending
        )

        if let result = draftAIResult {
            entry.aiEmotion = result.emotion
            entry.aiSummary = result.summary
            entry.cardState = .generated
        } else if draftAIDidFail {
            entry.cardState = .failed
        }

        guard store.add(entry) else {
            alertMessage = CaptureFlowError.cannotSaveRecord.errorDescription
            return
        }

        // 照片文件的归属从草稿转给正式记录，这里只清草稿元数据，不删文件。
        draftAITask?.cancel()
        draftStore.clear()
        pendingDraft = nil
        pendingImage = nil

        // 保存时还没拿到结果（离线或仍在路上）就交给统一的重试入口继续。
        if entry.cardState != .generated {
            startAIGeneration(for: entry)
        }

        showCard(entry)
    }

    /// 用户点“重拍”或确认放弃：照片文件和草稿一起删除，不进相册。
    @MainActor
    private func discardDraft() {
        draftAITask?.cancel()
        if let draft = pendingDraft {
            try? photoFileStore.delete(fileName: draft.imageFileName)
        }
        draftStore.clear()
        pendingDraft = nil
        pendingImage = nil
        draftNote = ""
        draftEmotion = nil
        draftEmotionTouchedByUser = false
        draftAIResult = nil
        draftAIDidFail = false
    }

    /// 用户已经填过东西时离开要问一句，什么都没填则直接放弃、不打扰。
    @MainActor
    private func requestDiscardDraft() {
        let hasInput = !draftNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || draftEmotionTouchedByUser
        if hasInput {
            isShowingDiscardConfirm = true
        } else {
            discardDraft()
        }
    }

    /// 启动时若发现上次没保存完的草稿，直接回到编辑页继续，不静默丢照片。
    @MainActor
    private func restorePendingDraftIfNeeded() {
        guard pendingDraft == nil, let draft = draftStore.load() else { return }
        guard photoFileStore.exists(fileName: draft.imageFileName) else {
            draftStore.clear()
            return
        }
        let image = photoFileStore.loadImage(fileName: draft.imageFileName)
        presentDraftEditor(draft, image: image)
    }

    /// 编辑页里的输入实时回写草稿，App 被杀也不丢已经写下的内容。
    @MainActor
    private func persistDraftEdits() {
        guard var draft = pendingDraft else { return }
        draft.note = draftNote
        draft.userEmotion = draftEmotion
        pendingDraft = draft
        draftStore.save(draft)
    }

    @MainActor
    private func startAIGeneration(for entry: MoodEntry) {
        Task {
            await generateMoodCard(
                entryID: entry.id,
                using: aiService,
                store: store,
                isNetworkConnected: networkMonitor.isConnected
            )
        }
    }
}

/// 三段式底条左侧显示的最近一张本地照片缩略图。
private struct IntegratedRecentPhotoThumbnail: View {
    let entry: MoodEntry?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.white.opacity(0.76))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.38))
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.white.opacity(0.9), lineWidth: 2)
        }
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .task(id: entry?.id) {
            guard let entry else {
                image = nil
                return
            }
            image = PhotoFileStore().loadImage(
                fileName: entry.imageFileName,
                maxPixelSize: 180
            )
        }
    }
}

/// 三段式底条中央模拟相机扬声器孔的装饰点阵。
private struct DotMatrixDecoration: View {
    var body: some View {
        VStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 7) {
                    ForEach(0..<4, id: \.self) { _ in
                        Circle()
                            .fill(.black.opacity(0.18))
                            .frame(width: 4, height: 4)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// 产品中相册图片无法读取或拍摄记录无法写入本机时使用的流程错误。
private enum CaptureFlowError: LocalizedError {
    case cannotReadImportedImage
    case cannotSaveRecord

    var errorDescription: String? {
        switch self {
        case .cannotReadImportedImage: "无法读取这张照片，请换一张重试。"
        case .cannotSaveRecord: "无法写入本地记录。"
        }
    }
}
