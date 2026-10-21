// 몬스터볼 앱 아이콘(Resources/AppIcon.icns)을 그린다: swift scripts/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS 아이콘 그리드: 바탕 사각형은 캔버스의 약 80%, 둥근 모서리.
    let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(white: 0.99, alpha: 1), NSColor(white: 0.9, alpha: 1)])!.draw(in: tilePath, angle: -90)

    let ball = tile.insetBy(dx: s * 0.12, dy: s * 0.12)
    let outline = NSColor(white: 0.12, alpha: 1)
    let line = s * 0.03
    let circle = NSBezierPath(ovalIn: ball)
    NSGraphicsContext.saveGraphicsState()
    circle.addClip()
    NSColor(srgbRed: 0.93, green: 0.22, blue: 0.2, alpha: 1).setFill()
    NSRect(x: ball.minX, y: ball.midY, width: ball.width, height: ball.height / 2).fill()
    NSColor.white.setFill()
    NSRect(x: ball.minX, y: ball.minY, width: ball.width, height: ball.height / 2).fill()
    outline.setFill()
    NSRect(x: ball.minX, y: ball.midY - line / 2, width: ball.width, height: line).fill()
    NSGraphicsContext.restoreGraphicsState()
    outline.setStroke()
    circle.lineWidth = line
    circle.stroke()
    let r = ball.width * 0.16
    let button = NSBezierPath(ovalIn: NSRect(x: ball.midX - r, y: ball.midY - r, width: r * 2, height: r * 2))
    NSColor.white.setFill()
    button.fill()
    button.lineWidth = line
    button.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: set.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: set.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
print("Resources/AppIcon.icns")
