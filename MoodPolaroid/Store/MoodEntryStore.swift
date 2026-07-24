import Foundation

/// 产品的轻量本地数据层：内存中管理记录，并同步到应用支持目录下的 JSON 文件。
@MainActor
final class MoodEntryStore: ObservableObject {
    @Published private(set) var entries: [MoodEntry] = []

    /// 相册、图钉墙、相簿和张数统计只看已保存的记录，草稿一律不露面。
    var savedEntries: [MoodEntry] { entries.filter { $0.isDraft != true } }
    @Published private(set) var persistenceErrorMessage: String?
    @Published private(set) var missingPhotoEntryIDs: Set<MoodEntry.ID> = []

    private let fileURL: URL
    private var generationInFlight: Set<MoodEntry.ID> = []

    init(fileManager: FileManager = .default) {
        fileURL = Self.makeFileURL(fileManager: fileManager)
        load()
    }

    @discardableResult
    func add(_ newEntry: MoodEntry) -> Bool {
        let entry = newEntry
        let previousEntries = entries
        entries.append(entry)
        entries.sort { $0.createdAt > $1.createdAt }
        // 排好序后按“最新在最上”重排未被手动拖动过的照片；
        // 旧写法用 max(zIndex)+1 当序号，新照片反而被排到墙的最下面。
        reflowWallLayouts()

        guard save() else {
            entries = previousEntries
            return false
        }

        refreshPhotoIntegrity()

        return true
    }

    func update(_ entry: MoodEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        sortAndSave()
        refreshPhotoIntegrity()
    }

