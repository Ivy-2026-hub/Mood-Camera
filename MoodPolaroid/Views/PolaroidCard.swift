import SwiftUI

/// 产品中拍立得卡片的可调整动画时序。
enum PolaroidAnimationTiming {
    static let ejectionDuration: TimeInterval = 2.0
    static let developmentDuration: TimeInterval = 4.0
    static let ejectionTravel: CGFloat = 520
}

/// 产品中拍立得卡片可选择的日期显示格式，所有格式都不包含时分。
enum PolaroidDateStyle: String, CaseIterable, Identifiable {
    case localized
    case numeric
    case withWeekday

    var id: Self { self }

    var displayName: String {
        switch self {
        case .localized: "中文长日期"
        case .numeric: "数字日期"
        case .withWeekday: "日期和星期"
        }
    }

    func text(for date: Date) -> String {
        switch self {
        case .localized:
            date.formatted(date: .long, time: .omitted)
        case .numeric:
            date.formatted(date: .numeric, time: .omitted)
        case .withWeekday:
            date.formatted(date: .complete, time: .omitted)
        }
    }
}

/// 产品中拍立得卡片日期文字可选择的字体风格。
enum PolaroidDateFontStyle: String, CaseIterable, Identifiable {
    case monospaced
    case rounded
    case serif

    var id: Self { self }

    var displayName: String {
        switch self {
        case .monospaced: "等宽"
        case .rounded: "圆体"
        case .serif: "衬线"
        }
    }

    var font: Font {
        font(size: 10)
    }

    func font(size: CGFloat) -> Font {
        switch self {
        case .monospaced:
            .system(size: size, design: .monospaced)
        case .rounded:
            .system(size: size, design: .rounded)
        case .serif:
            .system(size: size, design: .serif)
        }
    }
}

/// 产品中拍立得从等待、吐纸到显影完成的视觉阶段。
private enum PolaroidAnimationPhase {
    case waiting
    case ejecting
    case developing
    case complete
}

/// 产品中承载照片、文字和日期，并播放吐纸与显影动画的拍立得卡片。
struct PolaroidCard: View {
    /// 产品中照片墙、翻页相册和详情页统一使用的卡片高宽比。
    static let unifiedCardHeightRatio: CGFloat = 1.42

    let entry: MoodEntry
    let dateStyle: PolaroidDateStyle
    let dateFontStyle: PolaroidDateFontStyle
    let cardWidth: CGFloat
    let playsDevelopmentAnimation: Bool
    let onAnimationCompleted: (() -> Void)?

    @State private var phase: PolaroidAnimationPhase = .waiting
    @State private var photoImage: UIImage?

    init(
        entry: MoodEntry,
        dateStyle: PolaroidDateStyle = .localized,
        dateFontStyle: PolaroidDateFontStyle = .monospaced,
        cardWidth: CGFloat = 280,
        playsDevelopmentAnimation: Bool = true,
        onAnimationCompleted: (() -> Void)? = nil
    ) {
        self.entry = entry
        self.dateStyle = dateStyle
        self.dateFontStyle = dateFontStyle
        self.cardWidth = cardWidth
        self.playsDevelopmentAnimation = playsDevelopmentAnimation
        self.onAnimationCompleted = onAnimationCompleted
    }

    /// 拍立得卡片与相机取景框共用同一个比例，避免展示时发生第二次裁切。
    static func photoAspectRatio(for entry: MoodEntry) -> CGFloat {
        guard entry.cameraStyle == .polaroid,
              let skin = CameraSkins.named(entry.cameraSkinID)
                ?? CameraSkins.named("polaroid"),
              skin.viewfinderRect.height > 0,
              skin.pixelHeight > 0 else {
            return 4 / 5
        }
        let pixelWidth = skin.viewfinderRect.width * skin.pixelWidth
        let pixelHeight = skin.viewfinderRect.height * skin.pixelHeight
        return pixelWidth / pixelHeight
    }

    /// 产品中卡片正反面共用的统一高度，不再因相机取景框比例而改变。
    static func cardHeight(for entry: MoodEntry, cardWidth: CGFloat) -> CGFloat {
        cardWidth * unifiedCardHeightRatio
    }

    var body: some View {
        cardContent
        .frame(width: cardWidth, height: unifiedCardHeight)
        .background(cardBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: max(2, 3 * cardScale), style: .continuous))
        .shadow(
            color: .black.opacity(0.16),
            radius: max(5, 12 * cardScale),
            x: 0,
            y: max(3, 8 * cardScale)
        )
        .scaleEffect(isPaperAtRest ? 1 : 0.95)
        .offset(y: isPaperAtRest ? 0 : PolaroidAnimationTiming.ejectionTravel)
        .rotationEffect(.degrees(paperRotation))
        // 用文件名当 id：同一张照片只解码一次。之前是裸 .task，拖动时视图反复
        // 重建会不停重新解码磁盘图片，造成“照片比图钉慢半拍才跟上”的割裂感。
        .task(id: entry.imageFileName) {
            photoImage = PhotoFileStore().loadImage(
                fileName: entry.imageFileName,
                maxPixelSize: max(500, cardWidth * 4)
            )
            if playsDevelopmentAnimation {
                await runAnimation()
            }
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        if entry.cameraStyle == .ccd {
            ccdCardContent
        } else {
            instantCardContent
        }
    }

