import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
}

func drawIcon() {
    let tile = NSBezierPath(roundedRect: NSRect(x: 86, y: 86, width: 852, height: 852),
                            xRadius: 203, yRadius: 203)
    NSGradient(starting: color(0.22, 0.53, 1), ending: color(0.06, 0.20, 0.58))?
        .draw(in: tile, angle: -70)

    let outline = NSBezierPath()
    for (x, y, dx, dy) in [(303, 744, 1, -1), (721, 744, -1, -1),
                            (303, 280, 1, 1), (721, 280, -1, 1)] {
        outline.move(to: NSPoint(x: x + dx * 117, y: y))
        outline.line(to: NSPoint(x: x, y: y))
        outline.line(to: NSPoint(x: x, y: y + dy * 117))
    }
    NSColor.white.withAlphaComponent(0.94).setStroke()
    outline.lineWidth = 34
    outline.lineJoinStyle = .round
    outline.lineCapStyle = .round
    outline.stroke()

    let pencil = NSBezierPath()
    let points = [NSPoint(x: 365, y: 379), NSPoint(x: 400, y: 510),
                  NSPoint(x: 600, y: 710), NSPoint(x: 693, y: 617),
                  NSPoint(x: 493, y: 417)]
    pencil.move(to: points[0])
    for point in points.dropFirst() { pencil.line(to: point) }
    pencil.close()
    color(1, 0.79, 0.32).setFill()
    pencil.fill()

    let tip = NSBezierPath()
    tip.move(to: points[0])
    tip.line(to: NSPoint(x: 380, y: 435))
    tip.line(to: NSPoint(x: 421, y: 397))
    tip.close()
    NSColor.white.setFill()
    tip.fill()
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fatalError("Could not create icon bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let factor = CGFloat(pixels) / 1024
        context.cgContext.scaleBy(x: factor, y: factor)
        drawIcon()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let filename = "icon_\(size)x\(size)\(suffix).png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(filename))
    }
}
