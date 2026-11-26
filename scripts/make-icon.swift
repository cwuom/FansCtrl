// 生成 App 图标：swift scripts/make-icon.swift <输出目录>
// 输出 AppIcon.iconset/（供 iconutil 生成 .icns）和 icon-1024.png。
// 纯矢量绘制：SF Symbols 的许可不允许用于 App 图标，所以风扇叶片手绘。
import AppKit
import CoreGraphics

let canvas: CGFloat = 1024
// macOS 图标模板：824pt 主体居中，四周留出投影空间
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func white(_ a: CGFloat) -> CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: a) }

/// 连续曲率圆角矩形（超椭圆），与系统图标外形一致
func squircle(in r: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = r.width / 2, b = r.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = r.midX + a * (c >= 0 ? 1 : -1) * pow(abs(c), 2 / n)
        let y = r.midY + b * (s >= 0 ? 1 : -1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

/// 单片后掠叶片（极坐标构造，基准方向 +y），绕圆心旋转得到整组
func blade(count: Int) -> CGPath {
    let rootR: CGFloat = 80, tipR: CGFloat = 262
    let samples = 48
    func point(_ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: r * sin(a), y: r * cos(a)) }
    func sweep(_ t: CGFloat) -> CGFloat { -0.62 * pow(t, 1.35) }
    // 叶片从根部到叶尖逐渐变宽，留出均匀间隙
    func half(_ t: CGFloat) -> CGFloat { (0.17 + 0.13 * t) * 7 / CGFloat(count) }

    let p = CGMutablePath()
    for i in 0...samples {
        let t = CGFloat(i) / CGFloat(samples)
        let pt = point(rootR + (tipR - rootR) * t, sweep(t) + half(t))
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    // 圆润叶尖
    p.addQuadCurve(to: point(tipR, sweep(1) - half(1)), control: point(tipR + 26, sweep(1)))
    for i in stride(from: samples, through: 0, by: -1) {
        let t = CGFloat(i) / CGFloat(samples)
        p.addLine(to: point(rootR + (tipR - rootR) * t, sweep(t) - half(t)))
    }
    p.closeSubpath()
    return p
}

func draw(_ ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let shape = squircle(in: body)
    let center = CGPoint(x: canvas / 2, y: canvas / 2)

    // 投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 36, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x2B3FC4))
    ctx.fillPath()
    ctx.restoreGState()

    // 主体渐变：薄荷青 → 靛蓝
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [rgb(0x3FE3C8), rgb(0x2E8FE0), rgb(0x3A3DC9)] as CFArray,
                        locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 180, y: 940), end: CGPoint(x: 860, y: 90), options: [])
    // 左上柔光
    let glow = CGGradient(colorsSpace: space, colors: [white(0.38), white(0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 820), startRadius: 0,
                           endCenter: CGPoint(x: 330, y: 820), endRadius: 560, options: [])

    // 玻璃圆盘
    let disc = CGRect(x: center.x - 318, y: center.y - 318, width: 636, height: 636)
    ctx.saveGState()
    ctx.addEllipse(in: disc)
    ctx.clip()
    let discFill = CGGradient(colorsSpace: space, colors: [white(0.30), white(0.06)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(discFill, start: CGPoint(x: disc.minX, y: disc.maxY), end: CGPoint(x: disc.maxX, y: disc.minY), options: [])
    ctx.restoreGState()
    ctx.addEllipse(in: disc.insetBy(dx: 3, dy: 3))
    ctx.setStrokeColor(white(0.55))
    ctx.setLineWidth(6)
    ctx.strokePath()

    // 叶片
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: rgb(0x1B2380, 0.35))
    let bladeCount = 7
    for i in 0..<bladeCount {
        var t = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: CGFloat(i) * 2 * .pi / CGFloat(bladeCount))
        if let path = blade(count: bladeCount).copy(using: &t) {
            ctx.addPath(path)
        }
    }
    ctx.setFillColor(white(0.96))
    ctx.fillPath()
    ctx.restoreGState()

    // 轮毂
    let hub = CGRect(x: center.x - 92, y: center.y - 92, width: 184, height: 184)
    ctx.saveGState()
    ctx.addEllipse(in: hub)
    ctx.clip()
    let hubFill = CGGradient(colorsSpace: space, colors: [white(1), rgb(0xD5E4FF)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hubFill, start: CGPoint(x: hub.minX, y: hub.maxY), end: CGPoint(x: hub.maxX, y: hub.minY), options: [])
    ctx.restoreGState()
    ctx.addEllipse(in: hub.insetBy(dx: 64, dy: 64))
    ctx.setFillColor(rgb(0x3A55D6, 0.85))
    ctx.fillPath()

    // 顶部高光与玻璃描边
    let sheen = CGGradient(colorsSpace: space, colors: [white(0.28), white(0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY + 60), options: [])
    ctx.restoreGState()

    ctx.addPath(shape)
    ctx.setStrokeColor(white(0.35))
    ctx.setLineWidth(4)
    ctx.strokePath()
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    draw(ctx)
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon")
let iconset = out.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(size: 1024).write(to: out.appendingPathComponent("icon-1024.png"))
print("已生成 \(iconset.path)")
