import PhotosUI
import SwiftUI
import UIKit

/// 产品中同一批照片可选择的图钉墙或翻页拍立得相册展示方式。
private enum GalleryDisplayMode: String, CaseIterable, Identifiable {
    /// 上下分栏的入口选择页；进入相册先落在这里。
    case chooser
    case pinboard
    case album

    var id: Self { self }

    var displayName: String {
        switch self {
        case .chooser: "收藏"
        case .pinboard: "图钉墙"
        case .album: "相簿"
        }
    }

    var systemImage: String {
        switch self {
        case .chooser: "rectangle.split.1x2.fill"
        case .pinboard: "pin.fill"
        case .album: "book.closed.fill"
        }
    }
}

/// 相簿分册规则：一周 7 天、每天 4 张，一本装满 28 张后自动开新的一本。
private enum AlbumCapacity {
    static let photosPerPage = 4
    static let pagesPerBook = 7
    static var photosPerBook: Int { photosPerPage * pagesPerBook }
}

/// 入口选择页两块可替换的背景图资源名；图片放进 Assets 后即可生效，无需改代码。
private enum GalleryEntryBackground {
    static let pinboard = "gallery_entry_pinboard"
    static let shelf = "gallery_entry_shelf"
}

/// 产品中让图钉墙和翻页相册共享同一批本地情绪照片的收藏页面。
struct GalleryView: View {
    @EnvironmentObject private var store: MoodEntryStore
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    let aiService: any AIService
    let openCapture: () -> Void

    @State private var selectedEntry: MoodEntry?
    @AppStorage("galleryDisplayMode") private var displayModeRawValue = GalleryDisplayMode.chooser.rawValue
    /// 当前打开的是第几本相簿（0 起）。
    @AppStorage("galleryCurrentBook") private var currentBookIndex = 0
    @AppStorage("galleryCurrentAlbumPage") private var currentAlbumPage = 0
    @State private var importedPhotoItem: PhotosPickerItem?
    @State private var isImporting = false
    @State private var importErrorMessage: String?
    @State private var entryPendingDeletion: MoodEntry?
    @State private var deletionErrorMessage: String?

    private let photoFileStore = PhotoFileStore()

    var body: some View {
        ZStack {
            galleryBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if displayMode != .chooser {
                    modeBackBar
                }

                if !store.missingPhotoEntryIDs.isEmpty {
                    missingPhotoBanner
                }

                if store.savedEntries.isEmpty {
                    emptyWall
                } else {
                    switch displayMode {
                    case .chooser:
                        galleryEntryChooser
                    case .pinboard:
                        photoWall
                    case .album:
                        albumView
                    }
                }
            }
        }
        .navigationTitle("照片收藏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Text("\(store.savedEntries.count) 张")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                PhotosPicker(selection: $importedPhotoItem, matching: .images) {
                    Label("导入", systemImage: "square.and.arrow.down")
                }
                .disabled(isImporting)

