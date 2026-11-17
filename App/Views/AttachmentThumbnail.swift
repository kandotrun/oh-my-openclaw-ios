import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Decode once per input change, off the main actor, at the size the UI needs.
struct AttachmentThumbnail: View {
    enum Presentation {
        case draft, message

        var maxPixelSize: Int { self == .draft ? 168 : 900 }
    }

    let data: Data
    let fileName: String
    let presentation: Presentation
    var loading = false
    var failed = false
    @State private var image: UIImage?
    @State private var decodedData: Data?
    @State private var decoding = false
    @State private var visible = false

    private struct Request: Hashable {
        let data: Data
        let maxPixelSize: Int
        let visible: Bool
    }

    var body: some View {
        Group {
            if decodedData == data, let image {
                if presentation == .draft {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipped()
                } else {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxWidth: 260, maxHeight: 240)
                }
            } else {
                VStack(spacing: 8) {
                    if loading || decoding || (!data.isEmpty && decodedData != data) { ProgressView() }
                    else { Image(systemName: failed ? "arrow.clockwise" : "photo").font(.title2).foregroundStyle(.secondary) }
                    if presentation == .message, !loading, !decoding {
                        if failed {
                            Text("タップして再試行").font(.caption).foregroundStyle(.secondary)
                        } else if !data.isEmpty, decodedData == data {
                            Text("画像を開く").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: presentation == .draft ? 56 : 230, height: presentation == .draft ? 56 : 150)
                .background(ChatTheme.secondaryCanvas)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: presentation == .draft ? 10 : 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fileName)
        .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
        .task(id: Request(data: data, maxPixelSize: presentation.maxPixelSize, visible: visible)) {
            guard visible, decodedData != data else { return }
            guard !data.isEmpty else { decoding = false; return }
            decoding = true
            let sourceData = data
            let maxPixelSize = presentation.maxPixelSize
            let thumbnail = await Task.detached(priority: .userInitiated) {
                Self.thumbnailData(sourceData, maxPixelSize: maxPixelSize)
            }.value
            guard !Task.isCancelled else { return }
            image = thumbnail.flatMap { UIImage(data: $0) }
            decodedData = data
            decoding = false
        }
    }

    private nonisolated static func thumbnailData(_ data: Data, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
