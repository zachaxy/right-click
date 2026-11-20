import Cocoa

var checks = 0
func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { fatalError(message) }
}

struct PixelBounds {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int
    var centerY: Double { Double(minY + maxY + 1) / 2 }
}

struct RenderedImage {
    let scale: Int
    let width: Int
    let height: Int
    let bytes: [UInt8]

    func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }

    func bounds(x: Range<Int>? = nil, y: Range<Int>? = nil) -> PixelBounds? {
        var xs = [Int]()
        var ys = [Int]()
        for py in y ?? 0..<height {
            for px in x ?? 0..<width where alpha(px, py) > 8 {
                xs.append(px)
                ys.append(py)
            }
        }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        return PixelBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    func verticalCenter(x: Range<Int>? = nil) -> Double {
        var weight = 0.0
        var position = 0.0
        for y in 0..<height {
            for px in x ?? 0..<width {
                let a = Double(alpha(px, y))
                weight += a
                position += (Double(y) + 0.5) * a
            }
        }
        return position / weight / Double(scale)
    }

    func alphaRegion(x: Range<Int>, y: Range<Int>) -> [UInt8] {
        y.flatMap { py in x.map { alpha($0, py) } }
    }

    // Locate the arrow's first connected column group, then the text after its
    // transparent gap. The test does not duplicate the renderer's text layout.
    func rowBounds(y: Range<Int>) -> (arrow: PixelBounds, text: PixelBounds) {
        let columns = (18 * scale..<width).map { x in y.contains { alpha(x, $0) > 8 } }
        let first = columns.firstIndex(of: true)!
        var end = first
        while end + 1 < columns.count && columns[end + 1] { end += 1 }
        let next = columns[(end + 1)...].firstIndex(of: true)!
        return (bounds(x: (first + 18 * scale)..<(end + 18 * scale + 1), y: y)!,
                bounds(x: (next + 18 * scale)..<width, y: y)!)
    }
}

func render(_ image: NSImage, scale: Int) -> RenderedImage {
    let width = Int(image.size.width) * scale
    let height = Int(image.size.height) * scale
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero,
               operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    let bytes = Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    return RenderedImage(scale: scale, width: width, height: height, bytes: bytes)
}

let cases: [(String, String, String)] = [
    ("maximum", "1000.0 KB/s", "1000.0 KB/s"),
    ("user screenshot", "64.4 KB/s", "6.1 KB/s"),
    ("mixed", "8.0 MB/s", "999.9 KB/s"),
    ("idle", "0 B/s", "0 B/s"),
    ("pending", "—", "—")
]
var renders = [String: RenderedImage]()
var evidence = [String]()
for scale in [1, 2] {
    for (name, download, upload) in cases {
        let image = NetworkSpeedStatusImage.make(download: download, upload: upload)
        check(image.isTemplate, "\(name): AppKit must tint the image for the current menu-bar appearance")
        check(image.size == NSSize(width: 94, height: 22), "\(name): status item size cannot grow with text")
        let rendered = render(image, scale: scale)
        renders["\(name)-\(scale)"] = rendered
        let bounds = rendered.bounds()!
        let icon = rendered.bounds(x: 0..<(17 * scale))!
        let row1 = rendered.rowBounds(y: 0..<(11 * scale))
        let row2 = rendered.rowBounds(y: (11 * scale)..<rendered.height)
        let text1 = row1.text
        let text2 = row2.text
        let bottom = bounds.minY
        let top = rendered.height - bounds.maxY - 1
        check(bottom >= scale && top >= scale, "\(name) @\(scale)x: visible pixels need at least 1 pt above and below")
        check(abs(Double(bottom - top)) / Double(scale) <= 1,
              "\(name) @\(scale)x: combined content cannot lean toward the top of the menu bar")
        check(abs(bounds.centerY / Double(scale) - 11) <= 0.5,
              "\(name) @\(scale)x: occupied pixel bounds must center on the 22 pt menu bar")
        check(abs(rendered.verticalCenter() - 11) <= 1,
              "\(name) @\(scale)x: alpha-weighted visual center must remain near the menu-bar midline")
        check(abs(icon.centerY / Double(scale) - 11) <= 1,
              "\(name) @\(scale)x: the retained RightClick icon must stay vertically centered")
        check(text1.minY > 0 && text2.maxY < rendered.height - 1,
              "\(name) @\(scale)x: both rows must fit without touching their outer clipping edges")
        check(text1.maxY < text2.minY - 1,
              "\(name) @\(scale)x: the two text rows need a visible gap")
        check(bounds.maxX < rendered.width - scale,
              "\(name) @\(scale)x: even 1000.0 KB/s must leave a right margin")
        for row in [row1, row2] {
            check((88.5...90.5).contains(Double(row.text.maxX + 1) / Double(scale)),
                  "\(name) @\(scale)x: short and long complete rates must end near x=90")
            let gap = Double(row.text.minX - row.arrow.maxX - 1) / Double(scale)
            check((3.5...6).contains(gap),
                  "\(name) @\(scale)x: each arrow must follow its text with a small fixed gap")
            check(row.arrow.minX - icon.maxX >= 3 * scale,
                  "\(name) @\(scale)x: longest rate and its arrow must not collide with the RightClick icon")
        }
        if name == "user screenshot" {
            check(text1.maxX == text2.maxX,
                  "64.4 KB/s and 6.1 KB/s must have identical right edges")
            check(row1.arrow.minX != row2.arrow.minX,
                  "arrows must move with the different-length rates instead of leaving a wide gap")
            check(abs((text1.minX - row1.arrow.maxX) - (text2.minX - row2.arrow.maxX)) <= scale,
                  "arrow-to-text gaps may differ only by pixel rounding, not number length")
        }
        evidence.append("\(name) @\(scale)x: alpha y=\(bounds.minY)...\(bounds.maxY), padding=\(bottom)/\(top) px, "
            + "visual center=\(String(format: "%.2f", rendered.verticalCenter())) pt; icon y=\(icon.minY)...\(icon.maxY), "
            + "text rows=\(text1.minY)...\(text1.maxY) / \(text2.minY)...\(text2.maxY), "
            + "text right=\(text1.maxX)/\(text2.maxX) px, "
            + "arrow gaps=\(text1.minX - row1.arrow.maxX - 1)/\(text2.minX - row2.arrow.maxX - 1) px")
    }
    let maximum = renders["maximum-\(scale)"]!
    for (name, _, _) in cases where name != "maximum" {
        let other = renders["\(name)-\(scale)"]!
        check(maximum.alphaRegion(x: 0..<(17 * scale), y: 0..<maximum.height)
              == other.alphaRegion(x: 0..<(17 * scale), y: 0..<other.height),
              "\(name) @\(scale)x: RightClick icon pixels remain fixed while rates and arrows move")
    }
}

