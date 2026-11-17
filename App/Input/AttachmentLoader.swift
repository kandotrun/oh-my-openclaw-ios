import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum AttachmentLoader {
    struct Loaded: Sendable {
        let data: Data
        let fileName: String
        let mimeType: String
    }

    enum Failure: LocalizedError {
        case tooLarge, invalidPhoto, unreadable
        var errorDescription: String? {
            switch self {
            case .tooLarge: "ファイルが大きすぎます。25 MB 未満のファイルを選んでください。"
            case .invalidPhoto: "この写真を読み込めませんでした。別の写真を選んでください。"
            case .unreadable: "ファイルを読み込めませんでした。アクセス権とダウンロード状態を確認してください。"
            }
        }
    }

    /// Decode only a thumbnail so a large camera original does not become a full-resolution bitmap.
    static func photo(data: Data) throws -> Loaded {
        guard data.count <= 40 * 1024 * 1024 else { throw Failure.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary),
              let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.84) else { throw Failure.invalidPhoto }
        guard jpeg.count <= 6 * 1024 * 1024 else { throw Failure.tooLarge }
        return Loaded(data: jpeg, fileName: "Photo-\(UUID().uuidString.prefix(8)).jpg", mimeType: "image/jpeg")
    }

    static func file(url: URL) throws -> Loaded {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile != false else { throw Failure.unreadable }
        guard let bytes = size.fileSize, bytes <= 25 * 1024 * 1024 else { throw Failure.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 25 * 1024 * 1024 else { throw Failure.tooLarge }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return Loaded(data: data, fileName: url.lastPathComponent, mimeType: mime)
    }
}
