import SwiftUI
import UIKit

/// 产品中用来展示单条 MoodEntry 打印过程、正反面内容与用户情绪修正的卡片页。
struct CardView: View {
    @EnvironmentObject private var store: MoodEntryStore
    @EnvironmentObject private var networkMonitor: NetworkMonitor

    let entry: MoodEntry
    let aiService: any AIService
    let openGallery: (() -> Void)?
    let playsDevelopmentAnimation: Bool

    @AppStorage("polaroidDateStyle") private var dateStyleRawValue = PolaroidDateStyle.localized.rawValue
    @AppStorage("polaroidDateFontStyle") private var dateFontStyleRawValue = PolaroidDateFontStyle.monospaced.rawValue
    @State private var isFlipped = false
    /// 显影动画是否已经放完；翻面还要求 AI 结果已经回来（见 canFlip）。
    @State private var developmentDidFinish = false
    @State private var isShowingMoodEditor = false
    /// 用户是否已经点过“保存心情卡片”；没点就离开视为重拍、放弃这张照片。
    @State private var didCommit = false
    @State private var draftNote = ""


    init(
        entry: MoodEntry,
        aiService: any AIService,
        openGallery: (() -> Void)?,
        playsDevelopmentAnimation: Bool = true
    ) {
        self.entry = entry
        self.aiService = aiService
        self.openGallery = openGallery
        self.playsDevelopmentAnimation = playsDevelopmentAnimation
        _developmentDidFinish = State(initialValue: !playsDevelopmentAnimation)
    }