// Build a labelled, enlarged preview from the exact tested alpha masks. This is an
// offscreen rendering preview, not a screenshot of the user's live menu bar.
let previewWidth = 680
let previewHeight = 412
let preview = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: previewWidth, pixelsHigh: previewHeight,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: previewWidth * 4, bitsPerPixel: 32)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: preview)
NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: previewWidth, height: previewHeight).fill()
func label(_ text: String, at point: NSPoint, size: CGFloat = 13, color: NSColor = .black) {
    (text as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color])
}
label("离屏渲染预览 · 真实生产 renderer · 非菜单栏截图", at: NSPoint(x: 18, y: 378), size: 17)
label("数值与单位整体右对齐；箭头跟随文字；2× 原样着色，橙线标出垂直中线", at: NSPoint(x: 18, y: 355), size: 12)
for (index, item) in cases.enumerated() {
    let name = item.0
    let rendered = renders["\(name)-2"]!
    let y = CGFloat(293 - index * 62)
    label(name, at: NSPoint(x: 18, y: y + 15), size: 12)
    for (column, dark) in [false, true].enumerated() {
        let rect = NSRect(x: 119 + column * 270, y: Int(y), width: 244, height: 50)
        (dark ? NSColor(deviceRed: 0.16, green: 0.16, blue: 0.16, alpha: 1) : .white).setFill()
        rect.fill()
        let tinted = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rendered.width, pixelsHigh: rendered.height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: rendered.width * 4, bitsPerPixel: 32)!
        let p = tinted.bitmapData!
        for pixel in 0..<(rendered.width * rendered.height) {
            let alpha = rendered.bytes[pixel * 4 + 3]
            // Composite explicitly so preview readers need no transparency convention.
            let color = dark ? UInt8((40.8 + 214.2 * Double(alpha) / 255).rounded()) : 255 - alpha
            p[pixel * 4] = color
            p[pixel * 4 + 1] = color
            p[pixel * 4 + 2] = color
            p[pixel * 4 + 3] = 255
        }
        tinted.draw(in: NSRect(x: rect.minX + 28, y: rect.minY + 3,
                              width: CGFloat(rendered.width), height: CGFloat(rendered.height)))
        let line = NSBezierPath()
        line.move(to: NSPoint(x: rect.minX + 3, y: rect.midY))
        line.line(to: NSPoint(x: rect.minX + 24, y: rect.midY))
        line.move(to: NSPoint(x: rect.maxX - 24, y: rect.midY))
        line.line(to: NSPoint(x: rect.maxX - 3, y: rect.midY))
        NSColor.systemOrange.setStroke()
        line.lineWidth = 1
        line.stroke()
    }
}
NSGraphicsContext.restoreGraphicsState()
let previewURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("build/network-speed-image-preview.png")
try FileManager.default.createDirectory(at: previewURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try preview.representation(using: .png, properties: [:])!.write(to: previewURL)
for line in evidence { print(line) }
print("PASS: \(checks) network speed image checks")
print("Offscreen rendering preview: \(previewURL.path)")
