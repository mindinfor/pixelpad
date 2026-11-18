import AppKit
import UniformTypeIdentifiers

// The canvas draws the glyphs. The editor keeps native selection, caret and input handling.
private final class EditingLayoutManager: NSLayoutManager {
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {}
}

private func makeTextLayout(layout: NSLayoutManager = NSLayoutManager()) -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
    let storage = NSTextStorage()
    let container = NSTextContainer(containerSize: NSSize(width: 100_000, height: 100_000))
    container.lineFragmentPadding = 0
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)
    return (storage, layout, container)
}

private extension NSRect {
    var pixelAligned: NSRect {
        let left = minX.rounded()
        let top = minY.rounded()
        return NSRect(x: left, y: top, width: maxX.rounded() - left, height: maxY.rounded() - top)
    }

    func scaled(by factor: CGFloat) -> NSRect {
        NSRect(x: minX * factor, y: minY * factor, width: width * factor, height: height * factor)
    }
}

struct Item {
    enum Content {
        case image(NSImage)
        case text(String, NSFont, NSColor)
        case stroke([NSPoint], NSColor, CGFloat, antialiased: Bool = false)
        case pixelStroke([NSPoint], NSColor, CGFloat, stampWidth: Int = 1)
        case rectangle(NSColor, CGFloat)
        case filledRectangle(NSColor)
        case ellipse(NSColor, CGFloat)
        case solid(NSColor)
        case raster(NSImage)
    }

    var content: Content
    var frame: NSRect
    var clip: NSRect? = nil

    static func text(_ string: String, font: NSFont, color: NSColor, at origin: NSPoint) -> Item {
        let size = (string as NSString).size(withAttributes: [.font: font])
        return Item(content: .text(string, font, color), frame: NSRect(
            origin: origin, size: NSSize(width: ceil(size.width) + 4, height: ceil(size.height) + 4)))
    }

    var isRectangle: Bool {
        switch content {
        case .rectangle, .filledRectangle: return true
        default: return false
        }
    }

    func scaled(by factor: CGFloat) -> Item {
        var result = self
        result.frame = frame.scaled(by: factor)
        result.clip = clip?.scaled(by: factor)
        switch content {
        case let .text(string, font, color):
            let font = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * factor) ?? font
            let text = Self.text(string, font: font, color: color, at: result.frame.origin)
            result.content = text.content
            result.frame = text.frame
        case let .pixelStroke(points, color, pixelSize, stampWidth):
            result.content = .pixelStroke(points, color, pixelSize * factor, stampWidth: stampWidth)
        case let .stroke(points, color, width, antialiased):
            result.content = .stroke(points.map { NSPoint(x: $0.x * factor, y: $0.y * factor) }, color, width * factor, antialiased: antialiased)
        case let .rectangle(color, width):
            result.content = .rectangle(color, width * factor)
        case let .ellipse(color, width):
            result.content = .ellipse(color, width * factor)
        default: break
        }
        if result.isRectangle && result.frame.width >= 1 && result.frame.height >= 1 {
            result.frame = result.frame.pixelAligned
        }
        return result
    }

    var isSelectable: Bool {
        switch content {
        case .stroke, .pixelStroke, .solid, .raster: return false
        default: return true
        }
    }

    func draw() {
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        defer { context?.restoreGState() }
        if let clip { context?.clip(to: clip) }
        switch content {
        case let .image(image), let .raster(image):
            image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case let .text(string, font, color):
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let (storage, layout, container) = makeTextLayout()
            storage.setAttributedString(NSAttributedString(string: string, attributes: attributes))
            withExtendedLifetime(storage) {
                layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: frame.origin)
            }
        case let .pixelStroke(points, color, pixelSize, stampWidth):
            context?.setShouldAntialias(false)
            color.setFill()
            let path = NSBezierPath()
            let offset = (stampWidth - 1) / 2
            let size = CGFloat(stampWidth) * pixelSize
            Self.tracePixels(points) { x, y in
                path.appendRect(NSRect(x: CGFloat(x - offset) * pixelSize, y: CGFloat(y - offset) * pixelSize,
                                       width: size, height: size))
            }
            path.fill()
        case let .stroke(points, color, width, antialiased):
            context?.setShouldAntialias(antialiased)
            guard let start = points.first else { return }
            color.setStroke()
            color.setFill()
            if points.count == 1 {
                NSBezierPath(ovalIn: NSRect(x: start.x - width / 2, y: start.y - width / 2,
                                            width: width, height: width)).fill()
                return
            }
            let path = NSBezierPath()
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: start)
            for point in points.dropFirst() { path.line(to: point) }
            if points.allSatisfy({ $0 == start }) {
                NSBezierPath(ovalIn: NSRect(x: start.x - width / 2, y: start.y - width / 2,
                                            width: width, height: width)).fill()
            } else {
                path.stroke()
            }
        case let .solid(color):
            color.setFill()
            frame.fill()
        case let .filledRectangle(color):
            context?.setShouldAntialias(false)
            color.setFill()
            frame.pixelAligned.fill()
        case let .ellipse(color, width):
            context?.setShouldAntialias(false)
            color.setStroke()
            let path = NSBezierPath(ovalIn: frame)
            path.lineWidth = width
            path.stroke()
        case let .rectangle(color, width):
            context?.setShouldAntialias(false)
            color.setFill()
            let thickness = max(1, width.rounded())
            let outer = frame.insetBy(dx: -thickness / 2, dy: -thickness / 2).pixelAligned
            let path = NSBezierPath(rect: outer)
            if outer.width > thickness * 2 && outer.height > thickness * 2 {
                path.appendRect(outer.insetBy(dx: thickness, dy: thickness))
            }
            path.windingRule = .evenOdd
            path.fill()
        }
    }
    private static func tracePixels(_ points: [NSPoint], visit: (Int, Int) -> Void) {
        guard let first = points.first else { return }
        var x = Int(floor(first.x))
        var y = Int(floor(first.y))
        visit(x, y)
        for point in points.dropFirst() {
            let endX = Int(floor(point.x))
            let endY = Int(floor(point.y))
            let dx = abs(endX - x)
            let dy = -abs(endY - y)
            let stepX = x < endX ? 1 : -1
            let stepY = y < endY ? 1 : -1
            var error = dx + dy
            while x != endX || y != endY {
                let doubled = 2 * error
                if doubled >= dy { error += dy; x += stepX }
                if doubled <= dx { error += dx; y += stepY }
                visit(x, y)
            }
        }
    }

}

struct Document {
    var size = NSSize(width: 1000, height: 650)
    var background: NSImage?
    var items: [Item] = []
    var backgroundSize: NSSize?
    var usesCentimeters = false

    static let pixelsPerCentimeter: CGFloat = 300 / 2.54
    var printSize: NSSize {
        let pointsPerPixel: CGFloat = 72 / 300
        return NSSize(width: size.width * pointsPerPixel, height: size.height * pointsPerPixel)
    }

    func resizedCanvas(to newSize: NSSize, scalingContentBy factor: CGFloat) -> Document {
        var result = self
        result.size = newSize
        if background != nil {
            let current = backgroundSize ?? size
            result.backgroundSize = NSSize(width: current.width * factor, height: current.height * factor)
        }
        if factor != 1 { result.items = items.map { $0.scaled(by: factor) } }
        return result
    }

    func draw(replacing index: Int? = nil, with draft: Item? = nil) {
        let bounds = NSRect(origin: .zero, size: size)
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        defer { context?.restoreGState() }
        context?.clip(to: bounds)
        if let background {
            let frame = NSRect(origin: .zero, size: backgroundSize ?? size)
            NSColor.white.setFill()
            if frame.maxX < bounds.maxX {
                NSRect(x: frame.maxX, y: 0, width: bounds.maxX - frame.maxX, height: bounds.height).fill()
            }
            if frame.maxY < bounds.maxY {
                NSRect(x: 0, y: frame.maxY, width: min(frame.width, bounds.width), height: bounds.maxY - frame.maxY).fill()
            }
            background.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            NSColor.white.setFill()
            bounds.fill()
        }
        for (itemIndex, item) in items.enumerated() {
            if itemIndex == index { draft?.draw() } else { item.draw() }
        }
        if index == nil { draft?.draw() }
    }

    func png() -> Data? {
        render(NSRect(origin: .zero, size: size))?.representation(using: .png, properties: [:])
    }

