import SwiftUI

// MARK: - 情绪会话模型

/// 一次“情绪会话”：一张自拍（锚，定情绪基调）+ 若干顺着情绪补拍的照片。
/// 会话情绪由自拍与补拍综合得出（多数票，平票时以自拍为准）。
struct MoodSession: Identifiable {
    let id: String
    let anchor: MoodEntry
    let followups: [MoodEntry]

    var all: [MoodEntry] { [anchor] + followups }
    var createdAt: Date { anchor.createdAt }
    var photoCount: Int { all.count }

    /// 自拍 + 补拍综合出的情绪：所有成员里出现最多的情绪，平票以自拍为准。
    var emotion: Emotion? {
        let emotions = all.compactMap { $0.userEmotion ?? $0.aiEmotion }
        guard !emotions.isEmpty else { return anchor.userEmotion ?? anchor.aiEmotion }
        var tally: [Emotion: Int] = [:]
        for e in emotions { tally[e, default: 0] += 1 }
        let best = tally.max { a, b in
            if a.value != b.value { return a.value < b.value }
            // 平票：自拍的情绪优先
            return b.key == (anchor.userEmotion ?? anchor.aiEmotion)
        }
        return best?.key ?? (anchor.userEmotion ?? anchor.aiEmotion)
    }

    var palette: MoodPalette { MoodPalette.forEmotion(emotion) }
    var moodCode: String { anchor.moodCode ?? emotion?.displayName ?? "这一刻" }
    var encouragement: String? { anchor.encouragement }

    /// 把一批已保存记录按 sessionID 归成会话；没有 sessionID 的记录各自成一个单张会话。
    static func group(_ entries: [MoodEntry]) -> [MoodSession] {
        var byID: [String: [MoodEntry]] = [:]
        var order: [String] = []
        for e in entries {
            let key = e.sessionID ?? e.id.uuidString
            if byID[key] == nil { order.append(key) }
            byID[key, default: []].append(e)
        }
        return order.compactMap { key in
            let members = byID[key] ?? []
            guard !members.isEmpty else { return nil }
            // 锚 = 标了 anchor 的那张，否则取最早的一张
            let anchor = members.first { $0.sessionRole == "anchor" }
                ?? members.min { $0.createdAt < $1.createdAt }!
            let followups = members
                .filter { $0.id != anchor.id }
                .sorted { $0.createdAt < $1.createdAt }
            return MoodSession(id: key, anchor: anchor, followups: followups)
        }
    }
}

// MARK: - 情绪轨迹入口（情绪河流总览）

/// 长期情绪走势的“情绪河流”：每次会话是河上一个彩色节点，
/// 颜色=会话情绪、大小=照片数量，连成一条流动的带子——一眼看出情绪怎么流动。
struct MoodRiverScreen: View {
    let sessions: [MoodSession]        // 传入时约定：最新在前
    let onOpen: (MoodSession) -> Void
    let onClose: () -> Void

    private let store = PhotoFileStore()

    // 河流按时间正序绘制（最早在上、最新在下），读起来像“一路走到今天”。
    private var chronological: [MoodSession] { sessions.reversed() }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.11, blue: 0.16), Color(red: 0.06, green: 0.07, blue: 0.10)],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    header
                    if chronological.isEmpty {
                        emptyState
                    } else {
                        river
                    }
                }
                .padding(.bottom, 60)
            }
        }
    }

    private var header: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            Spacer()
            VStack(spacing: 2) {
                Text("情绪河流")
                    .font(.system(size: 17, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Text("\(chronological.count) 段记录 · 顺流而下是时间")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "drop.halffull")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white.opacity(0.4))
            Text("还没有情绪记录")
                .foregroundStyle(.white.opacity(0.6))
                .font(.system(size: 14, weight: .semibold))
        }
        .padding(.top, 120)
    }

    /// 河流主体：一条在左右之间蜿蜒的彩色带 + 每段会话的节点。
    private var river: some View {
        let rowH: CGFloat = 150
        let n = chronological.count
        return ZStack(alignment: .top) {
            // 底层：流动的彩色带（Canvas 画一条平滑曲线，颜色随情绪渐变）
            Canvas { ctx, size in
                guard n > 0 else { return }
                let midX = size.width / 2
                let amp = size.width * 0.24
                func x(_ i: Int) -> CGFloat { midX + amp * sin(CGFloat(i) * 0.9) }
                func y(_ i: Int) -> CGFloat { rowH / 2 + CGFloat(i) * rowH }

                var path = Path()
                path.move(to: CGPoint(x: x(0), y: y(0)))
                for i in 1..<n {
                    let p0 = CGPoint(x: x(i - 1), y: y(i - 1))
                    let p1 = CGPoint(x: x(i), y: y(i))
                    let midY = (p0.y + p1.y) / 2
                    path.addCurve(to: p1,
                                  control1: CGPoint(x: p0.x, y: midY),
                                  control2: CGPoint(x: p1.x, y: midY))
                }
                // 用整体情绪色做一条半透明的宽带
                let colors = chronological.map { $0.palette.capsule.opacity(0.55) }
                ctx.stroke(path,
                           with: .linearGradient(
                            Gradient(colors: colors.isEmpty ? [.gray] : colors),
                            startPoint: CGPoint(x: midX, y: 0),
                            endPoint: CGPoint(x: midX, y: y(n - 1))),
                           style: StrokeStyle(lineWidth: 26, lineCap: .round, lineJoin: .round))
            }
            .frame(height: rowH * CGFloat(max(1, n)))

            // 上层：每段会话一个可点节点
            GeometryReader { proxy in
                let midX = proxy.size.width / 2
                let amp = proxy.size.width * 0.24
                ForEach(Array(chronological.enumerated()), id: \.element.id) { i, session in
                    RiverNode(session: session, store: store)
                        .position(
                            x: midX + amp * sin(CGFloat(i) * 0.9),
                            y: rowH / 2 + CGFloat(i) * rowH
                        )
                        .onTapGesture { onOpen(session) }
                }
            }
            .frame(height: rowH * CGFloat(max(1, n)))
        }
        .padding(.horizontal, 8)
    }
}

