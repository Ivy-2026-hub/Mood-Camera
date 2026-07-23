import Foundation

/// 产品的轻量本地数据层：内存中管理记录，并同步到应用支持目录下的 JSON 文件。
@MainActor
final class MoodEntryStore: ObservableObject {
    @Published private(set) var entries: [MoodEntry] = []
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
        var entry = newEntry
        assignWallLayoutIfNeeded(to: &entry, ordinal: nextWallOrdinal)
        let previousEntries = entries
        entries.append(entry)
        entries.sort { $0.createdAt > $1.createdAt }

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

    /// 删除后把剩余照片重新连续排布，照片墙不留空洞，相册页也按新顺序重新分页。
    private func reflowWallLayouts() {
        let rotations = [-3.5, 2.4, -1.2, 3.2, 1.0, -2.6]
        for index in entries.indices {
            entries[index].wallPositionX = index.isMultiple(of: 2) ? 0.27 : 0.73
            entries[index].wallPositionY = 135 + Double(index / 2) * 248
            entries[index].wallRotation = rotations[index % rotations.count]
            entries[index].wallZIndex = Double(index)
        }
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