    func color(at point: NSPoint) -> NSColor? {
        let pixel = NSRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1)
        guard NSRect(origin: .zero, size: size).contains(pixel) else { return nil }
        return render(pixel)?.colorAt(x: 0, y: 0)
    }

    func image(in region: NSRect, replacing index: Int? = nil, text: Item? = nil,
               drawing draft: Item? = nil) -> NSImage? {
        guard let bitmap = Self.render(region, drawing: { _ in
            draw(replacing: index, with: text)
            draft?.draw()
        }) else { return nil }
        return Self.image(from: bitmap)
    }

    static func image(from bitmap: NSBitmapImageRep) -> NSImage {
        let image = NSImage(size: NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        image.addRepresentation(bitmap)
        return image
    }

    private static func bitmap(width: Int, height: Int) -> NSBitmapImageRep? {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)
    }

    func flood(at point: NSPoint, color: NSColor, within limit: NSRect) -> Item? {
        guard limit.contains(point), let source = render(limit),
              let data = source.bitmapData,
              let sample = Self.render(NSRect(x: 0, y: 0, width: 1, height: 1), drawing: { _ in
                  color.withAlphaComponent(1).setFill()
                  NSRect(x: 0, y: 0, width: 1, height: 1).fill()
              }), let sampleData = sample.bitmapData else { return nil }
        let width = source.pixelsWide
        let height = source.pixelsHigh
        let stride = source.bytesPerRow
        let startX = Int(floor(point.x - limit.minX))
        let startY = Int(floor(point.y - limit.minY))
        let start = startY * stride + startX * 4
        let target = UnsafeRawPointer(data).load(fromByteOffset: start, as: UInt32.self)
        let replacement = UnsafeRawPointer(sampleData).load(as: UInt32.self)
        guard target != replacement else { return nil }
        guard let mask = Self.bitmap(width: width, height: height), let pixels = mask.bitmapData else { return nil }
        memset(pixels, 0, mask.bytesPerRow * height)
        var stack = [startY * width + startX]
        var minX = startX, maxX = startX, minY = startY, maxY = startY
        while let index = stack.popLast() {
            let x = index % width
            let y = index / width
            let offset = y * stride + x * 4
            guard UnsafeRawPointer(data).load(fromByteOffset: offset, as: UInt32.self) == target else { continue }
            UnsafeMutableRawPointer(data).storeBytes(of: replacement, toByteOffset: offset, as: UInt32.self)
            UnsafeMutableRawPointer(pixels).storeBytes(of: replacement, toByteOffset: y * mask.bytesPerRow + x * 4, as: UInt32.self)
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
            if x > 0 { stack.append(index - 1) }
            if x + 1 < width { stack.append(index + 1) }
            if y > 0 { stack.append(index - width) }
            if y + 1 < height { stack.append(index + width) }
        }
        let bounds = NSRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let clipped = mask.cgImage?.cropping(to: bounds) else { return nil }
        let image = Self.image(from: NSBitmapImageRep(cgImage: clipped))
        return Item(content: .raster(image), frame: bounds.offsetBy(dx: limit.minX, dy: limit.minY))
    }

    func transformed(to size: NSSize, draw transform: (CGContext) -> Void) -> Document? {
        let bounds = NSRect(origin: .zero, size: size)
        guard let bitmap = Self.render(bounds, drawing: { context in
            transform(context)
            draw()
        }) else { return nil }
        return Document(size: size, background: Self.image(from: bitmap), usesCentimeters: usesCentimeters)
    }

    private func render(_ region: NSRect) -> NSBitmapImageRep? {
        Self.render(region) { _ in draw() }
    }

    private static func render(_ region: NSRect, drawing: (CGContext) -> Void) -> NSBitmapImageRep? {
        guard let bitmap = bitmap(width: Int(region.width), height: Int(region.height)),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let cg = context.cgContext
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        cg.translateBy(x: -region.minX, y: region.maxY)
        cg.scaleBy(x: 1, y: -1)
        cg.clear(region)
        cg.interpolationQuality = .none
        drawing(cg)
        return bitmap
    }
}

final class Canvas: NSView {
    var document = Document() { didSet { refreshSelection() } }
    var selected: Int? { didSet { refreshSelection() } }
    var selectionChanged: ((NSRect?) -> Void)?
    var fillRectangles = false
    var pixelBrush = true
    private var smoothBrush = false

    private func refreshSelection() {
        needsDisplay = true
        let itemFrame = selected.flatMap { document.items.indices.contains($0) ? document.items[$0].frame : nil }
        selectionChanged?(pixelSelection ?? itemFrame)
    }
    var changed: (() -> Void)?
    enum Tool: Int { case select, marquee, pencil, brush, eraser, fill, line, rectangle, ellipse, eyedropper, text }
    var pickColor: ((NSColor) -> Void)?
    var gestureZoom: ((CGFloat, NSPoint) -> Void)?
    private var marqueeOrigin: NSPoint?
    private var movingRegion: (start: NSPoint, region: NSRect, handle: ResizeHandle?)?
    private var canvasSelected = false
    private var canvasResize: (start: NSPoint, handle: ResizeHandle, before: Document)?
    var pixelSelection: NSRect? {
        didSet {
            if pixelSelection != imageBounds { canvasSelected = false }
            refreshSelection()
        }
    }

    func selectCanvas() {
        selected = nil
        canvasSelected = true
        pixelSelection = imageBounds
    }

    private var canvasHandleFrame: NSRect {
        imageBounds.insetBy(dx: min(5 / zoom, imageBounds.width / 4),
                            dy: min(5 / zoom, imageBounds.height / 4))
    }
    var imageBounds: NSRect { NSRect(origin: .zero, size: document.size) }
    var textDraft: (() -> (Int?, Item)?)? { didSet { needsDisplay = true } }
    var placeText: ((NSPoint) -> Void)?
    var finishText: (() -> Void)?
    var tool: Tool = .select { didSet { if tool != .marquee { canvasSelected = false }; if tool != .select { selected = nil } } }
    var editText: ((Int) -> Void)?
    var strokeColor = NSColor.black
    var strokeWidth: CGFloat = 4
    var zoomChanged: ((CGFloat) -> Void)?
    var zoom: CGFloat = 1 { didSet { updateSize(); zoomChanged?(zoom) } }
    private var drawingPoints: [NSPoint] = []
    private var draft: Item?
    private var past: [Document] = []
    private var future: [Document] = []
    private var drag: (start: NSPoint, item: Item, handle: ResizeHandle?, before: Document)?
    private var editedDuringDrag = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func updateSize() {
        setFrameSize(NSSize(width: document.size.width * zoom, height: document.size.height * zoom))
        (enclosingScrollView?.contentView as? CenteringClipView)?.repositionDocument()
        needsDisplay = true
    }

    func replace(_ newDocument: Document) {
        document = newDocument
        pixelSelection = nil
        selected = nil
        past.removeAll()
        future.removeAll()
        updateSize()
    }

    func record(_ previous: Document) {
        past.append(previous)
        if past.count > 50 { past.removeFirst() }
        future.removeAll()
        changed?()
    }

    @objc func undo(_ sender: Any?) {
        guard let previous = past.popLast() else { return }
        future.append(document)
        document = previous
        pixelSelection = nil
        updateSize()
        selected = nil
        changed?()
    }

    @objc func redo(_ sender: Any?) {
        guard let next = future.popLast() else { return }
        past.append(document)
        document = next
        pixelSelection = nil
        updateSize()
        selected = nil
        changed?()
    }

    func add(_ item: Item, select: Bool = true) {
        let previous = document
        document.items.append(item)
        selected = select ? document.items.indices.last : nil
        record(previous)
    }

    func update(_ item: Item, at index: Int) {
        let previous = document
        document.items[index] = item
        selected = index
        record(previous)
    }

    func transform(_ newDocument: Document) {
        let previous = document
        document = newDocument
        pixelSelection = nil
        selected = nil
        updateSize()
        record(previous)
    }

    func fillSelection(_ color: NSColor) {
        guard let region = pixelSelection else { NSSound.beep(); return }
        add(Item(content: .solid(color), frame: region), select: false)
    }

    func deleteSelected() {
        if pixelSelection != nil {
            fillSelection(.white)
            pixelSelection = nil
            return
        }
        guard let selected else { return }
        let previous = document
        document.items.remove(at: selected)
        self.selected = nil
        record(previous)
    }

    private enum ResizeHandle: CaseIterable {
        case topLeft, topRight, bottomRight, bottomLeft, top, right, bottom, left

        func point(in frame: NSRect) -> NSPoint {
            switch self {
            case .topLeft: return NSPoint(x: frame.minX, y: frame.minY)
            case .topRight: return NSPoint(x: frame.maxX, y: frame.minY)
            case .bottomRight: return NSPoint(x: frame.maxX, y: frame.maxY)
            case .bottomLeft: return NSPoint(x: frame.minX, y: frame.maxY)
            case .top: return NSPoint(x: frame.midX, y: frame.minY)
            case .right: return NSPoint(x: frame.maxX, y: frame.midY)
            case .bottom: return NSPoint(x: frame.midX, y: frame.maxY)
            case .left: return NSPoint(x: frame.minX, y: frame.midY)
            }
        }

        var oppositeCorner: ResizeHandle? {
            switch self {
            case .topLeft: return .bottomRight
            case .topRight: return .bottomLeft
            case .bottomRight: return .topLeft
            case .bottomLeft: return .topRight
            default: return nil
            }
        }
    }

    private func resizeHandles(for item: Item) -> [ResizeHandle] {
        if case .image = item.content { return ResizeHandle.allCases }
        return [.topLeft, .topRight, .bottomRight, .bottomLeft]
    }