    private var instantCardContent: some View {
        VStack(spacing: 0) {
            photoArea
                .frame(
                    width: instantPhotoSize.width,
                    height: instantPhotoSize.height
                )

            VStack(spacing: 8 * cardScale) {
                if hasStructuredMoodCard {
                    // 上方并排：AI 给的情绪口令（大字）+ 用户自己写的 note（小字）。
                    // 不再显示 summary——它已经去掉了。
                    Text(entry.moodCode ?? captionText)
                        .font(.custom("Chalkboard SE", size: 25 * cardScale))
                        .foregroundStyle(palette.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)

                    if let userNote = entry.note?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !userNote.isEmpty {
                        Text(userNote)
                            .font(.system(size: 13 * cardScale, weight: .medium, design: .rounded))
                            .foregroundStyle(Color(red: 0.18, green: 0.17, blue: 0.16))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    Text(captionText)
                        .font(.system(size: 18 * cardScale, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 0.12, green: 0.16, blue: 0.22))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }

                Spacer(minLength: 0)

                cardMetadata
            }
            .padding(.horizontal, 4 * cardScale)
            .padding(.top, 14 * cardScale)
            .frame(
                width: instantPhotoSize.width,
                height: instantChinHeight
            )
            .opacity(isPhotoVisible ? 1 : 0)
        }
        .padding(.top, instantTopInset)
        .padding(.bottom, instantBottomInset)
        .frame(width: cardWidth, height: unifiedCardHeight, alignment: .top)
    }

    private var ccdCardContent: some View {
        ZStack {
            photoArea
                .frame(
                    width: cardWidth - 18 * cardScale,
                    height: unifiedCardHeight - 18 * cardScale
                )
                .overlay {
                    Rectangle()
                        .stroke(.white.opacity(0.34), lineWidth: max(1, cardScale))
                }

            if entry.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                Text(captionText)
                    .font(.system(size: 14 * cardScale, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12 * cardScale)
                    .padding(.vertical, 7 * cardScale)
                    .frame(maxWidth: cardWidth - 36 * cardScale)
                    .background(.black.opacity(0.42))
                    .offset(y: -unifiedCardHeight * 0.18)
                    .opacity(isPhotoVisible ? 1 : 0)
            }

            VStack {
                Spacer()
                cardMetadata
                    .padding(.horizontal, 15 * cardScale)
                    .padding(.bottom, 15 * cardScale)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 3, y: 1)
            }
            .opacity(isPhotoVisible ? 1 : 0)
        }
        .padding(9 * cardScale)
    }