                Button("拍摄", systemImage: "camera", action: openCapture)
            }
        }
        .onChange(of: importedPhotoItem) { _, item in
            guard let item else { return }
            Task {
                await importPhoto(from: item)
            }
        }
        .onChange(of: store.savedEntries.count) { _, _ in
            clampAlbumIndices()
        }
        .onAppear {
            clampAlbumIndices()
        }
        .alert(
            "导入失败",
            isPresented: Binding(
                get: { importErrorMessage != nil },
                set: { if !$0 { importErrorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "")
        }
        .confirmationDialog(
            "删除这张照片和情绪记录？",
            isPresented: Binding(
                get: { entryPendingDeletion != nil },
                set: { if !$0 { entryPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) {
                deletePendingEntry()
            }
            Button("取消", role: .cancel) {
                entryPendingDeletion = nil
            }
        } message: {
            Text("照片文件、卡片内容和照片墙位置都会从本机删除，此操作无法撤销。")
        }
        .alert(
            "删除失败",
            isPresented: Binding(
                get: { deletionErrorMessage != nil },
                set: { if !$0 { deletionErrorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(deletionErrorMessage ?? "")
        }
        .fullScreenCover(item: $selectedEntry) { entry in
            GalleryPhotoDetail(entry: entry)
        }
    }

    @ViewBuilder
    private var galleryBackground: some View {
        switch displayMode {
        case .chooser:
            Color(white: 0.94)
        case .pinboard:
            PhotoWallBackground()
        case .album:
            LinearGradient(
                colors: [Color(red: 0.17, green: 0.10, blue: 0.07), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    /// 进入图钉墙或相簿之后，顶部一条返回选择页的横条。
    private var modeBackBar: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    displayModeRawValue = GalleryDisplayMode.chooser.rawValue
                }
            } label: {
                Label("收藏", systemImage: "chevron.left")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .buttonStyle(.plain)

            Spacer()

            Text(displayMode == .album ? albumBookSubtitle : "图钉墙")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var displayMode: GalleryDisplayMode {
        GalleryDisplayMode(rawValue: displayModeRawValue) ?? .chooser
    }

    /// 删除照片后册数和页数都可能缩水，统一钳回合法范围，避免出现空册空页。
    private func clampAlbumIndices() {
        currentBookIndex = min(max(0, currentBookIndex), max(0, albumBooks.count - 1))
        currentAlbumPage = min(max(0, currentAlbumPage), max(0, albumPages.count - 1))
    }

    private var displayModeBinding: Binding<GalleryDisplayMode> {
        Binding(
            get: { displayMode },
            set: { displayModeRawValue = $0.rawValue }
        )
    }

    private var missingPhotoBanner: some View {
        Label(
            "有 \(store.missingPhotoEntryIDs.count) 张照片文件缺失，记录仍已保留",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .background(Color.orange.opacity(0.92))
    }

    private var photoWall: some View {
        ScrollView {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    // 有照片被挪动过才提示，等于告诉用户“这面墙现在可以整理一下”。
                    if hasManuallyPlacedPhotos {
                        Label("下拉整理照片墙", systemImage: "arrow.down")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.black.opacity(0.42))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(.white.opacity(0.62), in: Capsule())
                            .position(x: proxy.size.width / 2, y: 26)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }

                    ForEach(store.savedEntries) { entry in
                        PinnedPhoto(
                            entry: entry,
                            rotation: entry.wallRotation ?? 0,
                            showDetail: { selectedEntry = entry },
                            requestDelete: { entryPendingDeletion = entry },
                            commitDrag: { translation in
                                let width = max(1, proxy.size.width)
                                let currentX = width * (entry.wallPositionX ?? 0.5)
                                let currentY = entry.wallPositionY ?? 135
                                store.updateWallPosition(
                                    id: entry.id,
                                    relativeX: (currentX + translation.width) / width,
                                    absoluteY: currentY + translation.height
                                )
                            }
                        )
                        .position(
                            x: proxy.size.width * (entry.wallPositionX ?? 0.5),
                            y: entry.wallPositionY ?? 135
                        )
                        .zIndex(entry.wallZIndex ?? 0)
                    }
                }
                .animation(
                    .spring(response: 0.48, dampingFraction: 0.82),
                    value: store.savedEntries.map(\.id)
                )
                // 整理后照片要看得见地飞回各自的位置，而不是瞬间跳过去。
                .animation(
                    .spring(response: 0.55, dampingFraction: 0.78),
                    value: wallLayoutSignature
                )
            }
            .frame(height: wallContentHeight)
        }
        // 从顶部下拉即可把整面墙重新码齐——拖动过的照片久了会挡住新照片的落点。
        .refreshable {
            await reorganizeWall()
        }
    }

    /// 是否有照片被用户亲手挪动过——只有这时整理才有意义。
    private var hasManuallyPlacedPhotos: Bool {
        store.savedEntries.contains { $0.wallIsManual == true }
    }

    /// 墙面布局的指纹：任意一张照片的位置或层级变化都会触发重排动画。
    private var wallLayoutSignature: String {
        store.savedEntries
            .map { "\($0.id.uuidString.prefix(4))\($0.wallPositionX ?? 0)\($0.wallPositionY ?? 0)" }
            .joined()
    }

    /// 下拉刷新时整理照片墙：清掉手动摆放标记，全部按时间重新排布。
    @MainActor
    private func reorganizeWall() async {
        guard !store.savedEntries.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        store.reorganizeWall()
        // 留一点时间让下拉指示器收回、照片飞回位的动画放完。
        try? await Task.sleep(for: .milliseconds(520))
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private var wallContentHeight: CGFloat {
        let largestY = store.savedEntries.compactMap(\.wallPositionY).max() ?? 135
        return max(520, largestY + 150)
    }

    private var albumView: some View {
        VStack(spacing: 8) {
            ZStack {
                AlbumLeatherCover()

                PlasticAlbumPager(
                    pages: albumPages,
                    currentPage: $currentAlbumPage,
                    requestDelete: { entryPendingDeletion = $0 }
                ) { entry in
                    selectedEntry = entry
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 24)
            }

            HStack(spacing: 6) {
                ForEach(albumPages.indices, id: \.self) { index in
                    Capsule()
                        .fill(index == currentAlbumPage ? .white : .white.opacity(0.28))
                        .frame(width: index == currentAlbumPage ? 18 : 6, height: 6)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: currentAlbumPage)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    /// 按 28 张一本分册；最新的照片在第一本。
    private var albumBooks: [[MoodEntry]] {
        let size = AlbumCapacity.photosPerBook
        guard !store.savedEntries.isEmpty else { return [] }
        return stride(from: 0, to: store.savedEntries.count, by: size).map { start in
            let end = min(start + size, store.savedEntries.count)
            return Array(store.savedEntries[start..<end])
        }
    }

    /// 当前这一本里的照片；册号越界时退回第一本。
    private var currentBookEntries: [MoodEntry] {
        let books = albumBooks
        guard !books.isEmpty else { return [] }
        return books[min(max(0, currentBookIndex), books.count - 1)]
    }

    /// 只在当前这一本内部按每页 4 张分页，翻页不会跨册。
    private var albumPages: [[MoodEntry]] {
        let entries = currentBookEntries
        let size = AlbumCapacity.photosPerPage
        guard !entries.isEmpty else { return [] }
        return stride(from: 0, to: entries.count, by: size).map { start in
            let end = min(start + size, entries.count)
            return Array(entries[start..<end])
        }
    }

    /// 顶部横条上显示的册号与日期范围。
    private var albumBookSubtitle: String {
        let books = albumBooks
        guard !books.isEmpty else { return "相簿" }
        let index = min(max(0, currentBookIndex), books.count - 1)
        let entries = books[index]
        guard let newest = entries.first?.createdAt,
              let oldest = entries.last?.createdAt else {
            return "第 \(index + 1) 本"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        let range = entries.count == 1
            ? formatter.string(from: newest)
            : "\(formatter.string(from: oldest)) – \(formatter.string(from: newest))"
        return "第 \(index + 1) 本 · \(range) · \(entries.count)/\(AlbumCapacity.photosPerBook)"
    }

    /// 上下分栏的入口选择页：上半图钉墙预览，下半书架相簿。
    private var galleryEntryChooser: some View {
        GeometryReader { proxy in
            VStack(spacing: 12) {
                GalleryEntryPanel(
                    title: "图钉墙",
                    subtitle: "\(store.savedEntries.count) 张",
                    systemImage: "pin.fill",
                    backgroundImageName: GalleryEntryBackground.pinboard
                ) {
                    PinboardMiniPreview(entries: Array(store.savedEntries.prefix(6)))
                } action: {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        displayModeRawValue = GalleryDisplayMode.pinboard.rawValue
                    }
                }

                GalleryEntryPanel(
                    title: "相簿",
                    subtitle: "\(albumBooks.count) 本 · 每本 \(AlbumCapacity.photosPerBook) 张",
                    systemImage: "books.vertical.fill",
                    backgroundImageName: GalleryEntryBackground.shelf
                ) {
                    BookshelfMiniPreview(
                        bookCount: albumBooks.count,
                        selectedIndex: min(currentBookIndex, max(0, albumBooks.count - 1))
                    ) { index in
                        currentBookIndex = index
                        currentAlbumPage = 0
                        withAnimation(.easeInOut(duration: 0.22)) {
                            displayModeRawValue = GalleryDisplayMode.album.rawValue
                        }
                    }
                } action: {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        displayModeRawValue = GalleryDisplayMode.album.rawValue
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var emptyWall: some View {
        ContentUnavailableView {
            Label("照片墙还是空的", systemImage: "pin")
        } description: {
            Text("拍摄后的情绪卡片会直接钉在这里。")
        } actions: {
            Button("拍第一张", action: openCapture)
                .buttonStyle(.borderedProminent)

            PhotosPicker(selection: $importedPhotoItem, matching: .images) {
                Label("从系统相册导入", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.bordered)
        }
    }

    @MainActor
    private func importPhoto(from item: PhotosPickerItem) async {
        isImporting = true
        defer {
            isImporting = false
            importedPhotoItem = nil
        }

        let entryID = UUID()
        var savedFileName: String?

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw GalleryImportError.cannotReadImage
            }

            let fileName = try photoFileStore.saveImportedData(data, id: entryID)
            savedFileName = fileName
            let entry = MoodEntry(
                id: entryID,
                createdAt: Date(),
                imageFileName: fileName,
                cameraStyle: .polaroid,
                cardState: .pending
            )

            guard store.add(entry) else {
                throw GalleryImportError.cannotSaveRecord
            }

            startAIGeneration(for: entry)
            selectedEntry = entry
        } catch {
            if let savedFileName {
                try? photoFileStore.delete(fileName: savedFileName)
            }
            importErrorMessage = error.localizedDescription
        }
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

    @MainActor
    private func deletePendingEntry() {
        guard let entry = entryPendingDeletion else { return }
        entryPendingDeletion = nil
        if selectedEntry?.id == entry.id {
            selectedEntry = nil
        }
        if !store.delete(id: entry.id) {
            deletionErrorMessage = store.persistenceErrorMessage ?? "无法删除这条记录。"
        }
    }

}

/// 产品中从照片墙导入图片时可能出现的本地读取或记录写入错误。
private enum GalleryImportError: LocalizedError {
    case cannotReadImage
    case cannotSaveRecord

    var errorDescription: String? {
        switch self {
        case .cannotReadImage: "无法读取这张照片，请换一张重试。"
        case .cannotSaveRecord: "照片已读取，但无法写入本地记录。"
        }
    }
}

/// 产品中承托透明相册页的深色皮革封套与车线细节。
private struct AlbumLeatherCover: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(red: 0.15, green: 0.12, blue: 0.11), Color(red: 0.025, green: 0.025, blue: 0.025)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .padding(7)
            }
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(.black.opacity(0.72))
                    .frame(width: 18)
                    .padding(.vertical, 14)
                    .shadow(color: .black, radius: 7, x: 5)
            }
            .shadow(color: .black.opacity(0.60), radius: 20, y: 12)
    }
}

/// 产品中使用 iOS 原生卷页引擎承载透明塑料相册页的 SwiftUI 桥接层。
private struct PlasticAlbumPager: UIViewControllerRepresentable {
    let pages: [[MoodEntry]]
    @Binding var currentPage: Int
    let requestDelete: (MoodEntry) -> Void
    let selectEntry: (MoodEntry) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: [.spineLocation: NSNumber(value: UIPageViewController.SpineLocation.min.rawValue)]
        )
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.isDoubleSided = false
        controller.view.backgroundColor = .clear
        context.coordinator.reloadControllersIfNeeded()

        if let initialController = context.coordinator.controllers.first {
            controller.setViewControllers([initialController], direction: .forward, animated: false)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.reloadControllersIfNeeded()

        guard context.coordinator.controllers.indices.contains(currentPage),
              let visibleController = controller.viewControllers?.first,
              let visibleIndex = context.coordinator.controllers.firstIndex(where: { $0 === visibleController }),
              visibleIndex != currentPage else { return }

        let direction: UIPageViewController.NavigationDirection = currentPage > visibleIndex ? .forward : .reverse
        controller.setViewControllers(
            [context.coordinator.controllers[currentPage]],
            direction: direction,
            animated: true
        )
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PlasticAlbumPager
        var controllers: [UIViewController] = []
        private var pageIDs: [[UUID]] = []

        init(parent: PlasticAlbumPager) {
            self.parent = parent
        }

        func reloadControllersIfNeeded() {
            let newPageIDs = parent.pages.map { $0.map(\.id) }
            if pageIDs == newPageIDs {
                // 记录数量不变时也刷新 rootView，保证心情与文字修改立即同步到透明相册。
                for (index, entries) in parent.pages.enumerated() {
                    guard controllers.indices.contains(index),
                          let hostingController = controllers[index] as? UIHostingController<PlasticAlbumSheet> else {
                        continue
                    }
                    hostingController.rootView = PlasticAlbumSheet(
                        entries: entries,
                        selectEntry: parent.selectEntry,
                        requestDelete: parent.requestDelete
                    )
                }
                return
            }
            pageIDs = newPageIDs
            controllers = parent.pages.map { entries in
                let hostingController = UIHostingController(
                    rootView: PlasticAlbumSheet(
                        entries: entries,
                        selectEntry: parent.selectEntry,
                        requestDelete: parent.requestDelete
                    )
                )
                hostingController.view.backgroundColor = .clear
                return hostingController
            }
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let index = controllers.firstIndex(where: { $0 === viewController }), index > 0 else {
                return nil
            }
            return controllers[index - 1]
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let index = controllers.firstIndex(where: { $0 === viewController }),
                  index + 1 < controllers.count else {
                return nil
            }
            return controllers[index + 1]
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            guard completed,
                  let visibleController = pageViewController.viewControllers?.first,
                  let index = controllers.firstIndex(where: { $0 === visibleController }) else { return }
            parent.currentPage = index
        }
    }
}

/// 产品中带焊接边、反光、插袋和卷起页角的透明塑料相册页。
private struct PlasticAlbumSheet: View {
    let entries: [MoodEntry]
    let selectEntry: (MoodEntry) -> Void
    let requestDelete: (MoodEntry) -> Void

    var body: some View {
        GeometryReader { proxy in
            let pocketWidth = max(112, (proxy.size.width - 45) / 2)

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.74)
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.72), lineWidth: 1.2)
                    }

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 14
                ) {
                    ForEach(0..<4, id: \.self) { slot in
                        PlasticPhotoPocket(
                            entry: entries.indices.contains(slot) ? entries[slot] : nil,
                            width: pocketWidth,
                            selectEntry: selectEntry,
                            requestDelete: requestDelete
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 22)

                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.42), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    .padding(7)

                HStack(spacing: 0) {
                    Spacer()
                    Rectangle()
                        .fill(.white.opacity(0.32))
                        .frame(width: 1)
                    Spacer()
                }
                VStack {
                    Spacer()
                    Rectangle()
                        .fill(.white.opacity(0.30))
                        .frame(height: 1)
                    Spacer()
                }

                LinearGradient(
                    colors: [.white.opacity(0.34), .clear, .white.opacity(0.10), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .allowsHitTesting(false)

                HStack(spacing: 18) {
                    ForEach(0..<6, id: \.self) { _ in
                        Circle()
                            .fill(.black.opacity(0.48))
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(.white.opacity(0.55), lineWidth: 1))
                    }
                }
                .rotationEffect(.degrees(90))
                .offset(x: -(proxy.size.width / 2) + 9)

                PageCornerLift()
                    .frame(width: 58, height: 58)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .shadow(color: .black.opacity(0.35), radius: 12, x: 5, y: 8)
        }
    }
}

/// 产品中透明塑料页上带开口、焊边和反光膜的单个照片插袋。
private struct PlasticPhotoPocket: View {
    let entry: MoodEntry?
    let width: CGFloat
    let selectEntry: (MoodEntry) -> Void
    let requestDelete: (MoodEntry) -> Void

    @AppStorage("polaroidDateStyle") private var dateStyleRawValue = PolaroidDateStyle.localized.rawValue
    @AppStorage("polaroidDateFontStyle") private var dateFontStyleRawValue = PolaroidDateFontStyle.monospaced.rawValue

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(.white.opacity(0.06))

            if let entry {
                GalleryFlippableCard(
                    entry: entry,
                    cardWidth: width - 12,
                    showDetail: { selectEntry(entry) },
                    requestDelete: { requestDelete(entry) }
                )
                .accessibilityLabel("轻点翻看情绪卡片，右上角可放大")
            }

            RoundedRectangle(cornerRadius: 5)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.28), .clear, .white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: 5)
                .stroke(.white.opacity(0.58), lineWidth: 1)
                .allowsHitTesting(false)

            VStack {
                Rectangle()
                    .fill(.white.opacity(0.74))
                    .frame(height: 1)
                Spacer()
                Capsule()
                    .fill(.white.opacity(0.30))
                    .frame(width: width * 0.62, height: 2)
                    .padding(.bottom, 4)
            }
            .allowsHitTesting(false)
        }
        .frame(width: width, height: width * 1.26)
    }
}

/// 产品中塑料页右下角轻微抬起、产生厚度和阴影的卷角细节。
private struct PageCornerLift: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Path { path in
                path.move(to: CGPoint(x: 58, y: 0))
                path.addQuadCurve(
                    to: CGPoint(x: 0, y: 58),
                    control: CGPoint(x: 44, y: 48)
                )
                path.addLine(to: CGPoint(x: 58, y: 58))
                path.closeSubpath()
            }
            .fill(
                LinearGradient(
                    colors: [.white.opacity(0.70), .white.opacity(0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .shadow(color: .black.opacity(0.28), radius: 7, x: -4, y: -4)
        }
        .allowsHitTesting(false)
    }
}

/// 产品中照片墙上的单张成品拍立得与顶部图钉组合。
private struct PinnedPhoto: View {
    let entry: MoodEntry
    let rotation: Double
    let showDetail: () -> Void
    let requestDelete: () -> Void
    /// 拖动结束后把落点交回上层保存；参数是相对墙宽的 X 与绝对 Y。
    var commitDrag: ((CGSize) -> Void)?

    @State private var dragTranslation: CGSize = .zero
    @State private var isDragging = false

    var body: some View {
        ZStack(alignment: .top) {
            GalleryFlippableCard(
                entry: entry,
                cardWidth: 150,
                showDetail: showDetail,
                requestDelete: requestDelete
            )

            PushPin()
                .offset(y: -7)
        }
        .padding(.top, 7)
        // 拖动时抬起、摆正、加深阴影，像把照片从墙上取下来拿在手里。
        .rotationEffect(.degrees(isDragging ? 0 : rotation))
        .scaleEffect(isDragging ? 1.06 : 1)
        .shadow(
            color: .black.opacity(isDragging ? 0.28 : 0),
            radius: isDragging ? 14 : 0,
            y: isDragging ? 10 : 0
        )
        // 位移必须瞬时跟手：offset 放在“拿起/放下”动画修饰器之后，
        // 并显式关掉它的隐式动画，否则位移会被卷进那条动画曲线，
        // 出现“图钉先动、照片两三秒后才追上”的割裂感。
        .animation(.easeOut(duration: 0.18), value: isDragging)
        .offset(dragTranslation)
        .animation(nil, value: dragTranslation)
        .zIndex(isDragging ? 1000 : (entry.wallZIndex ?? 0))
        .contentShape(Rectangle())
        .gesture(
            // 长按后才进入拖动，避免与轻点翻卡、滚动照片墙抢手势。
            LongPressGesture(minimumDuration: 0.28)
                .sequenced(before: DragGesture(coordinateSpace: .local))
                .onChanged { value in
                    guard case let .second(_, drag?) = value else { return }
                    if !isDragging {
                        isDragging = true
                        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    }
                    dragTranslation = drag.translation
                }
                .onEnded { _ in
                    guard isDragging else { return }
                    isDragging = false
                    let finalTranslation = dragTranslation
                    // 先把落点写进 store（position 一步到位），同一帧内再归零 offset，
                    // 关掉 offset 的隐式动画后二者叠加不会产生“先归零再飞过去”的闪动。
                    commitDrag?(finalTranslation)
                    dragTranslation = .zero
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
        )
        .accessibilityLabel("轻点翻看情绪卡片，长按可拖动摆放")
    }
}

/// 产品中照片墙与透明相册共同使用的可翻面成品卡片；静态查看不会重播显影。
private struct GalleryFlippableCard: View {
    let entry: MoodEntry
    let cardWidth: CGFloat
    let showDetail: (() -> Void)?
    let requestDelete: (() -> Void)?

    @AppStorage("polaroidDateStyle") private var dateStyleRawValue = PolaroidDateStyle.localized.rawValue
    @AppStorage("polaroidDateFontStyle") private var dateFontStyleRawValue = PolaroidDateFontStyle.monospaced.rawValue
    @AppStorage private var isFlipped: Bool

    init(
        entry: MoodEntry,
        cardWidth: CGFloat,
        showDetail: (() -> Void)?,
        requestDelete: (() -> Void)? = nil
    ) {
        self.entry = entry
        self.cardWidth = cardWidth
        self.showDetail = showDetail
        self.requestDelete = requestDelete
        _isFlipped = AppStorage(
            wrappedValue: false,
            "galleryCardFlipped.\(entry.id.uuidString)"
        )
    }

    private var cardHeight: CGFloat {
        PolaroidCard.cardHeight(for: entry, cardWidth: cardWidth)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                PolaroidCard(
                    entry: entry,
                    dateStyle: PolaroidDateStyle(rawValue: dateStyleRawValue) ?? .localized,
                    dateFontStyle: PolaroidDateFontStyle(rawValue: dateFontStyleRawValue) ?? .monospaced,
                    cardWidth: cardWidth,
                    playsDevelopmentAnimation: false
                )
                .opacity(isFlipped ? 0 : 1)
                .rotation3DEffect(
                    .degrees(isFlipped ? 180 : 0),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.74
                )

                CompactEmotionCardBack(entry: entry, cardWidth: cardWidth, cardHeight: cardHeight)
                    .opacity(isFlipped ? 1 : 0)
                    .rotation3DEffect(
                        .degrees(isFlipped ? 0 : -180),
                        axis: (x: 0, y: 1, z: 0),
                        perspective: 0.74
                    )
            }
            .frame(width: cardWidth, height: cardHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                MoodSoundEffect.cardFlip()
                withAnimation(.spring(response: 0.68, dampingFraction: 0.82)) {
                    isFlipped.toggle()
                }
            }

            if let showDetail {
                Button(action: showDetail) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: max(8, cardWidth * 0.07), weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: max(24, cardWidth * 0.19), height: max(24, cardWidth * 0.19))
                        .background(.black.opacity(0.62), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(max(5, cardWidth * 0.055))
                .accessibilityLabel("放大照片")
            }
        }
        .contextMenu {
            if let requestDelete {
                Button(role: .destructive, action: requestDelete) {
                    Label("删除照片和记录", systemImage: "trash")
                }
            }
        }
    }
}

/// 产品中收藏页卡片背面的紧凑心情摘要，适配照片墙和透明插袋的小尺寸。
private struct CompactEmotionCardBack: View {
    let entry: MoodEntry
    let cardWidth: CGFloat
    let cardHeight: CGFloat

    private var scale: CGFloat { max(0.72, min(1.5, cardWidth / 220)) }
    private var effectiveEmotion: Emotion? { entry.userEmotion ?? entry.aiEmotion }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            HStack {
                Text("MOOD CARD")
                    .font(.system(size: 10 * scale, weight: .black, design: .rounded))
                    .tracking(1.2 * scale)
                Spacer()
                Image(systemName: "heart.fill")
                    .font(.system(size: 12 * scale, weight: .bold))
                    .foregroundStyle(Color(red: 0.91, green: 0.30, blue: 0.50))
            }

            Spacer(minLength: 0)

            if hasStructuredMoodCard {
                Text(entry.encouragement ?? "")
                    .font(.system(size: 18 * scale, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.ink)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)

                Text(entry.psychologyNote ?? "")
                    .font(.system(size: 11 * scale, weight: .medium, design: .rounded))
                    .foregroundStyle(.black.opacity(0.62))
                    .lineLimit(5)
            } else {
                Text(effectiveEmotion?.displayName ?? "还没有选择心情")
                    .font(.system(size: 20 * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.45, green: 0.14, blue: 0.25))
                    .lineLimit(1)
                if let note = entry.note, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 12 * scale, weight: .medium, design: .rounded))
                        .lineLimit(cardWidth > 230 ? 3 : 2)
                }

                Text(entry.aiSummary ?? "正在感受这一刻…")
                    .font(.system(size: 13 * scale, weight: .semibold, design: .serif))
                    .foregroundStyle(.black.opacity(0.70))
                    .lineLimit(cardWidth > 230 ? 4 : 3)
            }

            Spacer(minLength: 0)

            HStack {
                Text(entry.createdAt.formatted(date: .numeric, time: .omitted))
                    .font(.system(size: 8 * scale, design: .monospaced))
                    .foregroundStyle(.black.opacity(0.45))
                Spacer()
                Image(systemName: "rotate.3d")
                    .font(.system(size: 11 * scale, weight: .bold))
                    .foregroundStyle(Color(red: 0.72, green: 0.20, blue: 0.38))
            }
        }
        .padding(16 * scale)
        .frame(width: cardWidth, height: cardHeight)
        .background(
            palette.paper
        )
        .clipShape(RoundedRectangle(cornerRadius: max(3, 5 * scale), style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: max(3, 5 * scale), style: .continuous)
                .stroke(.white.opacity(0.72), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.20), radius: 10 * scale, y: 6 * scale)
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