    private func handle(_ point: NSPoint) -> NSRect {
        let radius = 4 / zoom
        return NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.scaleBy(x: zoom, y: zoom)
        let bounds = NSRect(origin: .zero, size: document.size)
        context.saveGState()
        context.clip(to: bounds)
        NSColor.white.setFill()
        bounds.fill()
        NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
        let step: CGFloat = 12
        let visible = NSRect(x: dirtyRect.minX / zoom, y: dirtyRect.minY / zoom, width: dirtyRect.width / zoom, height: dirtyRect.height / zoom)
        let area = bounds.intersection(visible)
        if !area.isEmpty {
            for row in Int(area.minY / step)...Int(area.maxY / step) {
                for col in Int(area.minX / step)...Int(area.maxX / step) where (row + col).isMultiple(of: 2) {
                    NSRect(x: CGFloat(col) * step, y: CGFloat(row) * step, width: step, height: step).fill()
                }
            }
        }
        let text = textDraft.flatMap { $0() }
        var drawing = draft
        drawing?.clip = pixelSelection
        if zoom >= 1, !area.isEmpty,
           let pixels = document.image(in: area.integral, replacing: text?.0, text: text?.1, drawing: drawing) {
            pixels.draw(in: area.integral, from: .zero, operation: .sourceOver, fraction: 1,
                        respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
        } else {
            document.draw(replacing: text?.0, with: text?.1)
            drawing?.draw()
        }
        if zoom >= 16 && !area.isEmpty {
            drawPixelGrid(in: area)
        }
        context.restoreGState()
        if let pixelSelection {
            let outline = NSBezierPath(rect: pixelSelection)
            outline.lineWidth = 1 / zoom
            NSColor.white.setStroke()
            outline.stroke()
            outline.setLineDash([4 / zoom, 3 / zoom], count: 2, phase: 0)
            NSColor.black.setStroke()
            outline.stroke()
            if tool == .marquee && marqueeOrigin == nil {
                drawResizeHandles(ResizeHandle.allCases, in: canvasSelected ? canvasHandleFrame : pixelSelection)
            }
        }
        guard let selected else { return }
        let item = document.items[selected]
        let frame = item.frame
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: frame)
        outline.lineWidth = 1 / zoom
        outline.stroke()
        drawResizeHandles(resizeHandles(for: item), in: frame)
    }

    private func drawPixelGrid(in area: NSRect) {
        let grid = NSBezierPath()
        grid.lineWidth = 0.75 / zoom
        for column in Int(ceil(area.minX))..<Int(ceil(area.maxX)) where column > 0 {
            let x = CGFloat(column)
            grid.move(to: NSPoint(x: x, y: area.minY))
            grid.line(to: NSPoint(x: x, y: area.maxY))
        }
        for row in Int(ceil(area.minY))..<Int(ceil(area.maxY)) where row > 0 {
            let y = CGFloat(row)
            grid.move(to: NSPoint(x: area.minX, y: y))
            grid.line(to: NSPoint(x: area.maxX, y: y))
        }
        NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 0.22).setStroke()
        grid.stroke()
    }

    private func drawResizeHandles(_ controls: [ResizeHandle], in frame: NSRect) {
        NSColor.controlAccentColor.setStroke()
        for control in controls {
            let box = handle(control.point(in: frame))
            NSColor.white.setFill()
            box.fill()
            let edge = NSBezierPath(rect: box)
            edge.lineWidth = 1 / zoom
            edge.stroke()
        }
    }

    private func point(_ event: NSEvent) -> NSPoint {
        let local = convert(event.locationInWindow, from: nil)
        return NSPoint(x: local.x / zoom, y: local.y / zoom)
    }

    override func magnify(with event: NSEvent) {
        gestureZoom?(max(0.01, 1 + event.magnification), event.locationInWindow)
    }

    override func mouseDown(with event: NSEvent) {
        let location = point(event)
        if tool == .eyedropper {
            if let color = document.color(at: location) { pickColor?(color) }
            return
        }
        if tool == .text {
            if textDraft != nil {
                finishText?()
                return
            }
            if NSRect(origin: .zero, size: document.size).contains(location) {
                placeText?(location)
            } else {
                finishText?()
            }
            return
        }
        finishText?()
        window?.makeFirstResponder(self)
        if let selected {
            let item = document.items[selected]
            if let control = resizeHandle(at: location, for: item) {
                drag = (location, item, control, document)
                editedDuringDrag = false
                return
            }
        }
        if tool == .marquee {
            if let selected {
                let item = document.items[selected]
                if item.frame.contains(location) {
                    drag = (location, item, nil, document)
                    editedDuringDrag = false
                    return
                }
                self.selected = nil
            }
            if canvasSelected, let control = resizeHandle(at: location, in: canvasHandleFrame, controls: ResizeHandle.allCases) {
                canvasResize = (event.locationInWindow, control, document)
                return
            }
            if let pixelSelection {
                let control = resizeHandle(at: location, in: pixelSelection, controls: ResizeHandle.allCases)
                if control != nil || pixelSelection.contains(location) {
                    movingRegion = (location, pixelSelection, control)
                    return
                }
            }
            pixelSelection = nil
            if imageBounds.contains(location) { marqueeOrigin = location }
            return
        }
        if tool == .fill {
            if let patch = document.flood(at: location, color: strokeColor, within: pixelSelection ?? imageBounds) {
                add(patch, select: false)
            }
            return
        }
        if tool != .select {
            guard NSRect(origin: .zero, size: document.size).contains(location) else { return }
            selected = nil
            smoothBrush = tool == .brush && !pixelBrush
            drawingPoints = [smoothBrush || tool == .rectangle || tool == .ellipse ? location : pixelCenter(location)]
            updateDraft(at: location)
            return
        }
        pixelSelection = nil
        selected = document.items.lastIndex { $0.isSelectable && $0.frame.contains(location) }
        if let selected {
            if event.clickCount == 2, case .text = document.items[selected].content {
                editText?(selected)
                return
            }
            drag = (location, document.items[selected], nil, document)
            editedDuringDrag = false
        }
    }

    private func resizeHandle(at location: NSPoint, for item: Item) -> ResizeHandle? {
        resizeHandle(at: location, in: item.frame, controls: resizeHandles(for: item))
    }

    private func resizeHandle(at location: NSPoint, in frame: NSRect, controls: [ResizeHandle]) -> ResizeHandle? {
        controls
            .filter { handle($0.point(in: frame)).insetBy(dx: -5 / zoom, dy: -5 / zoom).contains(location) }
            .min { first, second in
                let a = first.point(in: frame)
                let b = second.point(in: frame)
                return hypot(a.x - location.x, a.y - location.y) < hypot(b.x - location.x, b.y - location.y)
            }
    }

    private func pixelCenter(_ point: NSPoint) -> NSPoint {
        NSPoint(x: floor(point.x) + 0.5, y: floor(point.y) + 0.5)
    }

    private func updateDraft(at point: NSPoint) {
        guard let start = drawingPoints.first else { return }
        switch tool {
        case .select, .text, .eyedropper, .marquee, .fill: return
        case .pencil, .brush, .eraser:
            let color = tool == .eraser ? .white : strokeColor
            let sample = smoothBrush ? point : pixelCenter(point)
            if drawingPoints.last != sample { drawingPoints.append(sample) }
            let exactPixel = tool == .pencil || (tool == .brush && !smoothBrush)
            let stampWidth = tool == .pencil ? 1 : Int(strokeWidth)
            let content: Item.Content = exactPixel
                ? .pixelStroke(drawingPoints, color, 1, stampWidth: stampWidth)
                : .stroke(drawingPoints, color, strokeWidth, antialiased: smoothBrush)
            draft = Item(content: content, frame: .zero)
        case .line:
            let end = pixelCenter(point)
            let content: Item.Content = strokeWidth == 1
                ? .pixelStroke([start, end], strokeColor, 1)
                : .stroke([start, end], strokeColor, strokeWidth)
            draft = Item(content: content, frame: .zero)
        case .rectangle, .ellipse:
            let frame = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                               width: abs(start.x - point.x), height: abs(start.y - point.y))
            let shape: Item.Content
            if tool == .ellipse {
                shape = .ellipse(strokeColor, strokeWidth)
            } else if fillRectangles {
                shape = .filledRectangle(strokeColor)
            } else {
                shape = .rectangle(strokeColor, strokeWidth)
            }
            let aligned = frame.pixelAligned
            draft = aligned.isEmpty ? nil : Item(content: shape, frame: aligned)
        }
        needsDisplay = true
    }

    private func updateMarquee(to point: NSPoint) {
        guard let origin = marqueeOrigin else { return }
        let rect = NSRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                          width: abs(origin.x - point.x), height: abs(origin.y - point.y))
        let region = rect.integral.intersection(imageBounds)
        pixelSelection = region.isEmpty || rect.isEmpty ? nil : region
    }

    private func updateCanvasResize(with event: NSEvent) {
        guard let resize = canvasResize else { return }
        let original = resize.before.size
        let frame = NSRect(origin: .zero, size: original)
        let point = resize.handle.point(in: frame)
        let dx = (event.locationInWindow.x - resize.start.x) / zoom
        let dy = (resize.start.y - event.locationInWindow.y) / zoom
        let x = (point.x - frame.midX).sign == .minus ? -dx : dx
        let y = (point.y - frame.midY).sign == .minus ? -dy : dy
        let horizontal = resize.handle != .top && resize.handle != .bottom
        let vertical = resize.handle != .left && resize.handle != .right
        let width = horizontal ? original.width + x : original.width
        let height = vertical ? original.height + y : original.height
        let proportional = resize.handle.oppositeCorner != nil || event.modifierFlags.contains(.option)
        let maxSide: CGFloat = 16_384
        let maxArea: CGFloat = 64_000_000
        var factor: CGFloat = 1
        let size: NSSize
        if proportional {
            let candidate = ((horizontal ? width * original.width : 0) + (vertical ? height * original.height : 0))
                / ((horizontal ? original.width * original.width : 0) + (vertical ? original.height * original.height : 0))
            let limit = min(maxSide / original.width, maxSide / original.height, sqrt(maxArea / (original.width * original.height)))
            factor = min(limit, max(candidate, 1 / max(original.width, original.height)))
            size = NSSize(width: max(1, floor(original.width * factor + 0.000001)),
                          height: max(1, floor(original.height * factor + 0.000001)))
        } else {
            size = NSSize(width: min(maxSide, floor(maxArea / original.height), max(1, width.rounded())),
                          height: min(maxSide, floor(maxArea / original.width), max(1, height.rounded())))
        }
        let contentScale = event.modifierFlags.contains(.option) && size != original ? factor : 1
        document = resize.before.resizedCanvas(to: size, scalingContentBy: contentScale)
        pixelSelection = imageBounds
        updateSize()
    }

    override func mouseDragged(with event: NSEvent) {
        if canvasResize != nil {
            updateCanvasResize(with: event)
            return
        }
        let location = point(event)
        if let movingRegion {
            self.movingRegion = nil
            guard let image = document.image(in: movingRegion.region) else { return }
            let before = document
            let item = Item(content: .image(image), frame: movingRegion.region)
            document.items.append(Item(content: .solid(.white), frame: movingRegion.region))
            document.items.append(item)
            pixelSelection = nil
            selected = document.items.indices.last
            drag = (movingRegion.start, item, movingRegion.handle, before)
        }
        guard let drag, let selected else {
            if tool == .marquee {
                updateMarquee(to: location)
            } else {
                updateDraft(at: location)
            }
            return
        }
        let original = drag.item.frame
        var item = drag.item
        var frame = original
        let offset = NSPoint(x: location.x - drag.start.x, y: location.y - drag.start.y)
        if let control = drag.handle, let opposite = control.oppositeCorner {
            let anchor = opposite.point(in: original)
            let movingPoint = control.point(in: original)
            let dx = movingPoint.x - anchor.x
            let dy = movingPoint.y - anchor.y
            let scale = max(0.01, ((dx + offset.x) * dx + (dy + offset.y) * dy) / (dx * dx + dy * dy))
            frame.size = NSSize(width: original.width * scale, height: original.height * scale)
            if case let .text(string, font, color) = item.content {
                let size = min(512, max(6, (font.pointSize * scale).rounded()))
                let resized = NSFont(descriptor: font.fontDescriptor, size: size) ?? font
                item = .text(string, font: resized, color: color, at: original.origin)
                frame.size = item.frame.size
            }
            frame.origin = NSPoint(x: dx < 0 ? anchor.x - frame.width : anchor.x,
                                   y: dy < 0 ? anchor.y - frame.height : anchor.y)
        } else if let control = drag.handle {
            switch control {
            case .top:
                frame.size.height = max(1, original.height - offset.y)
                frame.origin.y = original.maxY - frame.height
            case .bottom:
                frame.size.height = max(1, original.height + offset.y)
            case .left:
                frame.size.width = max(1, original.width - offset.x)
                frame.origin.x = original.maxX - frame.width
            case .right:
                frame.size.width = max(1, original.width + offset.x)
            default: break
            }
        } else {
            frame = original.offsetBy(dx: offset.x, dy: offset.y)
        }
        if item.isRectangle {
            let snapped = frame.pixelAligned
            frame = NSRect(origin: snapped.origin, size: NSSize(width: max(1, snapped.width), height: max(1, snapped.height)))
        }
        if let clip = item.clip {
            let scaleX = frame.width / original.width
            let scaleY = frame.height / original.height
            item.clip = NSRect(x: frame.minX + (clip.minX - original.minX) * scaleX,
                               y: frame.minY + (clip.minY - original.minY) * scaleY,
                               width: clip.width * scaleX, height: clip.height * scaleY)
        }
        item.frame = frame
        document.items[selected] = item
        editedDuringDrag = true
    }

    override func mouseUp(with event: NSEvent) {
        if let resize = canvasResize {
            updateCanvasResize(with: event)
            canvasResize = nil
            if document.size != resize.before.size { record(resize.before) }
            return
        }
        movingRegion = nil
        if marqueeOrigin != nil {
            updateMarquee(to: point(event))
            marqueeOrigin = nil
            needsDisplay = true
            return
        }
        if !drawingPoints.isEmpty {
            updateDraft(at: point(event))
            if var draft {
                draft.clip = pixelSelection
                add(draft, select: pixelSelection == nil && draft.isSelectable)
            }
            draft = nil
            drawingPoints.removeAll()
            needsDisplay = true
            return
        }
        if let drag, editedDuringDrag { record(drag.before) }
        drag = nil
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: deleteSelected()
        case 53: selected = nil; pixelSelection = nil
        case 123...126:
            guard let selected else { super.keyDown(with: event); return }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy: CGFloat = event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
            var item = document.items[selected]
            item.frame = item.frame.offsetBy(dx: dx, dy: dy)
            item.clip = item.clip?.offsetBy(dx: dx, dy: dy)
            update(item, at: selected)
        default: super.keyDown(with: event)
        }
    }
}

