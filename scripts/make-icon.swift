// Renders Resources/AppIcon.icns. Usage: swift scripts/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.20, blue: 0.23, alpha: 1),
                        NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1)])!.draw(in: shape, angle: -90)

    // Text lines
    let left = rect.minX + rect.width * 0.2
    let lineH = rect.height * 0.055
    func bar(_ y: CGFloat, _ w: CGFloat, _ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: left, y: rect.minY + rect.height * y, width: rect.width * w, height: lineH),
                     xRadius: lineH / 2, yRadius: lineH / 2).fill()
    }
    bar(0.68, 0.42, NSColor(white: 1, alpha: 0.95))
    bar(0.54, 0.6, NSColor(white: 1, alpha: 0.38))
    bar(0.43, 0.5, NSColor(white: 1, alpha: 0.38))

    // Checkbox row
    let box = NSRect(x: left, y: rect.minY + rect.height * 0.24, width: rect.width * 0.11, height: rect.width * 0.11)
    let accent = NSColor(srgbRed: 1.0, green: 0.39, blue: 0.39, alpha: 1)
    accent.setFill()
    NSBezierPath(roundedRect: box, xRadius: box.width * 0.28, yRadius: box.width * 0.28).fill()
    let check = NSBezierPath()
    check.move(to: NSPoint(x: box.minX + box.width * 0.25, y: box.minY + box.height * 0.5))
    check.line(to: NSPoint(x: box.minX + box.width * 0.43, y: box.minY + box.height * 0.3))
    check.line(to: NSPoint(x: box.minX + box.width * 0.76, y: box.minY + box.height * 0.7))
    check.lineWidth = box.width * 0.14
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    NSColor.white.setStroke()
    check.stroke()
    NSColor(white: 1, alpha: 0.38).setFill()
    NSBezierPath(roundedRect: NSRect(x: box.maxX + rect.width * 0.06, y: box.midY - lineH / 2, width: rect.width * 0.33, height: lineH),
                 xRadius: lineH / 2, yRadius: lineH / 2).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