/// 产品中固定照片墙卡片的红色圆形图钉。
private struct PushPin: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.72, green: 0.08, blue: 0.12))
                .frame(width: 17, height: 17)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 2)

            Circle()
                .fill(.white.opacity(0.55))
                .frame(width: 5, height: 5)
                .offset(x: -3, y: -3)
        }
    }
}

/// 产品中提供软木色、细颗粒和接缝纹理的照片墙背景。
private struct PhotoWallBackground: View {
    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            context.fill(
                Path(bounds),
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.78, green: 0.58, blue: 0.37),
                        Color(red: 0.68, green: 0.46, blue: 0.28)
                    ]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: size.height)
                )
            )

            for x in stride(from: CGFloat(8), through: size.width, by: 22) {
                for y in stride(from: CGFloat(8), through: size.height, by: 22) {
                    let offset = Int(y / 22).isMultiple(of: 2) ? CGFloat(0) : 8
                    let dot = CGRect(x: x + offset, y: y, width: 1.5, height: 1.5)
                    context.fill(Path(ellipseIn: dot), with: .color(.black.opacity(0.12)))
                }
            }
        }
        .overlay(Color.white.opacity(0.05))
    }
}

/// 产品中点击照片墙卡片后展示的静态放大成品，不播放吐纸或显影。
private struct GalleryPhotoDetail: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: MoodEntryStore
    let entry: MoodEntry

    @AppStorage("polaroidDateStyle") private var dateStyleRawValue = PolaroidDateStyle.localized.rawValue
    @AppStorage("polaroidDateFontStyle") private var dateFontStyleRawValue = PolaroidDateFontStyle.monospaced.rawValue
    @State private var isConfirmingDeletion = false
    @State private var deletionErrorMessage: String?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [Color.black.opacity(0.92), Color(red: 0.16, green: 0.11, blue: 0.12)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                GalleryFlippableCard(
                    entry: currentEntry,
                    cardWidth: min(proxy.size.width - 44, 350),
                    showDetail: nil
                )

                VStack {
                    HStack {
                        Button {
                            isConfirmingDeletion = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 42, height: 42)
                                .background(.red.opacity(0.72), in: Circle())
                        }
                        .accessibilityLabel("删除照片和记录")

                        Spacer()

                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 42, height: 42)
                                .background(.white.opacity(0.14), in: Circle())
                        }
                        .accessibilityLabel("关闭放大照片")
                    }
                    Spacer()
                }
                .padding(18)
            }
        }
        .confirmationDialog(
            "删除这张照片和情绪记录？",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) {
                if store.delete(id: currentEntry.id) {
                    dismiss()
                } else {
                    deletionErrorMessage = store.persistenceErrorMessage ?? "无法删除这条记录。"
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("照片文件、卡片内容和照片墙位置都会从本机删除，此操作无法撤销。")
        }
        .alert(
            "删除失败",
            isPresented: Binding(
                get: { deletionErrorMessage != nil },
                set: { if !$0 { deletionErrorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(deletionErrorMessage ?? "")
        }
    }

    private var currentEntry: MoodEntry {
        store.savedEntries.first(where: { $0.id == entry.id }) ?? entry
    }
}

// MARK: - 相册入口选择页的三个组件

/// 上下分栏里的一块：可选中、可按压，背景图之后放进 Assets 即自动生效。
private struct GalleryEntryPanel<Preview: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    /// 背景图资源名；Assets 里没有这张图时自动退回纯色底，不影响功能。
    let backgroundImageName: String
    @ViewBuilder let preview: () -> Preview
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        ZStack {
            // 有背景图就用图，没有就用纯色占位，两种都不影响交互。
            if UIImage(named: backgroundImageName) != nil {
                Image(backgroundImageName)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color(white: 0.99), Color(white: 0.92)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }

            preview()
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 52)

            VStack {
                Spacer()
                HStack(spacing: 7) {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .bold))
                    Text(title)
                        .font(.system(size: 15, weight: .black, design: .rounded))
                    Text(subtitle)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.black.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(isPressed ? 0.06 : 0.12), radius: isPressed ? 4 : 10, y: isPressed ? 2 : 5)
        // 待选状态：按住轻微下沉并压暗，松开进入。
        .scaleEffect(isPressed ? 0.985 : 1)
        .brightness(isPressed ? -0.03 : 0)
        .animation(.easeOut(duration: 0.16), value: isPressed)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture(perform: action)
        .onLongPressGesture(minimumDuration: 0.6, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(subtitle)")
        .accessibilityAddTraits(.isButton)
    }
}