private enum InterfaceColor {
    static let surface = adaptive(0xf8f7f4, 0x272624)
    static let group = adaptive(0xf0efeb, 0x332f2b)
    static let border = adaptive(0xdcd9d2, 0x48443e)
    static let workspace = adaptive(0xebebeb, 0x242424)
    static let icon = adaptive(0x41403b, 0xd5d1c8)
    static let accent = adaptive(0x22221e, 0xf3efe5)
    static let selected = adaptive(0xdcd9d0, 0x514c44)
    static let export = adaptive(0x383833, 0x555046)

    private static func adaptive(_ light: Int, _ dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
}

private final class ToolbarButton: NSButton {
    static let height: CGFloat = 26
    var isPrimary = false { didSet { needsDisplay = true } }
    private var hoverArea: NSTrackingArea?
    private var hovered = false { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (isPrimary || state == .on || hovered || isHighlighted) {
            let color = isPrimary ? InterfaceColor.export : InterfaceColor.selected
            color.setFill()
            let highlightHeight = min(bounds.height, Self.height) - 2
            let highlight = NSRect(x: bounds.minX + 1, y: bounds.midY - highlightHeight / 2,
                                   width: bounds.width - 2, height: highlightHeight)
            NSBezierPath(roundedRect: highlight, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

final class CenteringClipView: NSClipView {
    override func draw(_ dirtyRect: NSRect) {
        InterfaceColor.workspace.setFill()
        dirtyRect.fill()
        guard let paper = documentView?.frame else { return }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        shadow.set()
        InterfaceColor.border.setFill()
        paper.insetBy(dx: -1, dy: -1).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return constrained }
        let frame = documentView.frame
        if frame.width < constrained.width {
            constrained.origin.x = frame.midX - constrained.width / 2
        }
        if frame.height < constrained.height {
            constrained.origin.y = frame.midY - constrained.height / 2
        }
        return constrained
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        repositionDocument()
    }

    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: newOrigin)
        needsDisplay = true
    }

    func repositionDocument() {
        needsDisplay = true
        let origin = constrainBoundsRect(bounds).origin
        if origin != bounds.origin { scroll(to: origin) }
    }
}

final class ZoomScrollView: NSScrollView {
    var zoomWheel: ((CGFloat, NSPoint) -> Void)?
    var gestureZoom: ((CGFloat, NSPoint) -> Void)?

    override func magnify(with event: NSEvent) {
        gestureZoom?(max(0.01, 1 + event.magnification), event.locationInWindow)
    }

