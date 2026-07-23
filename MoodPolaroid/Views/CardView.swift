import SwiftUI
import UIKit

/// 产品中用来展示单条 MoodEntry 打印过程、正反面内容与用户情绪修正的卡片页。
struct CardView: View {
    @EnvironmentObject private var store: MoodEntryStore

    let entry: MoodEntry
    let openGallery: (() -> Void)?
    let playsDevelopmentAnimation: Bool

    @AppStorage("polaroidDateStyle") private var dateStyleRawValue = PolaroidDateStyle.localized.rawValue
    @AppStorage("polaroidDateFontStyle") private var dateFontStyleRawValue = PolaroidDateFontStyle.monospaced.rawValue
    @State private var isFlipped = false
    @State private var canFlip = false
    @State private var isShowingMoodEditor = false
    @State private var draftNote = ""
    @State private var draftEmotion: Emotion?

    init(
        entry: MoodEntry,
        openGallery: (() -> Void)?,
        playsDevelopmentAnimation: Bool = true
    ) {
        self.entry = entry
        self.openGallery = openGallery
        self.playsDevelopmentAnimation = playsDevelopmentAnimation
        _canFlip = State(initialValue: !playsDevelopmentAnimation)
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
                    } else if !canFlip {
                        Label("正在打印和显影", systemImage: "printer.fill")
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
        .onAppear {
            guard !playsDevelopmentAnimation else { return }
            draftNote = currentEntry.note ?? ""
            draftEmotion = currentEntry.userEmotion ?? currentEntry.aiEmotion
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                isShowingMoodEditor = true
            }
        }
        .sheet(isPresented: $isShowingMoodEditor) {
            PostDevelopmentMoodEditor(
                note: $draftNote,
                selectedEmotion: $draftEmotion,
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
        canFlip = true
        draftNote = currentEntry.note ?? ""
        draftEmotion = currentEntry.userEmotion ?? currentEntry.aiEmotion

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            isShowingMoodEditor = true
        }
    }

    private func saveMoodDetails() {
        var updatedEntry = currentEntry
        let trimmedNote = draftNote.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedEntry.note = trimmedNote.isEmpty ? nil : trimmedNote
        updatedEntry.userEmotion = draftEmotion
        store.update(updatedEntry)
        isShowingMoodEditor = false
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func updateEmotion(_ emotion: Emotion) {
        var updatedEntry = currentEntry
        updatedEntry.userEmotion = emotion
        store.update(updatedEntry)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
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
                        .fill(Color(red: 0.96, green: 0.52, blue: 0.66))
                        .frame(width: 12, height: 12)
                    Text(effectiveEmotion?.displayName ?? "选择情绪")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(Color(red: 0.40, green: 0.12, blue: 0.22))
                .padding(.horizontal, 18)
                .frame(height: 48)
                .background(Color(red: 1.0, green: 0.88, blue: 0.92), in: Capsule())
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
            LinearGradient(
                colors: [Color(red: 1.0, green: 0.98, blue: 0.94), Color(red: 0.98, green: 0.89, blue: 0.91)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
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
            VStack(spacing: 12) {
                Image(systemName: "quote.opening")
                    .font(.title2)
                    .foregroundStyle(Color(red: 0.91, green: 0.30, blue: 0.50))
                Text(entry.aiSummary ?? "今天的光看起来很温柔")
                    .font(.system(size: 24, weight: .semibold, design: .serif))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color(red: 0.22, green: 0.16, blue: 0.18))
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
        case .generated: .green
        case .failed: .red
        }
    }
}

/// 产品中仅在照片完成显影后出现的心情填写层。
private struct PostDevelopmentMoodEditor: View {
    @Binding var note: String
    @Binding var selectedEmotion: Emotion?
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

                    VStack(alignment: .leading, spacing: 12) {
                        Text("这一刻的心情")
                            .font(.headline)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88))], spacing: 10) {
                            ForEach(Emotion.allCases) { emotion in
                                Button {
                                    selectedEmotion = emotion
                                } label: {
                                    HStack(spacing: 7) {
                                        Circle()
                                            .fill(selectedEmotion == emotion ? Color.white : Color.pink.opacity(0.65))
                                            .frame(width: 9, height: 9)
                                        Text(emotion.displayName)
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    .foregroundStyle(selectedEmotion == emotion ? .white : Color.primary)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 42)
                                    .background(
                                        selectedEmotion == emotion
                                            ? Color(red: 0.91, green: 0.30, blue: 0.50)
                                            : Color.secondary.opacity(0.08),
                                        in: Capsule()
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

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
            .navigationTitle("记录显影后的心情")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