/// 图钉墙那一块里的缩小预览：用真实照片按墙面的错落感排一小片。
private struct PinboardMiniPreview: View {
    let entries: [MoodEntry]
    private let photoFileStore = PhotoFileStore()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    MiniPhotoThumb(entry: entry, store: photoFileStore)
                        .rotationEffect(.degrees(index.isMultiple(of: 2) ? -5 : 4))
                        .position(
                            x: proxy.size.width * (index.isMultiple(of: 2) ? 0.3 : 0.7),
                            y: 34 + CGFloat(index / 2) * 62
                        )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .clipped()
        }
    }
}

/// 书架那一块：一排可点选的相簿书脊，点某一本直接进那一本。
private struct BookshelfMiniPreview: View {
    let bookCount: Int
    let selectedIndex: Int
    let openBook: (Int) -> Void

    private let spineColors: [Color] = [
        Color(red: 0.45, green: 0.24, blue: 0.18),
        Color(red: 0.24, green: 0.33, blue: 0.42),
        Color(red: 0.40, green: 0.36, blue: 0.22),
        Color(red: 0.38, green: 0.26, blue: 0.36)
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            HStack(alignment: .bottom, spacing: 7) {
                ForEach(0..<max(1, bookCount), id: \.self) { index in
                    Button {
                        openBook(index)
                    } label: {
                        VStack(spacing: 4) {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .black, design: .rounded))
                                .foregroundStyle(.white.opacity(0.92))
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 8)
                        .frame(width: 26, height: index == selectedIndex ? 92 : 82)
                        .background(
                            spineColors[index % spineColors.count],
                            in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                        )
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(.white.opacity(0.16))
                                .frame(width: 2)
                        }
                        .shadow(color: .black.opacity(0.22), radius: 3, y: 2)
                    }
                    .buttonStyle(.plain)
                    .disabled(bookCount == 0)
                }
            }

            // 书架隔板
            Rectangle()
                .fill(Color(red: 0.36, green: 0.25, blue: 0.17))
                .frame(height: 7)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
        }
    }
}

/// 墙面缩略预览里的一张小照片。
private struct MiniPhotoThumb: View {
    let entry: MoodEntry
    let store: PhotoFileStore
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.white)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .padding(3)
                    .padding(.bottom, 9)
            }
        }
        .frame(width: 54, height: 64)
        .shadow(color: .black.opacity(0.16), radius: 3, y: 2)
        .task(id: entry.id) {
            image = store.loadImage(fileName: entry.imageFileName, maxPixelSize: 200)
        }
    }
}