    /// 删除一条收藏时先持久化移除记录，再清理对应照片文件，避免重启后记录复活。
    @discardableResult
    func delete(id: MoodEntry.ID) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }) else { return true }
        let previousEntries = entries
        entries.removeAll { $0.id == id }
        reflowWallLayouts()
        missingPhotoEntryIDs.remove(id)
        generationInFlight.remove(id)

        guard save() else {
            entries = previousEntries
            refreshPhotoIntegrity()
            return false
        }

        do {
            try PhotoFileStore().delete(fileName: entry.imageFileName)
        } catch {
            persistenceErrorMessage = "记录已删除，但照片文件清理失败：\(error.localizedDescription)"
        }
        UserDefaults.standard.removeObject(
            forKey: "galleryCardFlipped.\(id.uuidString)"
        )
        refreshPhotoIntegrity()
        return true
    }

    func beginGeneration(id: MoodEntry.ID) -> Bool {
        guard !generationInFlight.contains(id) else { return false }
        generationInFlight.insert(id)
        return true
    }

    func endGeneration(id: MoodEntry.ID) {
        generationInFlight.remove(id)
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([MoodEntry].self, from: data)
            entries.sort { $0.createdAt > $1.createdAt }
            // 上次退出时还没点保存的草稿视为已放弃：连同照片文件一起清掉，
            // 避免留下相册里看不见、却一直占空间的孤儿记录。
            let staleDrafts = entries.filter { $0.isDraft == true }
            if !staleDrafts.isEmpty {
                let photoStore = PhotoFileStore()
                for draft in staleDrafts {
                    try? photoStore.delete(fileName: draft.imageFileName)
                }
                entries.removeAll { $0.isDraft == true }
                _ = save()
            }
            let didMigrateLayout = migrateMissingWallLayouts()
            if didMigrateLayout {
                save()
            }
            refreshPhotoIntegrity()
        } catch {
            persistenceErrorMessage = "读取本地记录失败：\(error.localizedDescription)"
        }
    }

    private func sortAndSave() {
        entries.sort { $0.createdAt > $1.createdAt }
        save()
    }

    private var nextWallOrdinal: Int {
        let highestZ = entries.compactMap(\.wallZIndex).max() ?? -1
        return Int(highestZ.rounded(.down)) + 1
    }

    private func migrateMissingWallLayouts() -> Bool {
        var didChange = false
        for index in entries.indices {
            let hadCompleteLayout = entries[index].wallPositionX != nil
                && entries[index].wallPositionY != nil
                && entries[index].wallRotation != nil
                && entries[index].wallZIndex != nil
            guard !hadCompleteLayout else { continue }
            assignWallLayoutIfNeeded(to: &entries[index], ordinal: index)
            didChange = true
        }
        return didChange
    }

    private func assignWallLayoutIfNeeded(to entry: inout MoodEntry, ordinal: Int) {
        let rotations = [-3.5, 2.4, -1.2, 3.2, 1.0, -2.6]
        if entry.wallPositionX == nil {
            entry.wallPositionX = ordinal.isMultiple(of: 2) ? 0.27 : 0.73
        }
        if entry.wallPositionY == nil {
            entry.wallPositionY = 135 + Double(ordinal / 2) * 248
        }
        if entry.wallRotation == nil {
            entry.wallRotation = rotations[ordinal % rotations.count]
        }
        if entry.wallZIndex == nil {
            entry.wallZIndex = Double(ordinal)
        }
    }

    /// 按“最新在最上”重排照片墙；用户亲手拖动过的照片保留自己的位置不被覆盖。
    private func reflowWallLayouts() {
        let rotations = [-3.5, 2.4, -1.2, 3.2, 1.0, -2.6]
        for index in entries.indices {
            // 草稿不进相册，也就不参与墙面排布。
            guard entries[index].isDraft != true else { continue }
            // 手动摆放过的照片只补缺失字段，位置与层级都听用户的。
            guard entries[index].wallIsManual != true else {
                if entries[index].wallRotation == nil {
                    entries[index].wallRotation = rotations[index % rotations.count]
                }
                if entries[index].wallZIndex == nil {
                    entries[index].wallZIndex = Double(entries.count - index)
                }
                continue
            }
            entries[index].wallPositionX = index.isMultiple(of: 2) ? 0.27 : 0.73
            entries[index].wallPositionY = 135 + Double(index / 2) * 248
            entries[index].wallRotation = rotations[index % rotations.count]
            // entries 是最新在前，越新层级越高，落在最上面。
            entries[index].wallZIndex = Double(entries.count - index)
        }
    }

    /// 用户点“保存心情卡片”：写入笔记与情绪，并把草稿转为正式记录进入相册。
    @discardableResult
    func commitDraft(id: UUID, note: String?, emotion: Emotion?) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        let previousEntries = entries
        entries[index].note = note
        entries[index].userEmotion = emotion
        entries[index].isDraft = nil
        reflowWallLayouts()

        guard save() else {
            entries = previousEntries
            return false
        }
        return true
    }

    /// 用户点返回/重拍：草稿连同照片文件一起删除，不进相册。
    @discardableResult
    func discardDraft(id: UUID) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }),
              entry.isDraft == true else { return false }
        let previousEntries = entries
        entries.removeAll { $0.id == id }
        try? PhotoFileStore().delete(fileName: entry.imageFileName)

        guard save() else {
            entries = previousEntries
            return false
        }
        return true
    }

    /// 整理照片墙：清掉所有“手动摆放”标记，全部按时间重新排布，最新的回到最上面。
    ///
    /// 拖动过的照片会一直待在用户放的位置，久了会挡住新照片的落点；
    /// 从顶部下拉刷新即可把整面墙重新码齐。
    @discardableResult
    func reorganizeWall() -> Bool {
        let previousEntries = entries
        for index in entries.indices {
            entries[index].wallIsManual = nil
        }
        reflowWallLayouts()

        guard save() else {
            entries = previousEntries
            return false
        }
        return true
    }

    /// 用户在照片墙上拖动一张照片后落位：记为手动摆放，并抬到最上层。
    @discardableResult
    func updateWallPosition(
        id: UUID,
        relativeX: Double,
        absoluteY: Double
    ) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        let previousEntries = entries
        let topZ = (entries.compactMap(\.wallZIndex).max() ?? 0) + 1
        entries[index].wallPositionX = min(0.95, max(0.05, relativeX))
        entries[index].wallPositionY = max(90, absoluteY)
        entries[index].wallZIndex = topZ
        entries[index].wallIsManual = true

        guard save() else {
            entries = previousEntries
            return false
        }
        return true
    }

    private func refreshPhotoIntegrity() {
        let photoStore = PhotoFileStore()
        missingPhotoEntryIDs = Set(
            entries
                .filter { !photoStore.exists(fileName: $0.imageFileName) }
                .map(\.id)
        )
        if missingPhotoEntryIDs.isEmpty {
            if persistenceErrorMessage?.hasPrefix("有 ") == true {
                persistenceErrorMessage = nil
            }
        } else {
            persistenceErrorMessage = "有 \(missingPhotoEntryIDs.count) 条记录找不到本地照片文件。"
        }
    }

    @discardableResult
    private func save() -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
            persistenceErrorMessage = nil
            return true
        } catch {
            persistenceErrorMessage = "保存本地记录失败：\(error.localizedDescription)"
            return false
        }
    }

    private static func makeFileURL(fileManager: FileManager) -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directoryURL = baseURL.appendingPathComponent("MoodPolaroid", isDirectory: true)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL.appendingPathComponent("mood_entries.json")
    }
}
