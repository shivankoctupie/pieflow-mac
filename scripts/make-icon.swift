// Draws the PieFlow app icon (cream squircle, five ink bars) at every size iconutil needs.
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
    NSColor(srgbRed: 0.957, green: 0.949, blue: 0.933, alpha: 1).setFill()
    bg.fill()
    NSColor(srgbRed: 0.85, green: 0.83, blue: 0.80, alpha: 1).setStroke()
    bg.lineWidth = max(1, s * 0.004)
    bg.stroke()
    let heights: [CGFloat] = [0.30, 0.50, 0.36, 0.56, 0.40]
    let barW = rect.width * 0.075, gap = rect.width * 0.055
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = rect.midX - total / 2
    NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1).setFill()
    for (i, h) in heights.enumerated() {
        let bh = rect.height * h
        let r = NSRect(x: x, y: rect.midY - bh / 2, width: barW, height: bh)
        if i == 3 { NSColor(srgbRed: 0.96, green: 0.65, blue: 0.29, alpha: 1).setFill() } else { NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1).setFill() }
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
