import Foundation
import ImageIO
import UIKit

/// 产品中负责把拍摄或导入的照片保存到 App 本地文件目录的轻量文件存储器。
struct PhotoFileStore {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func save(_ image: UIImage, id: UUID) throws -> String {
        // 先把 EXIF 方向烘进像素，得到“按用户当时握持姿态摆正”的画面；
        // 若这时仍是横图，再顺时针转 90° 放上竖版相纸——与相册导入同一条规则。
        let normalizedImage = image.normalizedForStorage()
        let filmImage = normalizedImage.size.width > normalizedImage.size.height
            ? normalizedImage.rotatedClockwiseForPortraitFilm()
            : normalizedImage
        guard let data = filmImage.jpegData(compressionQuality: 0.9) else {
            throw PhotoFileStoreError.cannotCreateJPEG
        }

        let directoryURL = try makePhotoDirectory()
        let fileName = "\(id.uuidString).jpg"
        let fileURL = directoryURL.appendingPathComponent(fileName)
        try data.write(to: fileURL, options: .atomic)
        return fileName
    }

    /// 相册大图不完整解码进内存，直接用 ImageIO 将长边降到 2560 像素后再保存。
    func saveImportedData(
        _ data: Data,
        id: UUID,
        maxPixelSize: CGFloat = 2560,
        compressionQuality: CGFloat = 0.84
    ) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PhotoFileStoreError.cannotReadSource
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw PhotoFileStoreError.cannotCreateJPEG
        }

        // 相册导入没有传感器方向：先由 ImageIO 烘焙 EXIF；若实际像素仍为横图，
        // 再顺时针旋转 90°，最终以 .up 像素写进固定竖向相纸。
        let importedImage = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
        let filmImage = cgImage.width > cgImage.height
            ? importedImage.rotatedClockwiseForPortraitFilm()
            : importedImage
        guard let jpegData = filmImage.jpegData(
            compressionQuality: compressionQuality
        ) else {
            throw PhotoFileStoreError.cannotCreateJPEG
        }

        let directoryURL = try makePhotoDirectory()
        let fileName = "\(id.uuidString).jpg"
        try jpegData.write(
            to: directoryURL.appendingPathComponent(fileName),
            options: .atomic
        )
        return fileName
    }

    func delete(fileName: String) throws {
        let directoryURL = try makePhotoDirectory()
        let fileURL = directoryURL.appendingPathComponent(fileName)

        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }

    func exists(fileName: String) -> Bool {
        guard let fileURL = try? photoURL(fileName: fileName) else { return false }
        return fileManager.fileExists(atPath: fileURL.path)
    }

    func loadImage(fileName: String, maxPixelSize: CGFloat = 1600) -> UIImage? {
        guard let fileURL = try? photoURL(fileName: fileName) else { return nil }
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private func photoURL(fileName: String) throws -> URL {
        try makePhotoDirectory().appendingPathComponent(fileName)
    }

    private func makePhotoDirectory() throws -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directoryURL = baseURL
            .appendingPathComponent("MoodPolaroid", isDirectory: true)
            .appendingPathComponent("Photos", isDirectory: true)
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        return directoryURL
    }
}

/// 产品中照片文件无法转换为可落盘 JPEG 时使用的本地存储错误。
private enum PhotoFileStoreError: LocalizedError {
    case cannotReadSource
    case cannotCreateJPEG

    var errorDescription: String? {
        switch self {
        case .cannotReadSource: "无法读取照片原始文件。"
        case .cannotCreateJPEG: "无法生成可保存的照片文件。"
        }
    }
}

/// 产品中把 EXIF 旋转与镜像烘焙进像素，确保卡片和相册读取时方向一致。
extension UIImage {
    func normalizedForStorage() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 相册横图进入竖版胶片时固定顺时针转 90°，并把结果方向烘焙为 `.up`。
    func rotatedClockwiseForPortraitFilm() -> UIImage {
        let outputSize = CGSize(width: size.height, height: size.width)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: outputSize, format: format).image { context in
            let cgContext = context.cgContext
            cgContext.translateBy(x: outputSize.width / 2, y: outputSize.height / 2)
            cgContext.rotate(by: .pi / 2)
            draw(
                in: CGRect(
                    x: -size.width / 2,
                    y: -size.height / 2,
                    width: size.width,
                    height: size.height
                )
            )
        }
    }
}
