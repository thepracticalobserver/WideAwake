// Generates AppIcon.icns: `swiftc icon.swift -o /tmp/icon && /tmp/icon`
import AppKit

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let s = CGFloat(size)
    let inset = s * 0.098
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    // Drop shadow under the tile.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowBlurRadius = s * 0.025
    shadow.set()
    NSColor(red: 0.07, green: 0.075, blue: 0.095, alpha: 1).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    path.addClip()

    // Dark panel gradient, matching the popup.
    NSGradient(starting: NSColor(red: 0.15, green: 0.16, blue: 0.20, alpha: 1),
               ending: NSColor(red: 0.05, green: 0.055, blue: 0.07, alpha: 1))!
        .draw(in: rect, angle: -90)

    // Warm glow behind the bulb.
    let center = NSPoint(x: rect.midX, y: rect.midY + rect.height * 0.02)
    NSGradient(colors: [NSColor.yellow.withAlphaComponent(0.42), NSColor.orange.withAlphaComponent(0.10), .clear],
               atLocations: [0, 0.5, 1], colorSpace: .deviceRGB)!
        .draw(fromCenter: center, radius: 0, toCenter: center, radius: rect.width * 0.5, options: [])

    // Bulb: SF Symbol tinted with a yellow to orange gradient.
    let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.6, weight: .regular)
    if let symbol = NSImage(systemSymbolName: "lightbulb.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let h = rect.height * 0.56
        let w = h * symbol.size.width / symbol.size.height
        let bulbRect = NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2 + rect.height * 0.02, width: w, height: h)
        let tinted = NSImage(size: bulbRect.size, flipped: false) { r in
            symbol.draw(in: r)
            NSGraphicsContext.current?.compositingOperation = .sourceIn
            NSGradient(starting: NSColor(red: 1.0, green: 0.86, blue: 0.25, alpha: 1),
                       ending: NSColor(red: 1.0, green: 0.62, blue: 0.12, alpha: 1))!.draw(in: r, angle: -90)
            return true
        }
        tinted.draw(in: bulbRect)
    }
    NSGraphicsContext.restoreGraphicsState()

    // Hairline border.
    NSColor.white.withAlphaComponent(0.10).setStroke()
    path.lineWidth = max(1, s * 0.004)
    path.stroke()

    return rep.representation(using: .png, properties: [:])!
}

let dir = "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: dir)
try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in entries {
    try render(size: px).write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
}
