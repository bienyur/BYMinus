import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MotionPhotoKind {
    case none, livePhoto, animatedImage

    var title: String {
        switch self {
        case .none: L10n.text("照片")
        case .livePhoto: L10n.text("实况照片")
        case .animatedImage: L10n.text("动态图")
        }
    }
}

/// 按需解码单帧，避免 UIImage.animatedImage 一次展开整个 GIF 导致内存激增。
/// ImageIO 的所有源读取都受同一把锁保护，可安全交给后台任务。
final class AnimatedImageSource: @unchecked Sendable {
    struct Frame: @unchecked Sendable {
        let image: CGImage
        let duration: TimeInterval
    }

    let frameCount: Int
    private let source: CGImageSource
    private let lock = NSLock()
    private let maximumPixelSize: Int

    static func isAnimated(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) else { return false }
        // 多页 HEIF / TIFF 不等于动图；只支持具有帧时长的 GIF 和 APNG。
        return [UTType.gif.identifier, UTType.png.identifier].contains(type as String)
            && CGImageSourceGetCount(source) > 1
    }

    init?(data: Data, maximumPixelSize: Int = 1_280) {
        guard Self.isAnimated(data),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        self.source = source
        self.frameCount = CGImageSourceGetCount(source)
        self.maximumPixelSize = max(1, maximumPixelSize)
    }

    func frame(at index: Int) -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        guard (0..<frameCount).contains(index) else { return nil }
        return autoreleasepool {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: false
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let png = properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
                ?? (png?[kCGImagePropertyAPNGUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (png?[kCGImagePropertyAPNGDelayTime] as? NSNumber)?.doubleValue
                ?? 0.1
            return Frame(image: image, duration: delay.isFinite && delay >= 0.02 ? delay : 0.1)
        }
    }
}
