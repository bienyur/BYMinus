// Minus 应用图标生成脚本。改完常量后执行 `swift design/GenerateIcon.swift` 重新导出 1024 图标。
// 用 CoreGraphics 直接画是为了保证对称和边缘精确，不依赖任何外部渲染器。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024

// 石墨主题取色
let background = CGColor(red: 0.067, green: 0.071, blue: 0.086, alpha: 1)
let accent = CGColor(red: 0.769, green: 0.937, blue: 0.290, alpha: 1)

/// 背后的照片卡。卡片必须填色，否则交叠处会露出对方的描边，多出一块杂形。
/// 按数组顺序从后往前画，前一张会盖住后一张。
struct Card {
    let offset: CGSize
    /// 顺时针为正，单位是度
    let tilt: CGFloat
    let fill: CGColor
    let stroke: CGColor
}

let cards: [Card] = [
    Card(
        offset: CGSize(width: -62, height: 10),
        tilt: -10,
        fill: CGColor(red: 0.082, green: 0.090, blue: 0.106, alpha: 1),
        stroke: CGColor(red: 0.141, green: 0.153, blue: 0.180, alpha: 1)
    ),
    Card(
        offset: CGSize(width: 28, height: -8),
        tilt: 4,
        fill: CGColor(red: 0.106, green: 0.114, blue: 0.133, alpha: 1),
        stroke: CGColor(red: 0.196, green: 0.212, blue: 0.243, alpha: 1)
    )
]

let cardSize = CGSize(width: 320, height: 430)
let cardRadius: CGFloat = 46
let cardLineWidth: CGFloat = 16

// 主角减号
let barSize = CGSize(width: 560, height: 120)

guard let context = CGContext(
    data: nil,
    width: Int(canvas),
    height: Int(canvas),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    // 图标不允许带 alpha，这里直接用不透明的位图
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    fatalError("无法创建绘图上下文")
}

context.setFillColor(background)
context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))

let center = canvas / 2
let cardRect = CGRect(
    x: -cardSize.width / 2,
    y: -cardSize.height / 2,
    width: cardSize.width,
    height: cardSize.height
)

context.setLineWidth(cardLineWidth)
for card in cards {
    context.setFillColor(card.fill)
    context.setStrokeColor(card.stroke)
    // 先绕自身中心旋转，再平移到目标位置
    var transform = CGAffineTransform(
        translationX: center + card.offset.width,
        y: center + card.offset.height
    ).rotated(by: -card.tilt * .pi / 180)
    guard let path = CGPath(
        roundedRect: cardRect,
        cornerWidth: cardRadius,
        cornerHeight: cardRadius,
        transform: &transform
    ) as CGPath? else { continue }
    context.addPath(path)
    context.drawPath(using: .fillStroke)
}

context.setFillColor(accent)
let barPath = CGPath(
    roundedRect: CGRect(
        x: center - barSize.width / 2,
        y: center - barSize.height / 2,
        width: barSize.width,
        height: barSize.height
    ),
    cornerWidth: barSize.height / 2,
    cornerHeight: barSize.height / 2,
    transform: nil
)
context.addPath(barPath)
context.fillPath()

guard let image = context.makeImage() else { fatalError("无法生成位图") }

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "TidyAlbum/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
let url = URL(fileURLWithPath: outputPath)

guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("无法写入 \(outputPath)")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("导出失败") }
print("已导出 \(outputPath)")
