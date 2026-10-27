// 独立运行：swiftc TidyAlbum/AnimatedImageSource.swift tests/AnimatedImageSourceTests.swift -o /tmp/minus-animation-tests
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
enum AnimatedImageSourceTests {
    static func main() {
        let gif = makeData(type: UTType.gif, delays: [0.08, 0.24])
        precondition(AnimatedImageSource.isAnimated(gif))
        let source = AnimatedImageSource(data: gif, maximumPixelSize: 32)!
        precondition(source.frameCount == 2)
        let first = source.frame(at: 0)!
        let second = source.frame(at: 1)!
        precondition(first.image.width <= 32 && first.image.height <= 32)
        precondition(abs(first.duration - 0.08) < 0.001)
        precondition(abs(second.duration - 0.24) < 0.001)
        precondition(color(first.image)[0] > 200 && color(first.image)[2] < 10)
        precondition(color(second.image)[2] > 200 && color(second.image)[0] < 10)
        precondition(source.frame(at: -1) == nil && source.frame(at: 2) == nil)

        // 重复长按会从首帧重播；不能污染 ImageIO 源的读取顺序。
        for _ in 0..<100 {
            precondition(source.frame(at: 0) != nil && source.frame(at: 1) != nil)
        }
        let zeroDelayGIF = makeData(type: UTType.gif, delays: [0, 0])
        precondition(AnimatedImageSource(data: zeroDelayGIF)!.frame(at: 0)!.duration >= 0.02)

        let apng = makeData(type: UTType.png, delays: [0.12, 0.3])
        precondition(AnimatedImageSource.isAnimated(apng))
        let pngSource = AnimatedImageSource(data: apng)!
        precondition(pngSource.frameCount == 2)
        precondition(abs(pngSource.frame(at: 1)!.duration - 0.3) < 0.001)

        precondition(!AnimatedImageSource.isAnimated(makeData(type: UTType.png, delays: [0])))
        precondition(!AnimatedImageSource.isAnimated(makeData(type: UTType.gif, delays: [0])))
        precondition(!AnimatedImageSource.isAnimated(Data([0, 1, 2])))
        precondition(AnimatedImageSource(data: Data()) == nil)
        print("PASS: GIF/APNG detection, frame order, timing, downsampling, replay, invalid and static images")
    }

    private static func makeData(type: UTType, delays: [Double]) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, delays.count, nil)!
        for (index, delay) in delays.enumerated() {
            let context = CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 320,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: index == 0 ? 1 : 0, green: 0, blue: index == 0 ? 0 : 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
            let properties: [CFString: Any] = type == .gif
                ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]
                : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay]]
            CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func color(_ image: CGImage) -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel
    }
}