    private var cardMetadata: some View {
        HStack(spacing: 5 * cardScale) {
            if let effectiveEmotion {
                Text(effectiveEmotion.displayName)
                    .font(.system(size: 9 * cardScale, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        entry.cameraStyle == .ccd
                            ? Color.white
                            : palette.ink
                    )
                    .padding(.horizontal, 7 * cardScale)
                    .padding(.vertical, 3 * cardScale)
                    .background(
                        entry.cameraStyle == .ccd
                            ? Color.black.opacity(0.48)
                            : palette.capsule,
                        in: Capsule()
                    )
            }

            Spacer(minLength: 2)

            Text(dateStyle.text(for: entry.createdAt))
                .font(dateFontStyle.font(size: 10 * cardScale))
                .foregroundStyle(
                    entry.cameraStyle == .ccd
                        ? Color.white.opacity(0.88)
                        : Color.black.opacity(0.4)
                )
        }
    }

    private var photoArea: some View {
        ZStack {
            Color(red: 0.08, green: 0.08, blue: 0.08)

            if let photoImage {
                if entry.cameraStyle == .ccd {
                    Image(uiImage: photoImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // 相纸始终保持竖版；横持拍摄使用照片自身的横向比例，
                    // 像真实拍立得一样把完整横图放在竖版相纸上。
                    Image(uiImage: photoImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Color.black
                .opacity(isPhotoVisible ? 0 : 1)
        }
        .clipped()
        .overlay {
            LinearGradient(
                colors: [.clear, .white.opacity(0.10), .clear],
                startPoint: .bottomLeading,
                endPoint: .topTrailing
            )
            .allowsHitTesting(false)
        }
        .overlay {
            // 用户选的相纸若带相框图（Ivy 设计的 SVG 转成的 PNG，中间照片窗口透明），
            // 就把它叠在照片四周；照片从透明窗口露出、边框art 框住照片。
            if let frameImage = currentPaperFrameImage {
                Image(frameImage)
                    .resizable()
                    .allowsHitTesting(false)
                    .opacity(isPhotoVisible ? 1 : 0)
            }
        }
    }

    /// 解析用户当前选中的相纸，取出它的相框图资源名（没有则 nil，走纯色边）。
    private var currentPaperFrameImage: String? {
        guard let paperID = entry.paperID,
              let skin = CameraSkins.named(entry.cameraSkinID) ?? CameraSkins.named("polaroid"),
              let paper = skin.papers.first(where: { $0.id == paperID }) else {
            return nil
        }
        return paper.frameImage
    }

    private var isPaperAtRest: Bool {
        !playsDevelopmentAnimation || phase != .waiting
    }

    private var isPhotoVisible: Bool {
        !playsDevelopmentAnimation || phase == .developing || phase == .complete
    }

    private var cardScale: CGFloat {
        cardWidth / 280
    }

    private var unifiedCardHeight: CGFloat {
        Self.cardHeight(for: entry, cardWidth: cardWidth)
    }

    /// 取景框在机身上的占比越大，卡片的上边和左右边越窄。
    private var viewfinderCoverage: CGFloat {
        guard entry.cameraStyle == .polaroid,
              let skin = CameraSkins.named(entry.cameraSkinID)
                ?? CameraSkins.named("polaroid") else {
            return entry.cameraStyle == .ccd ? 0.84 : 0.70
        }
        return sqrt(max(0, skin.viewfinderRect.width * skin.viewfinderRect.height))
    }

    private var instantSideInset: CGFloat {
        let normalizedCoverage = min(0.9, max(0.35, viewfinderCoverage))
        return cardWidth * (0.075 - normalizedCoverage * 0.045)
    }

    private var instantTopInset: CGFloat {
        max(8 * cardScale, instantSideInset * 0.92)
    }

    private var instantBottomInset: CGFloat {
        max(8 * cardScale, instantSideInset * 0.80)
    }

    private var instantPhotoSize: CGSize {
        let availableWidth = cardWidth - instantSideInset * 2
        let minimumChin = (78 + (1 - viewfinderCoverage) * 24) * cardScale
        let maximumHeight = unifiedCardHeight
            - instantTopInset
            - instantBottomInset
            - minimumChin
        let aspectRatio = displayedPhotoAspectRatio
        let height = min(availableWidth / aspectRatio, maximumHeight)
        return CGSize(width: min(availableWidth, height * aspectRatio), height: height)
    }

    private var displayedPhotoAspectRatio: CGFloat {
        guard let photoImage, photoImage.size.height > 0 else {
            return entry.cameraStyle == .ccd
                ? 4 / 5
                : Self.photoAspectRatio(for: entry)
        }
        let imageAspectRatio = photoImage.size.width / photoImage.size.height

        if entry.cameraStyle == .ccd {
            return imageAspectRatio
        }

        if imageAspectRatio > 1.05 {
            return imageAspectRatio
        }

        return Self.photoAspectRatio(for: entry)
    }

    private var instantChinHeight: CGFloat {
        max(
            0,
            unifiedCardHeight
                - instantTopInset
                - instantBottomInset
                - instantPhotoSize.height
        )
    }

    private var cardBackgroundColor: Color {
        palette.paper
    }

    private func color(from hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else {
            return Color(red: 0.99, green: 0.985, blue: 0.97)
        }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    private var effectiveEmotion: Emotion? {
        entry.userEmotion ?? entry.aiEmotion
    }

    private var palette: MoodPalette {
        // 配色跟随当前情绪（用户改后的优先），改心情即换模板。
        MoodPalette.forEmotion(entry.userEmotion ?? entry.aiEmotion)
    }

    private var hasStructuredMoodCard: Bool {
        entry.moodCode != nil
            || entry.encouragement != nil
            || entry.psychologyNote != nil
            || entry.palette != nil
    }

    private var paperRotation: Double {
        guard playsDevelopmentAnimation else { return 0 }
        return switch phase {
        case .waiting: -1.4
        case .ejecting: 0.45
        case .developing: -0.18
        case .complete: 0
        }
    }

    private var captionText: String {
        if let note = entry.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            return note
        }
        return "这一刻，值得被记住"
    }

    @MainActor
    private func runAnimation() async {
        var resetTransaction = Transaction()
        resetTransaction.disablesAnimations = true
        withTransaction(resetTransaction) {
            phase = .waiting
        }

        await Task.yield()

        MoodSoundEffect.printStart()

        withAnimation(
            .timingCurve(
                0.2,
                0.8,
                0.2,
                1,
                duration: PolaroidAnimationTiming.ejectionDuration
            )
        ) {
            phase = .ejecting
        }

        do {
            try await Task.sleep(for: .seconds(PolaroidAnimationTiming.ejectionDuration))
        } catch {
            return
        }

        withAnimation(.easeInOut(duration: PolaroidAnimationTiming.developmentDuration)) {
            phase = .developing
        }

        do {
            try await Task.sleep(for: .seconds(PolaroidAnimationTiming.developmentDuration))
        } catch {
            return
        }

        withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) {
            phase = .complete
        }
        MoodSoundEffect.developmentComplete()
        onAnimationCompleted?()
    }
}