/// 河流上的一个会话节点：情绪色的圆 + 自拍缩略 + 口令与日期。
private struct RiverNode: View {
    let session: MoodSession
    let store: PhotoFileStore
    @State private var thumb: UIImage?

    private var size: CGFloat { min(104, 64 + CGFloat(session.photoCount) * 10) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(session.palette.capsule)
                    .overlay(Circle().stroke(session.palette.ink.opacity(0.5), lineWidth: 2))
                    .shadow(color: session.palette.capsule.opacity(0.7), radius: 10)
                if let thumb {
                    Image(uiImage: thumb)
                        .resizable().scaledToFill()
                        .frame(width: size - 12, height: size - 12)
                        .clipShape(Circle())
                }
                if session.photoCount > 1 {
                    Text("\(session.photoCount)")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(session.palette.ink, in: Circle())
                        .offset(x: size / 2 - 8, y: -size / 2 + 8)
                }
            }
            .frame(width: size, height: size)

            Text(session.moodCode)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(session.createdAt.formatted(.dateTime.month().day()))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(width: 150)
        .task(id: session.anchor.imageFileName) {
            thumb = store.loadImage(fileName: session.anchor.imageFileName, maxPixelSize: 240)
        }
    }
}

// MARK: - 会话详情：主体屏 + 线索动线屏（上下翻页）

struct SessionDetailView: View {
    let session: MoodSession
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            TabView {
                SessionHeroScreen(session: session)
                SessionTrailScreen(session: session)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            Button(action: onClose) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(.black.opacity(0.28), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 18)
            .padding(.top, 12)
        }
    }
}

/// 第一屏 · 情绪主体：自拍占满屏 + 情绪主色 + 大字口令。
private struct SessionHeroScreen: View {
    let session: MoodSession
    @State private var image: UIImage?
    private let store = PhotoFileStore()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                session.palette.paper.ignoresSafeArea()

                if let image {
                    Image(uiImage: image)
                        .resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
                // 情绪主色从底部漫上来，压住照片下半，托住文字
                LinearGradient(
                    colors: [.clear, session.palette.ink.opacity(0.15),
                             session.palette.ink.opacity(0.82)],
                    startPoint: .center, endPoint: .bottom
                ).ignoresSafeArea()

                VStack(alignment: .leading, spacing: 10) {
                    Spacer()
                    Text(session.emotion?.displayName ?? "此刻")
                        .font(.system(size: 14, weight: .black, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.85))
                    Text(session.moodCode)
                        .font(.custom("Chalkboard SE", size: 40))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                    if let enc = session.encouragement {
                        Text(enc)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("左滑，看这一刻延展出的线索")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 8)
                    Spacer().frame(height: 40)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26)
            }
        }
        .task(id: session.anchor.imageFileName) {
            image = store.loadImage(fileName: session.anchor.imageFileName, maxPixelSize: 1400)
        }
    }
}

/// 第二屏 · 线索动线：补拍照片顺着一条曲线动线铺开，而不是网格。
private struct SessionTrailScreen: View {
    let session: MoodSession
    private let store = PhotoFileStore()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [session.palette.paper, session.palette.capsule.opacity(0.5)],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("这一刻的线索")
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundStyle(session.palette.ink)
                    Text("从「\(session.moodCode)」出发，顺着情绪拍下的")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(session.palette.ink.opacity(0.6))
                }
                .padding(.horizontal, 26)
                .padding(.top, 70)
                .padding(.bottom, 8)

                if session.followups.isEmpty {
                    Spacer()
                    Text("这次只留下了那张自拍")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(session.palette.ink.opacity(0.55))
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ScrollView {
                        // 动线：照片左右交错、由一条竖向连线串起，像走过的脚印
                        VStack(spacing: 0) {
                            ForEach(Array(session.followups.enumerated()), id: \.element.id) { i, entry in
                                TrailStop(entry: entry, index: i, palette: session.palette, store: store)
                            }
                        }
                        .padding(.vertical, 20)
                    }
                }
            }
        }
    }
}

/// 动线上的一站：一张补拍照片，左右交错摆放，前面连一段线。
private struct TrailStop: View {
    let entry: MoodEntry
    let index: Int
    let palette: MoodPalette
    let store: PhotoFileStore
    @State private var image: UIImage?

    private var onLeft: Bool { index % 2 == 0 }

    var body: some View {
        HStack {
            if !onLeft { connector }
            card
            if onLeft { connector }
        }
        .frame(maxWidth: .infinity, alignment: onLeft ? .leading : .trailing)
        .padding(.horizontal, 22)
    }

    private var connector: some View {
        VStack {
            Circle().fill(palette.ink).frame(width: 9, height: 9)
            Rectangle().fill(palette.ink.opacity(0.3)).frame(width: 2)
        }
        .frame(width: 30, height: 150)
    }

    private var card: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(white: 0.1)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .frame(width: 168, height: 168)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(7)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
            .rotationEffect(.degrees(onLeft ? -2.5 : 2.5))
            if let note = entry.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.ink.opacity(0.8))
                    .padding(.top, 8)
            }
        }
        .task(id: entry.imageFileName) {
            image = store.loadImage(fileName: entry.imageFileName, maxPixelSize: 500)
        }
    }
}
