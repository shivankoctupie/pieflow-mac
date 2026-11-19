// Draws the PieFlow app icon (orange squircle, five ink bars) at every size iconutil needs.
// Usage: swift scripts/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o Assets/AppIcon.icns
// The first icon was thin ink bars on a cream tile: it vanished on a light Dock and in Finder lists.
// A solid accent tile with heavy bars reads on light and dark backgrounds and down to 16 px.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSColor(srgbRed: 0.961, green: 0.647, blue: 0.290, alpha: 1).setFill()   // Theme.accent, F5A54A
    bg.fill()
    // Fewer, heavier bars at small sizes so they stay separate instead of blurring into a block.
    let small = px <= 32
    let heights: [CGFloat] = small ? [0.34, 0.62, 0.44] : [0.26, 0.46, 0.32, 0.62, 0.38]
    let barW = rect.width * (small ? 0.15 : 0.092), gap = rect.width * (small ? 0.1 : 0.058)
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = rect.midX - total / 2
    NSColor(srgbRed: 0.102, green: 0.102, blue: 0.102, alpha: 1).setFill()   // Theme.ink, 1A1A1A
    for h in heights {
        let bh = rect.height * h
        let r = NSRect(x: x, y: rect.midY - bh / 2, width: barW, height: bh)
        NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