    override func scrollWheel(with event: NSEvent) {
        let vertical = event.scrollingDeltaY
        if vertical != 0, event.modifierFlags.contains(.command), let zoomWheel {
            let steps = event.hasPreciseScrollingDeltas ? vertical / 20 : vertical
            zoomWheel(pow(1.15, min(4, max(-4, steps))), event.locationInWindow)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

final class WrappingToolbar: NSView {
    private let groups: [NSStackView]
    private let inset: CGFloat = 12
    private let gap: CGFloat = 8
    private let rowHeight: CGFloat = 41
    private let groupPadding: CGFloat = 4

    init(groups: [NSStackView]) {
        self.groups = groups
        super.init(frame: .zero)
        groups.forEach { addSubview($0) }
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    private func groupFrames(for width: CGFloat) -> [NSRect] {
        var x = inset
        var y: CGFloat = 4
        return groups.map { group in
            let size = group.fittingSize
            if x > inset && x + size.width + groupPadding * 2 > width - inset {
                x = inset
                y += rowHeight
            }
            let frame = NSRect(x: x + groupPadding, y: y + (rowHeight - size.height) / 2,
                               width: size.width, height: size.height)
            x = frame.maxX + groupPadding + gap
            return frame
        }
    }

    override var intrinsicContentSize: NSSize {
        let frames = groupFrames(for: frame.width > 0 ? frame.width : 1100)
        let height = frames.last.map { ceil($0.midY + rowHeight / 2 + 4) } ?? 0
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged {
            invalidateIntrinsicContentSize()
            needsLayout = true
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        InterfaceColor.surface.setFill()
        dirtyRect.fill()
        for frame in groupFrames(for: bounds.width) {
            let rect = NSRect(x: frame.minX - groupPadding, y: frame.midY - 17,
                              width: frame.width + groupPadding * 2, height: 34)
            let plate = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
            InterfaceColor.group.setFill()
            plate.fill()
            InterfaceColor.border.setStroke()
            plate.lineWidth = 0.75
            plate.stroke()
        }
    }

    override func layout() {
        super.layout()
        for (group, frame) in zip(groups, groupFrames(for: bounds.width)) {
            group.frame = frame
        }
    }
}

private final class CanvasSizeForm: NSObject, NSTextFieldDelegate {
    let width: NSTextField
    let height: NSTextField
    let mode = NSPopUpButton()
    let unit = NSPopUpButton()
    let lock = NSButton(checkboxWithTitle: "锁定宽高比", target: nil, action: nil)
    private let original: NSSize
    private var editedWidth = true
    private enum Unit: Int { case pixels, percent, centimeters }
    private var inputUnit: Unit
    var usesCentimeters: Bool { inputUnit == .centimeters }
    var changesDisplayUnit: Bool { inputUnit != .percent }

    init(size: NSSize, creating: Bool = false, usesCentimeters: Bool = false) {
        original = size
        inputUnit = .pixels
        width = NSTextField(string: String(Int(size.width)))
        height = NSTextField(string: String(Int(size.height)))
        super.init()
        mode.addItems(withTitles: ["仅调整画布", "画布和内容等比缩放"])
        mode.target = self
        mode.action = #selector(changeMode)
        unit.addItems(withTitles: ["像素", "百分比", "厘米"])
        unit.item(at: Unit.percent.rawValue)?.isHidden = creating
        unit.target = self
        unit.action = #selector(changeUnit)
        lock.state = creating ? .off : .on
        lock.target = self
        lock.action = #selector(syncDimensions)
        for field in [width, height] {
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 94).isActive = true
        }
        if creating {
            unit.selectItem(at: Unit.centimeters.rawValue)
            inputUnit = .centimeters
            width.stringValue = "10"
            height.stringValue = "15"
        } else if usesCentimeters {
            unit.selectItem(at: Unit.centimeters.rawValue)
            changeUnit()
        }
    }

    private func number(_ field: NSTextField) -> CGFloat? {
        guard let raw = Double(field.stringValue.trimmingCharacters(in: .whitespaces)),
              raw.isFinite, raw > 0 else { return nil }
        return CGFloat(raw)
    }

    private func format(_ value: CGFloat) -> String {
        if inputUnit == .pixels { return String(format: "%.0f", value.rounded()) }
        return String(format: "%.8f", value).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    private func pixelsPerUnit(_ unit: Unit, originalSize: CGFloat) -> CGFloat {
        switch unit {
        case .pixels: return 1
        case .percent: return originalSize / 100
        case .centimeters: return Document.pixelsPerCentimeter
        }
    }

    private var sourceField: NSTextField { editedWidth ? width : height }
    private var sourceSize: CGFloat { editedWidth ? original.width : original.height }
    var scale: CGFloat {
        guard mode.indexOfSelectedItem == 1, let value = number(sourceField) else { return 1 }
        return value * pixelsPerUnit(inputUnit, originalSize: sourceSize) / sourceSize
    }

    var size: NSSize? {
        guard let w = number(width), let h = number(height) else { return nil }
        let rawWidth = w * pixelsPerUnit(inputUnit, originalSize: original.width)
        let rawHeight = h * pixelsPerUnit(inputUnit, originalSize: original.height)
        let pixelsWide = inputUnit == .pixels ? rawWidth : rawWidth.rounded()
        let pixelsHigh = inputUnit == .pixels ? rawHeight : rawHeight.rounded()
        let validatedWidth = inputUnit == .percent ? max(1, pixelsWide) : pixelsWide
        let validatedHeight = inputUnit == .percent ? max(1, pixelsHigh) : pixelsHigh
        guard (1...16_384).contains(validatedWidth), (1...16_384).contains(validatedHeight),
              validatedWidth.rounded() == validatedWidth, validatedHeight.rounded() == validatedHeight,
              validatedWidth * validatedHeight <= 64_000_000 else { return nil }
        return NSSize(width: validatedWidth, height: validatedHeight)
    }

    func controlTextDidChange(_ notification: Notification) {
        editedWidth = (notification.object as? NSTextField) === width
        syncDimensions()
    }

    @objc private func changeUnit() {
        guard let nextUnit = Unit(rawValue: unit.indexOfSelectedItem) else { return }
        let previousUnit = inputUnit
        inputUnit = nextUnit
        for (field, originalSize) in [(width, original.width), (height, original.height)] {
            if let value = number(field) {
                let pixels = value * pixelsPerUnit(previousUnit, originalSize: originalSize)
                let converted = pixels / pixelsPerUnit(nextUnit, originalSize: originalSize)
                field.stringValue = format(nextUnit == .pixels ? max(1, converted) : converted)
            }
        }
        syncDimensions()
    }

    @objc private func changeMode() {
        let scalesContent = mode.indexOfSelectedItem == 1
        if scalesContent { lock.state = .on }
        lock.isEnabled = !scalesContent
        syncDimensions()
    }

    @objc func syncDimensions() {
        guard lock.state == .on, let value = number(sourceField) else { return }
        let linkedField = editedWidth ? height : width
        let linkedSize = editedWidth ? original.height : original.width
        let factor = value * pixelsPerUnit(inputUnit, originalSize: sourceSize) / sourceSize
        let linkedValue = linkedSize * factor / pixelsPerUnit(inputUnit, originalSize: linkedSize)
        linkedField.stringValue = format(inputUnit == .pixels ? max(1, linkedValue) : linkedValue)
    }
}

private final class PhotoPrintView: NSView {
    private let photo: NSImage
    private let photoSize: NSSize
    private var turnsPhoto = false

    init(photo: NSImage, size: NSSize) {
        self.photo = photo
        photoSize = size
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) { nil }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: 1)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        guard page == 1, let info = NSPrintOperation.current?.printInfo else { return .zero }
        let printable = info.imageablePageBounds.size
        let scale = info.scalingFactor > 0 ? info.scalingFactor : 1
        let uprightFit = min(printable.width / photoSize.width, printable.height / photoSize.height)
        let turnedFit = min(printable.width / photoSize.height, printable.height / photoSize.width)
        // Only turn the photo when its current orientation would lose content.
        turnsPhoto = uprightFit < scale && turnedFit > uprightFit
        let displayedSize = turnsPhoto ? NSSize(width: photoSize.height, height: photoSize.width) : photoSize
        let pageSize = NSSize(width: min(displayedSize.width, printable.width / scale),
                              height: min(displayedSize.height, printable.height / scale))
        frame = NSRect(origin: .zero, size: pageSize)
        return bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: bounds)
        context.translateBy(x: bounds.midX, y: bounds.midY)
        if turnsPhoto { context.rotate(by: .pi / 2) }
        photo.draw(in: NSRect(x: -photoSize.width / 2, y: -photoSize.height / 2,
                              width: photoSize.width, height: photoSize.height))
    }
}

final class Editor: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate, NSTextStorageDelegate {
    let canvas = Canvas()
    let scroll = ZoomScrollView()
    private let fontFamily = NSPopUpButton()
    private let fontSize = NSTextField(string: "32")
    private let fontColorButton = ToolbarButton()
    private let strokeColorButton = ToolbarButton()
    private let currentToolLabel = NSTextField(labelWithString: "移动对象")
    private let pixelSize = NSTextField(labelWithString: "")
    private let selectionSize = NSTextField(labelWithString: "")
    private let filledRectangle = ToolbarButton()
    private let pixelBrushToggle = NSButton(checkboxWithTitle: "像素画笔", target: nil, action: nil)
    private var fontColor = NSColor.black
    private var palette: NSPopover?
    private var colorHexField: NSTextField?
    private var editingFontColor = false
    private var toolBeforeEyedropper: Canvas.Tool = .select
    private let textBar = NSStackView()
    private var inlineText: (field: NSTextView, storage: NSTextStorage, origin: NSPoint, index: Int?)?
    private let toolNames = ["移动对象", "框选", "铅笔", "画笔", "橡皮擦", "油漆桶",
                             "直线", "矩形", "椭圆", "吸色管", "加文字"]
    private var toolButtons: [ToolbarButton] = []
    private let zoomLabel = NSTextField(labelWithString: "100%")
    var window: NSWindow!
    var filename = "未命名"
    var dirty = false
    private var pendingURL: URL?
    private var fitsWindow = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.delegate = self
        window.minSize = NSSize(width: 500, height: 450)
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 0
        let export = iconButton("arrow.down.to.line", "另存 PNG", #selector(savePNG(_:)))
        export.isPrimary = true
        export.contentTintColor = .white
        let fileActions = toolbarGroup([
            iconButton("doc.badge.plus", "新建画布", #selector(newCanvas(_:))),
            iconButton("folder", "打开图片", #selector(openImage(_:))),
            iconButton("clipboard", "粘贴", #selector(paste(_:))),
            iconButton("arrow.uturn.backward", "撤销", #selector(undo(_:))),
            export,
            iconButton("printer", "打印照片", #selector(printPhoto(_:)))
        ])
        let drawingSymbols = ["cursorarrow", "selection.pin.in.out", "pencil", "paintbrush",
                              "eraser", "drop.fill", "line.diagonal", "rectangle", "circle", "eyedropper", "textformat"]
        toolButtons = zip(drawingSymbols, toolNames).enumerated().map { index, entry in
            let button = iconButton(entry.0, entry.1, #selector(changeTool(_:)))
            button.tag = index
            button.setButtonType(.pushOnPushOff)
            return button
        }
        toolButtons.last?.toolTip = "加文字 · 点画布输入 · 回车确认 · Esc 取消"
        let drawingTools = toolbarGroup(toolButtons)

        configureIcon(filledRectangle, symbol: "rectangle.fill", label: "实心矩形")
        styleToolbarButton(filledRectangle)
        filledRectangle.setButtonType(.pushOnPushOff)
        filledRectangle.target = self
        filledRectangle.action = #selector(changeRectangleFill(_:))
        pixelBrushToggle.target = self
        pixelBrushToggle.action = #selector(changeBrushMode(_:))
        pixelBrushToggle.state = canvas.pixelBrush ? .on : .off
        pixelBrushToggle.toolTip = "勾选使用方形像素笔头，取消使用平滑圆形笔头"
        selectTool(.select)
        configureColorButton(strokeColorButton, title: "绘图颜色", color: canvas.strokeColor)
        let widths = NSPopUpButton()
        widths.addItems(withTitles: ["1 px", "2 px", "4 px", "8 px", "16 px", "32 px"])
        widths.selectItem(withTitle: "4 px")
        widths.target = self
        widths.action = #selector(changeStrokeWidth(_:))
        widths.setAccessibilityLabel("线宽")
        widths.toolTip = "线宽"
        let drawingStyle = toolbarGroup([strokeColorButton, widths, pixelBrushToggle, filledRectangle])
        let imageActions = toolbarGroup([
            iconButton("square.dashed.inset.filled", "填满选区", #selector(fillRegion(_:))),
            iconButton("crop", "裁剪", #selector(crop(_:))),
            iconButton("arrow.up.left.and.arrow.down.right", "调整画布尺寸", #selector(resizeImage(_:))),
            iconButton("rotate.right", "旋转／翻转", #selector(showTransforms(_:)))
        ])
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        zoomLabel.widthAnchor.constraint(equalToConstant: 46).isActive = true
        zoomLabel.alignment = .right
        let zoomActions = toolbarGroup([
            iconButton("minus", "缩小画布", #selector(zoomOut(_:))),
            zoomLabel,
            iconButton("plus", "放大画布", #selector(zoomIn(_:))),
            iconButton("1.magnifyingglass", "实际大小 100%", #selector(actual(_:))),
            iconButton("arrow.down.right.and.arrow.up.left", "适合窗口", #selector(fit(_:)))
        ])
        configureTextBar()
        root.addArrangedSubview(WrappingToolbar(groups: [
            fileActions, drawingTools, drawingStyle, imageActions, textBar
        ]))
        canvas.zoomChanged = { [weak self] zoom in
            self?.zoomLabel.stringValue = "\(Int((zoom * 100).rounded()))%"
            self?.layoutInlineText()
        }
        canvas.editText = { [weak self] index in self?.editText(at: index) }
        canvas.placeText = { [weak self] point in self?.beginText(at: point) }
        canvas.finishText = { [weak self] in self?.commitText() }
        canvas.pickColor = { [weak self] color in self?.applySample(color) }
        canvas.gestureZoom = { [weak self] factor, point in self?.scaleView(by: factor, at: point) }
        scroll.gestureZoom = canvas.gestureZoom
        scroll.zoomWheel = { [weak self] factor, point in self?.scaleView(by: factor, at: point) }
        let separator = NSBox()
        separator.boxType = .separator
        root.addArrangedSubview(separator)
        scroll.contentView = CenteringClipView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.backgroundColor = InterfaceColor.workspace
        scroll.documentView = canvas
        root.addArrangedSubview(scroll)
        let status = NSStackView(views: [currentToolLabel, pixelSize, selectionSize])
        currentToolLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        currentToolLabel.textColor = InterfaceColor.accent
        status.spacing = 18
        selectionSize.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        selectionSize.textColor = .secondaryLabelColor
        canvas.selectionChanged = { [weak self] frame in self?.showSelection(frame) }
        status.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 7, right: 14)
        pixelSize.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        pixelSize.textColor = .secondaryLabelColor
        let statusSeparator = NSBox()
        statusSeparator.boxType = .separator
        root.addArrangedSubview(statusSeparator)
        let footer = NSStackView(views: [status, NSView(), zoomActions])
        footer.alignment = .centerY
        footer.spacing = 8
        footer.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 12)
        status.setContentHuggingPriority(.required, for: .horizontal)
        zoomActions.setContentHuggingPriority(.required, for: .horizontal)
        root.addArrangedSubview(footer)
        window.contentView = root
        canvas.changed = { [weak self] in self?.setDirty(true) }
        canvas.updateSize()
        fit(nil)
        configureMenus()
        setDirty(false)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)
        if let pendingURL {
            self.pendingURL = nil
            _ = load(pendingURL)
        }
    }

    private func configureMenus() {
        let main = NSMenu()
        let definitions: [(String, [(String, Selector, String)])] = [
            ("PixelPad", [("退出 PixelPad", #selector(NSApplication.terminate(_:)), "q")]),
            ("文件", [("新建画布…", #selector(newCanvas(_:)), "n"),
                      ("打开图片…", #selector(openImage(_:)), "o"),
                      ("另存 PNG…", #selector(savePNG(_:)), "s"),
                      ("打印照片…", #selector(printPhoto(_:)), "p")]),
            ("编辑", [("撤销", #selector(undo(_:)), "z"), ("重做", #selector(redo(_:)), "Z"),
                     ("剪切", #selector(cut(_:)), "x"), ("复制", #selector(copy(_:)), "c"),
                     ("粘贴", #selector(paste(_:)), "v"), ("全选像素", #selector(selectAllPixels(_:)), "a"),
                     ("取消框选", #selector(clearSelection(_:)), "d"), ("文字工具", #selector(addText(_:)), "t")]),
            ("图像", [("裁剪到选区", #selector(crop(_:)), ""), ("调整画布尺寸…", #selector(resizeImage(_:)), ""),
                     ("顺时针旋转 90°", #selector(rotateRight(_:)), ""), ("逆时针旋转 90°", #selector(rotateLeft(_:)), ""),
                     ("水平翻转", #selector(flipHorizontal(_:)), ""), ("垂直翻转", #selector(flipVertical(_:)), "")]),
            ("显示", [("放大", #selector(zoomIn(_:)), "="), ("缩小", #selector(zoomOut(_:)), "-"),
                     ("实际大小", #selector(actual(_:)), "0"), ("适合窗口", #selector(fit(_:)), "9")])
        ]
        for (title, entries) in definitions {
            let container = NSMenuItem()
            let menu = NSMenu(title: title)
            for (label, action, key) in entries {
                let item = NSMenuItem(title: label, action: action, keyEquivalent: key)
                if key != "q" { item.target = self }
                menu.addItem(item)
            }
            container.submenu = menu
            main.addItem(container)
        }
        NSApp.mainMenu = main
    }

    func setDirty(_ value: Bool) {
        let size = canvas.document.size
        let pixels = "\(Int(size.width)) × \(Int(size.height)) px"
        if canvas.document.usesCentimeters {
            pixelSize.stringValue = "\(formatDimension(size.width, inCentimeters: true)) × \(formatDimension(size.height, inCentimeters: true)) cm"
            pixelSize.toolTip = pixels
        } else {
            pixelSize.stringValue = pixels
            pixelSize.toolTip = nil
        }
        dirty = value
        window.title = "\(filename) — PixelPad"
        window.isDocumentEdited = value
    }

    @objc func openImage(_ sender: Any?) {
        commitText()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = load(url)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        if window == nil {
            pendingURL = url
            return true
        }
        return load(url)
    }

    @discardableResult func load(_ url: URL) -> Bool {
        guard window != nil else { return false }
        commitText()
        if dirty {
            let alert = NSAlert()
            alert.messageText = "先保存当前修改？"
            alert.addButton(withTitle: "保存")
            alert.addButton(withTitle: "放弃修改")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn: guard exportPNG() else { return false }
            case .alertSecondButtonReturn: break
            default: return false
            }
        }
        guard let image = NSImage(contentsOf: url), let rep = image.representations.first,
              rep.pixelsWide > 0, rep.pixelsHigh > 0 else {
            error("无法打开这张图片。")
            return false
        }
        let size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        image.size = size
        canvas.replace(Document(size: size, background: image))
        filename = url.lastPathComponent
        setDirty(false)
        fit(nil)
        return true
    }

    private func selectTool(_ tool: Canvas.Tool) {
        canvas.tool = tool
        for (index, button) in toolButtons.enumerated() {
            let active = index == tool.rawValue
            button.state = active ? .on : .off
            button.contentTintColor = active ? InterfaceColor.accent : InterfaceColor.icon
            button.needsDisplay = true
        }
        currentToolLabel.stringValue = toolNames[tool.rawValue]
        filledRectangle.isEnabled = tool == .rectangle
    }

    @objc private func changeTool(_ sender: NSButton) {
        guard let tool = Canvas.Tool(rawValue: sender.tag) else { return }
        if tool == .text { addText(sender); return }
        if tool == .eyedropper {
            if canvas.tool != .eyedropper { toolBeforeEyedropper = canvas.tool }
            editingFontColor = inlineText != nil || canvas.tool == .text
        } else {
            commitText()
        }
        selectTool(tool)
        window.makeFirstResponder(canvas)
    }

    private func toolbarGroup(_ views: [NSView]) -> NSStackView {
        let group = NSStackView(views: views)
        group.alignment = .centerY
        group.spacing = 2
        return group
    }

    private func iconButton(_ symbol: String, _ label: String, _ action: Selector) -> ToolbarButton {
        let button = ToolbarButton()
        button.target = self
        button.action = action
        configureIcon(button, symbol: symbol, label: label)
        styleToolbarButton(button)
        return button
    }

    private func styleToolbarButton(_ button: NSButton) {
        button.isBordered = false
        button.contentTintColor = InterfaceColor.icon
        button.widthAnchor.constraint(equalToConstant: 29).isActive = true
        button.heightAnchor.constraint(equalToConstant: ToolbarButton.height).isActive = true
    }

    private func configureIcon(_ button: NSButton, symbol: String, label: String) {
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            button.image = image.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
            button.imagePosition = .imageOnly
        }
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    private func leftAligned(_ row: NSStackView) -> NSView {
        let wrapper = NSView()
        wrapper.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor),
            row.topAnchor.constraint(equalTo: wrapper.topAnchor),
            row.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor)
        ])
        return wrapper
    }

    private func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 15, height: 15), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            color.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.stroke()
            return true
        }
    }

    private func configureColorButton(_ button: NSButton, title: String, color: NSColor) {
        button.title = title
        button.imagePosition = .imageOnly
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.image = swatch(color)
        styleToolbarButton(button)
        button.target = self
        button.action = #selector(showPalette(_:))
    }

    @objc private func showPalette(_ sender: NSButton) {
        if let palette, palette.isShown {
            palette.performClose(nil)
            return
        }
        editingFontColor = sender === fontColorButton
        let colors: [NSColor] = [
            .black, .darkGray, .gray, .lightGray, .white, .systemRed,
            .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue, .systemPurple
        ]
        let rows = stride(from: 0, to: colors.count, by: 6).map { start in
            NSStackView(views: (start..<(start + 6)).map { index in
                let button = NSButton(image: swatch(colors[index]), target: self, action: #selector(pickSwatch(_:)))
                button.alternateImage = nil
                button.identifier = NSUserInterfaceItemIdentifier(hex(colors[index]))
                button.setAccessibilityLabel(hex(colors[index]))
                return button
            })
        }
        let field = NSTextField(string: hex(editingFontColor ? fontColor : canvas.strokeColor))
        field.setAccessibilityLabel("十六进制颜色")
        field.target = self
        field.action = #selector(applyHex(_:))
        field.widthAnchor.constraint(equalToConstant: 90).isActive = true
        colorHexField = field
        let actions = NSStackView(views: [
            field,
            NSButton(title: "应用", target: self, action: #selector(applyHex(_:))),
            NSButton(title: "吸色管", target: self, action: #selector(pickFromPalette(_:)))
        ])
        let content = NSStackView(views: rows + [actions])
        content.orientation = .vertical
        content.alignment = .leading
        content.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        content.spacing = 6
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = content.fittingSize
        palette = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    private func hex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }

    @objc private func pickSwatch(_ sender: NSButton) {
        if let value = sender.identifier?.rawValue { applyColorHex(value) }
    }

    @objc private func applyHex(_ sender: NSControl) {
        if let field = colorHexField { applyColorHex(field.stringValue) }
    }

    private func applyColorHex(_ input: String) {
        let digits = input.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { NSSound.beep(); return }
        let color = NSColor(srgbRed: CGFloat(value >> 16) / 255, green: CGFloat((value >> 8) & 255) / 255,
                            blue: CGFloat(value & 255) / 255, alpha: 1)
        palette?.performClose(nil)
        setActiveColor(color)
    }

    @objc private func pickFromPalette(_ sender: NSButton) {
        palette?.performClose(nil)
        if canvas.tool != .eyedropper { toolBeforeEyedropper = canvas.tool }
        selectTool(.eyedropper)
        window.makeFirstResponder(canvas)
    }

    private func applySample(_ color: NSColor) {
        selectTool(toolBeforeEyedropper)
        setActiveColor(color)
    }

    private func setActiveColor(_ color: NSColor) {
        if editingFontColor {
            fontColor = color
            fontColorButton.image = swatch(color)
        } else {
            canvas.strokeColor = color
            strokeColorButton.image = swatch(color)
        }
        layoutInlineText()
        if let field = inlineText?.field { window.makeFirstResponder(field) }
    }

    @objc private func changeRectangleFill(_ sender: NSButton) {
        canvas.fillRectangles = sender.state == .on
        sender.needsDisplay = true
        window.makeFirstResponder(canvas)
    }

    private func formatDimension(_ pixels: CGFloat, inCentimeters: Bool) -> String {
        let value = inCentimeters ? pixels / Document.pixelsPerCentimeter : pixels
        return String(format: "%.2f", value).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    private func showSelection(_ frame: NSRect?) {
        guard let frame else {
            selectionSize.stringValue = ""
            selectionSize.toolTip = nil
            return
        }
        func dimensions(inCentimeters: Bool) -> String {
            let x = formatDimension(frame.minX, inCentimeters: inCentimeters)
            let y = formatDimension(frame.minY, inCentimeters: inCentimeters)
            let width = formatDimension(frame.width, inCentimeters: inCentimeters)
            let height = formatDimension(frame.height, inCentimeters: inCentimeters)
            let unit = inCentimeters ? "cm" : "px"
            return "X \(x)  Y \(y)    \(width) × \(height) \(unit)"
        }
        let inCentimeters = canvas.document.usesCentimeters
        selectionSize.stringValue = dimensions(inCentimeters: inCentimeters)
        selectionSize.toolTip = inCentimeters ? dimensions(inCentimeters: false) : nil
    }

    @objc private func changeBrushMode(_ sender: NSButton) {
        commitText()
        canvas.pixelBrush = sender.state == .on
        selectTool(.brush)
        window.makeFirstResponder(canvas)
    }

    @objc private func changeStrokeWidth(_ sender: NSPopUpButton) {
        canvas.strokeWidth = pow(2, CGFloat(sender.indexOfSelectedItem))
    }

    private var activeTextEditor: NSTextView? {
        guard let editor = (NSApp.modalWindow ?? window).firstResponder as? NSTextView,
              editor.isFieldEditor || editor === inlineText?.field else { return nil }
        return editor
    }

    @objc private func selectAllPixels(_ sender: Any?) {
        if let editor = activeTextEditor { editor.selectAll(sender); return }
        commitText()
        selectTool(.marquee)
        canvas.selectCanvas()
        window.makeFirstResponder(canvas)
    }

    @objc private func clearSelection(_ sender: Any?) {
        canvas.pixelSelection = nil
        canvas.selected = nil
    }

    @objc func copy(_ sender: Any?) {
        if let editor = activeTextEditor { editor.copy(sender); return }
        _ = copyPixels()
    }

    @objc func cut(_ sender: Any?) {
        if let editor = activeTextEditor { editor.cut(sender); return }
        if copyPixels() { canvas.deleteSelected() }
    }

    private func copyPixels() -> Bool {
        guard let region = canvas.pixelSelection ?? canvas.selected.map({ canvas.document.items[$0].frame.integral.intersection(canvas.imageBounds) }),
              !region.isEmpty, let image = canvas.document.image(in: region) else { NSSound.beep(); return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([image])
    }

    @objc private func fillRegion(_ sender: Any?) {
        commitText()
        canvas.fillSelection(canvas.strokeColor)
    }

    @objc private func crop(_ sender: Any?) {
        commitText()
        guard let region = canvas.pixelSelection, let image = canvas.document.image(in: region) else { NSSound.beep(); return }
        canvas.transform(Document(size: region.size, background: image,
                                  usesCentimeters: canvas.document.usesCentimeters))
        fit(nil)
    }

    @objc private func newCanvas(_ sender: Any?) {
        let form = CanvasSizeForm(size: canvas.document.size, creating: true)
        guard let size = requestCanvasSize(form, creating: true), confirmClose() else { return }
        canvas.replace(Document(size: size, usesCentimeters: form.usesCentimeters))
        filename = "未命名"
        setDirty(false)
        fit(nil)
    }

    @objc private func resizeImage(_ sender: Any?) {
        commitText()
        let original = canvas.document
        let form = CanvasSizeForm(size: original.size, usesCentimeters: original.usesCentimeters)
        guard let size = requestCanvasSize(form, creating: false) else { return }
        let usesCentimeters = form.changesDisplayUnit ? form.usesCentimeters : original.usesCentimeters
        guard size != original.size || usesCentimeters != original.usesCentimeters else { return }
        var resized = size == original.size ? original : original.resizedCanvas(to: size, scalingContentBy: form.scale)
        resized.usesCentimeters = usesCentimeters
        canvas.transform(resized)
        fit(nil)
    }

    private func requestCanvasSize(_ form: CanvasSizeForm, creating: Bool) -> NSSize? {
        let dimensions = toolbarGroup([
            NSTextField(labelWithString: "宽"), form.width,
            NSTextField(labelWithString: "高"), form.height
        ])
        let unitControls = creating ? [form.unit] : [form.mode, form.unit]
        let rows = [toolbarGroup(unitControls), dimensions]
        let accessory = NSStackView(views: creating ? rows : rows + [form.lock])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 10
        accessory.frame = NSRect(x: 0, y: 0, width: 284, height: creating ? 64 : 96)
        let alert = NSAlert()
        alert.messageText = creating ? "新建画布" : "调整画布尺寸"
        alert.informativeText = creating
            ? "厘米尺寸按 300 像素/英寸换算。"
            : "厘米尺寸按 300 像素/英寸换算。调整以左上角为基准。"
        alert.accessoryView = accessory
        alert.addButton(withTitle: creating ? "创建" : "应用")
        alert.addButton(withTitle: "取消")
        while alert.runModal() == .alertFirstButtonReturn {
            alert.window.makeFirstResponder(nil)
            form.syncDimensions()
            if let size = form.size { return size }
            error("请输入有效的宽高。单边最多 16384 像素，总像素最多 64000000。")
        }
        return nil
    }

    @objc private func showTransforms(_ sender: NSButton) {
        let menu = NSMenu()
        for (title, action) in [("顺时针旋转 90°", #selector(rotateRight(_:))),
                                ("逆时针旋转 90°", #selector(rotateLeft(_:))),
                                ("水平翻转", #selector(flipHorizontal(_:))),
                                ("垂直翻转", #selector(flipVertical(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
    }

    @objc private func rotateRight(_ sender: Any?) { rotate(clockwise: true) }
    @objc private func rotateLeft(_ sender: Any?) { rotate(clockwise: false) }
    @objc private func flipHorizontal(_ sender: Any?) { flip(horizontal: true) }
    @objc private func flipVertical(_ sender: Any?) { flip(horizontal: false) }

    private func rotate(clockwise: Bool) {
        let size = canvas.document.size
        applyTransform(to: NSSize(width: size.height, height: size.width)) { context in
            context.translateBy(x: clockwise ? size.height : 0, y: clockwise ? 0 : size.width)
            context.rotate(by: clockwise ? .pi / 2 : -.pi / 2)
        }
    }

    private func flip(horizontal: Bool) {
        let size = canvas.document.size
        applyTransform(to: size) { context in
            context.translateBy(x: horizontal ? size.width : 0, y: horizontal ? 0 : size.height)
            context.scaleBy(x: horizontal ? -1 : 1, y: horizontal ? 1 : -1)
        }
    }

    private func applyTransform(to size: NSSize, _ transform: (CGContext) -> Void) {
        commitText()
        guard let document = canvas.document.transformed(to: size, draw: transform) else {
            error("无法处理此尺寸的图片。")
            return
        }
        canvas.transform(document)
        fit(nil)
    }

    @objc func paste(_ sender: Any?) {
        if let fieldEditor = activeTextEditor {
            fieldEditor.paste(sender)
            return
        }
        commitText()
        let board = NSPasteboard.general
        guard let image = (board.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage),
              let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 else {
            error("剪贴板里没有可粘贴的图片。")
            return
        }
        let size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        image.size = size
        let paper = canvas.document.size
        let ratio = min(1, min(paper.width / size.width, paper.height / size.height) * 0.9)
        let width = size.width * ratio
        let height = size.height * ratio
        selectTool(.select)
        canvas.pixelSelection = nil
        canvas.add(Item(content: .image(image), frame: NSRect(x: (paper.width - width) / 2,
                        y: (paper.height - height) / 2, width: width, height: height)))
        window.makeFirstResponder(canvas)
    }

    private func configureTextBar() {
        textBar.alignment = .centerY
        textBar.spacing = 4
        fontFamily.addItems(withTitles: NSFontManager.shared.availableFontFamilies.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        })
        fontFamily.selectItem(withTitle: "Helvetica")
        fontFamily.setAccessibilityLabel("字体")
        fontFamily.toolTip = "字体"
        fontFamily.widthAnchor.constraint(equalToConstant: 124).isActive = true
        fontSize.toolTip = "字号"
        fontSize.widthAnchor.constraint(equalToConstant: 48).isActive = true
        fontSize.setAccessibilityLabel("字号")
        configureColorButton(fontColorButton, title: "文字颜色", color: fontColor)
        for control in [fontFamily, fontSize] as [NSControl] {
            control.target = self
            control.action = #selector(textStyleChanged(_:))
        }
        for view in [fontFamily, fontSize, fontColorButton] {
            textBar.addArrangedSubview(view)
        }
    }

    @objc func addText(_ sender: Any?) {
        commitText()
        selectTool(.text)
        window.makeFirstResponder(canvas)
    }

    private func editText(at index: Int) {
        let item = canvas.document.items[index]
        guard case let .text(string, font, color) = item.content else { return }
        fontFamily.selectItem(withTitle: font.familyName ?? "Helvetica")
        fontSize.stringValue = String(Int(font.pointSize.rounded()))
        fontColor = color
        fontColorButton.image = swatch(color)
        beginText(at: item.frame.origin, index: index, value: string)
    }

    private func beginText(at origin: NSPoint, index: Int? = nil, value: String = "") {
        commitText()
        let (storage, _, container) = makeTextLayout(layout: EditingLayoutManager())
        let field = NSTextView(frame: .zero, textContainer: container)
        field.isRichText = false
        field.importsGraphics = false
        field.allowsUndo = true
        field.isHorizontallyResizable = false
        field.isVerticallyResizable = false
        field.textContainerInset = .zero
        field.drawsBackground = false
        field.focusRingType = .none
        field.setAccessibilityLabel("画布文字")
        field.delegate = self
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: value)
        canvas.selected = nil
        inlineText = (field, storage, origin, index)
        storage.delegate = self
        canvas.textDraft = { [weak self, weak field] in
            guard let self, let field else { return nil }
            return (index, Item.text(field.string, font: self.textFont, color: self.fontColor, at: origin))
        }
        canvas.addSubview(field)
        layoutInlineText()
        window.makeFirstResponder(field)
        field.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
    }

    private var textFont: NSFont {
        let size = CGFloat(max(6, min(512, Double(fontSize.stringValue) ?? 32)))
        let family = fontFamily.titleOfSelectedItem ?? "Helvetica"
        return NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
            ?? NSFont.systemFont(ofSize: size)
    }

    @objc private func textStyleChanged(_ sender: NSControl) {
        layoutInlineText()
        if let field = inlineText?.field { window.makeFirstResponder(field) }
    }

    private func layoutInlineText() {
        guard let edit = inlineText else { return }
        let zoom = canvas.zoom
        let font = textFont
        edit.field.font = font
        edit.field.textColor = fontColor
        let width = max(1, canvas.document.size.width - edit.origin.x)
        let height = max(24, ceil(font.ascender - font.descender + font.leading) + 6)
        let frameSize = NSSize(width: width * zoom, height: height * zoom)
        edit.field.frame = NSRect(origin: NSPoint(x: edit.origin.x * zoom, y: edit.origin.y * zoom),
                                  size: frameSize)
        edit.field.bounds = NSRect(x: 0, y: 0, width: width, height: height)
        canvas.needsDisplay = true
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        canvas.needsDisplay = true
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard textView === inlineText?.field else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): commitText()
        case #selector(NSResponder.cancelOperation(_:)): commitText(cancel: true)
        default: return false
        }
        return true
    }

    private func commitText(cancel: Bool = false) {
        guard let edit = inlineText else { return }
        edit.field.unmarkText()
        let currentValue = edit.field.string
        inlineText = nil
        edit.field.removeFromSuperview()
        canvas.textDraft = nil
        selectTool(edit.index == nil && canvas.tool == .text ? .text : .select)
        window.makeFirstResponder(canvas)
        if cancel || currentValue.isEmpty {
            canvas.selected = edit.index
            return
        }
        let item = Item.text(currentValue, font: textFont, color: fontColor, at: edit.origin)
        if let index = edit.index { canvas.update(item, at: index) } else { canvas.add(item) }
    }

    @objc func undo(_ sender: Any?) {
        if let editor = activeTextEditor {
            editor.undoManager?.undo()
        } else {
            commitText()
            canvas.undo(sender)
        }
    }
    @objc func redo(_ sender: Any?) {
        if let editor = activeTextEditor {
            editor.undoManager?.redo()
        } else {
            commitText()
            canvas.redo(sender)
        }
    }
    @objc func actual(_ sender: Any?) { scaleView(by: 1 / canvas.zoom) }
    @objc private func zoomIn(_ sender: Any?) { scaleView(by: 1.25) }
    @objc private func zoomOut(_ sender: Any?) { scaleView(by: 0.8) }

    private func scaleView(by factor: CGFloat, at point: NSPoint? = nil) {
        fitsWindow = false
        let clip = scroll.contentView
        let previous = canvas.zoom
        let zoom = min(64, max(0.01, previous * factor))
        guard zoom != previous else { return }
        let anchor = point.map { clip.convert($0, from: nil) }
            ?? NSPoint(x: clip.bounds.midX, y: clip.bounds.midY)
        let offset = NSPoint(x: anchor.x - clip.bounds.minX, y: anchor.y - clip.bounds.minY)
        let newOrigin = NSPoint(x: anchor.x * zoom / previous - offset.x,
                                y: anchor.y * zoom / previous - offset.y)
        canvas.zoom = zoom
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: newOrigin, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    func windowDidResize(_ notification: Notification) {
        if fitsWindow { fit(nil) }
    }

    @objc func fit(_ sender: Any?) {
        fitsWindow = true
        window.contentView?.layoutSubtreeIfNeeded()
        let available = scroll.contentSize
        let paper = canvas.document.size
        canvas.zoom = max(0.01, min(1, min(available.width / paper.width, available.height / paper.height)))
    }

    @objc private func printPhoto(_ sender: Any?) {
        commitText()
        let document = canvas.document
        let size = document.printSize
        guard let photo = document.image(in: NSRect(origin: .zero, size: document.size)) else {
            error("无法生成打印图像。")
            return
        }
        let page = PhotoPrintView(photo: photo, size: size)

        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.orientation = size.width > size.height ? .landscape : .portrait
        info.scalingFactor = 1
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        let operation = NSPrintOperation(view: page, printInfo: info)
        operation.jobTitle = filename
        operation.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsScaling, .showsPreview])
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc func savePNG(_ sender: Any?) { _ = exportPNG() }

    func exportPNG() -> Bool {
        commitText()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = (filename as NSString).deletingPathExtension + "-编辑.png"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard let data = canvas.document.png() else {
            error("无法生成 PNG。")
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            setDirty(false)
            return true
        } catch {
            self.error("保存失败。\n\(error.localizedDescription)")
            return false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmClose()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        confirmClose() ? .terminateNow : .terminateCancel
    }

    private func confirmClose() -> Bool {
        commitText()
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "退出前保存当前修改？"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "放弃修改")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return exportPNG()
        case .alertSecondButtonReturn: dirty = false; return true
        default: return false
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func error(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}

let app = NSApplication.shared
let editor = Editor()
app.delegate = editor
app.setActivationPolicy(.regular)
app.run()
