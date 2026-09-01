// Renders GPTCleaner's app icon into an .iconset directory.
// Run via build.sh; produces PNGs that iconutil turns into AppIcon.icns.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ size: Int) -> Data? {
    let px = CGFloat(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    // violet void, matching the web app's --void / --panel2
    let rect = NSRect(x: 0, y: 0, width: px, height: px)
    let path = NSBezierPath(roundedRect: rect, xRadius: px * 0.22, yRadius: px * 0.22)
    NSGradient(colors: [
        NSColor(srgbRed: 0.17, green: 0.13, blue: 0.27, alpha: 1),
        NSColor(srgbRed: 0.09, green: 0.07, blue: 0.15, alpha: 1),
    ])?.draw(in: path, angle: -90)

    // hot magenta glow behind the ghost
    NSColor(srgbRed: 1.0, green: 0.31, blue: 0.64, alpha: 0.30).setFill()
    NSBezierPath(ovalIn: rect.insetBy(dx: px * 0.26, dy: px * 0.26)).fill()

    let ghost = "👻" as NSString
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: px * 0.56)]
    let bounds = ghost.size(withAttributes: attrs)
    ghost.draw(at: NSPoint(x: (px - bounds.width) / 2, y: (px - bounds.height) / 2 - px * 0.03),
               withAttributes: attrs)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// macOS iconset: each logical size at 1x and 2x.
for size in [16, 32, 64, 128, 256, 512] {
    if let data = render(size) {
        try? data.write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    }
    if let data = render(size * 2) {
        try? data.write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
    }
}
print("iconset written to \(out)")