    /// 只有显影放完、且 AI 分析结果已经在这条记录里，才允许翻面——
    /// 背面要展示的就是分析内容，没出结果时翻过去是空的。
    private var canFlip: Bool {
        developmentDidFinish && currentEntry.cardState == .generated
    }

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = min(proxy.size.width - 44, 330)
            let cardHeight = PolaroidCard.cardHeight(
                for: currentEntry,
                cardWidth: cardWidth
            )

            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.98, green: 0.94, blue: 0.96), Color(red: 0.93, green: 0.90, blue: 0.94)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 18) {
                    ZStack {
                        PolaroidCard(
                            entry: currentEntry,
                            dateStyle: selectedDateStyle,
                            dateFontStyle: selectedDateFontStyle,
                            cardWidth: cardWidth,
                            playsDevelopmentAnimation: playsDevelopmentAnimation,
                            onAnimationCompleted: developmentDidComplete
                        )
                        .opacity(isFlipped ? 0 : 1)
                        .rotation3DEffect(
                            .degrees(isFlipped ? 180 : 0),
                            axis: (x: 0, y: 1, z: 0),
                            perspective: 0.72
                        )
                        .allowsHitTesting(!isFlipped && canFlip)
                        .onTapGesture(perform: flipCard)

                        EmotionCardBack(
                            entry: currentEntry,
                            dateText: selectedDateStyle.text(for: currentEntry.createdAt),
                            dateFont: selectedDateFontStyle.font(size: 12),
                            cardWidth: cardWidth,
                            cardHeight: cardHeight,
                            updateEmotion: updateEmotion,
                            flipBack: flipCard
                        )
                        .opacity(isFlipped ? 1 : 0)
                        .rotation3DEffect(
                            .degrees(isFlipped ? 0 : -180),
                            axis: (x: 0, y: 1, z: 0),
                            perspective: 0.72
                        )
                        .allowsHitTesting(isFlipped)
                    }
                    .frame(width: cardWidth, height: cardHeight)

                    if canFlip && !isFlipped {
                        Label("轻点卡片查看情绪总结", systemImage: "rotate.3d")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    } else if !developmentDidFinish {
                        Label("正在打印和显影", systemImage: "printer.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    } else if currentEntry.cardState == .failed {
                        Button(action: retryGeneration) {
                            Label("生成失败，可重试", systemImage: "arrow.clockwise")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Label("正在分析这一刻…", systemImage: "sparkles")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .clipped()
        .navigationTitle("情绪卡片")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let openGallery {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("相册", action: openGallery)
                }
            }
        }
        .onDisappear {
            // 返回即重拍：没点保存就离开，这张照片和记录一起丢弃。
            if !didCommit, currentEntry.isDraft == true {
                store.discardDraft(id: currentEntry.id)
            }
        }
        .onAppear {
            guard !playsDevelopmentAnimation else { return }
            draftNote = currentEntry.note ?? ""
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                isShowingMoodEditor = true
            }
        }
        .sheet(isPresented: $isShowingMoodEditor) {
            PostDevelopmentMoodEditor(
                note: $draftNote,
                onSave: saveMoodDetails
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var currentEntry: MoodEntry {
        store.entries.first(where: { $0.id == entry.id }) ?? entry
    }

    private var selectedDateStyle: PolaroidDateStyle {
        PolaroidDateStyle(rawValue: dateStyleRawValue) ?? .localized
    }

    private var selectedDateFontStyle: PolaroidDateFontStyle {
        PolaroidDateFontStyle(rawValue: dateFontStyleRawValue) ?? .monospaced
    }

    private func flipCard() {
        guard canFlip else { return }
        MoodSoundEffect.cardFlip()
        withAnimation(.spring(response: 0.72, dampingFraction: 0.82)) {
            isFlipped.toggle()
        }
    }

    /// 显影完成后才开放填写，保证用户先完整看到吐纸与显影过程。
    private func developmentDidComplete() {
        developmentDidFinish = true
        draftNote = currentEntry.note ?? ""

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            isShowingMoodEditor = true
        }
    }

    private func saveMoodDetails() {
        let trimmedNote = draftNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = trimmedNote.isEmpty ? nil : trimmedNote

        if currentEntry.isDraft == true {
            // 这一步才让照片真正进入相册。心情不在这里定，交给 AI 识别；
            // 用户不满意可在卡片背面直接改（不传 emotion，userEmotion 保持为空，
            // 卡片显示时回退到 aiEmotion）。
            store.commitDraft(id: currentEntry.id, note: note, emotion: nil)
        } else {
            var updatedEntry = currentEntry
            updatedEntry.note = note
            store.update(updatedEntry)
        }
        didCommit = true
        isShowingMoodEditor = false
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func updateEmotion(_ emotion: Emotion) {
        var updatedEntry = currentEntry
        updatedEntry.userEmotion = emotion
        store.update(updatedEntry)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func retryGeneration() {
        var updatedEntry = currentEntry
        updatedEntry.cardState = .pending
        store.update(updatedEntry)

        Task { @MainActor in
            await generateMoodCard(
                entryID: updatedEntry.id,
                using: aiService,
                store: store,
                isNetworkConnected: networkMonitor.isConnected
            )
        }
    }
}

/// 产品中拍立得卡片翻面后展示 AI 总结、生成状态并允许用户修正情绪的背面。
struct EmotionCardBack: View {
    let entry: MoodEntry
    let dateText: String
    let dateFont: Font
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let updateEmotion: (Emotion) -> Void
    let flipBack: () -> Void

    private var effectiveEmotion: Emotion? {
        entry.userEmotion ?? entry.aiEmotion
    }

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MOOD ANALYSIS")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .tracking(1.8)
                    Text(entry.cardState.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(stateColor)
                }
                Spacer()
                Image(systemName: "sparkles")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color(red: 0.91, green: 0.30, blue: 0.50))
            }

            Spacer(minLength: 0)

            summaryContent

            Menu {
                ForEach(Emotion.allCases) { emotion in
                    Button {
                        updateEmotion(emotion)
                    } label: {
                        if effectiveEmotion == emotion {
                            Label(emotion.displayName, systemImage: "checkmark")
                        } else {
                            Text(emotion.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 9) {
                    Circle()
                        .fill(palette.capsule)
                        .frame(width: 12, height: 12)
                    Text(effectiveEmotion?.displayName ?? "选择情绪")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(palette.ink)
                .padding(.horizontal, 18)
                .frame(height: 48)
                .background(palette.capsule, in: Capsule())
            }

            Spacer(minLength: 0)

            HStack {
                Text(dateText)
                    .font(dateFont)
                    .foregroundStyle(.black.opacity(0.45))
                Spacer()
                Button(action: flipBack) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color(red: 0.72, green: 0.20, blue: 0.38))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("翻回照片正面")
            }
        }
        .padding(28)
        .frame(width: cardWidth, height: cardHeight)
        .background(
            palette.paper
        )
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(.white.opacity(0.72), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.20), radius: 14, y: 9)
    }

    @ViewBuilder
    private var summaryContent: some View {
        switch entry.cardState {
        case .pending:
            VStack(spacing: 12) {
                ProgressView()
                    .tint(Color(red: 0.91, green: 0.30, blue: 0.50))
                Text("正在感受这一刻…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        case .generated:
            if hasStructuredMoodCard {
                VStack(spacing: 18) {
                    Text(entry.encouragement ?? "")
                        .font(.system(size: 23, weight: .semibold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(palette.ink)

                    Text(entry.psychologyNote ?? "")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.black.opacity(0.62))
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "quote.opening")
                        .font(.title2)
                        .foregroundStyle(Color(red: 0.91, green: 0.30, blue: 0.50))
                    Text(entry.aiSummary ?? "今天的光看起来很温柔")
                        .font(.system(size: 24, weight: .semibold, design: .serif))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color(red: 0.22, green: 0.16, blue: 0.18))
                }
            }
        case .failed:
            ContentUnavailableView(
                "暂时没有生成成功",
                systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                description: Text("照片已经安全保存在本机。")
            )
        }
    }

    private var stateColor: Color {
        switch entry.cardState {
        case .pending: .orange
        case .generated: palette.ink
        case .failed: .red
        }
    }

    private var palette: MoodPalette {
        MoodPalette.resolve(entry.palette)
    }

    private var hasStructuredMoodCard: Bool {
        entry.moodCode != nil
            || entry.encouragement != nil
            || entry.psychologyNote != nil
            || entry.palette != nil
    }
}

/// 产品中仅在照片完成显影后出现的填写层：只写一句可选的话，心情交给 AI 识别。
private struct PostDevelopmentMoodEditor: View {
    @Binding var note: String
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("给这一刻写一句话")
                            .font(.headline)

                        TextField("可选，最多 120 字", text: $note, axis: .vertical)
                            .lineLimit(3...5)
                            .padding(14)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))

                        Text("\(note.count)/120")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(note.count > 120 ? .red : .secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    // 心情不再让用户手选：AI 会自动识别，不满意可以在卡片背面直接改。
                    Label("心情正在由 AI 识别，保存后可在卡片背面修改", systemImage: "sparkles")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)

                    Button(action: onSave) {
                        Label("保存心情卡片", systemImage: "heart.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color(red: 0.91, green: 0.30, blue: 0.50), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(note.count > 120)
                }
                .padding(20)
            }
            .navigationTitle("记录这一刻")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
