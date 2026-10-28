// Draws Resources/AppIcon.icns: a dark rounded square with a mouse glyph and a soft glide arc.
// Run: swift scripts/make-icon.swift
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)
    // macOS grid: 824 pt rounded square, radius ~185, soft shadow
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    let path = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.22, alpha: 1),
                        NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.10, alpha: 1)])!.draw(in: path, angle: -90)
    ctx.restoreGState()
    // glide arc
    let arc = NSBezierPath()
    arc.move(to: NSPoint(x: 230, y: 300))
    arc.curve(to: NSPoint(x: 800, y: 760), controlPoint1: NSPoint(x: 330, y: 700), controlPoint2: NSPoint(x: 560, y: 790))
    arc.lineWidth = 34
    arc.lineCapStyle = .round
    NSColor(calibratedRed: 0.35, green: 0.62, blue: 1.0, alpha: 0.9).setStroke()
    arc.stroke()
    // mouse body
    let mouse = NSBezierPath(roundedRect: NSRect(x: 392, y: 250, width: 240, height: 380), xRadius: 120, yRadius: 120)
    NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
    mouse.fill()
    let split = NSBezierPath()
    split.move(to: NSPoint(x: 512, y: 630)); split.line(to: NSPoint(x: 512, y: 500))
    split.lineWidth = 10
    NSColor(calibratedWhite: 0.6, alpha: 1).setStroke()
    split.stroke()
    let wheel = NSBezierPath(roundedRect: NSRect(x: 497, y: 520, width: 30, height: 64), xRadius: 15, yRadius: 15)
    NSColor(calibratedRed: 0.35, green: 0.62, blue: 1.0, alpha: 1).setFill()
    wheel.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for px in sizes {
    let data = render(px)
    if px <= 512 { try! data.write(to: iconset.appendingPathComponent("icon_\(px)x\(px).png")) }
    if px >= 32 { try! data.write(to: iconset.appendingPathComponent("icon_\(px / 2)x\(px / 2)@2x.png")) }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print("wrote Resources/AppIcon.icns")
