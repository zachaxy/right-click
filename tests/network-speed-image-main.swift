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

    // Stats reserves a fixed arrow column before x=25. Later comparisons verify
    // that even expanded text cannot change any pixel in this reserved region.
    func rowBounds(y: Range<Int>) -> (arrow: PixelBounds, text: PixelBounds) {
        (bounds(x: (18 * scale)..<(25 * scale), y: y)!,
         bounds(x: (25 * scale)..<width, y: y)!)
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

// Match the production formatter at unit/precision boundaries, including the
// rounded value immediately below a unit transition.
let formats: [(Double, String)] = [
    (0, "0 KB/s"), (999.99, "0 KB/s"), (1000, "1 KB/s"),
    (1501, "2 KB/s"), (6100, "6 KB/s"), (64400, "64 KB/s"),
    (999999, "1000 KB/s"), (1_000_000, "1.0 MB/s"),
    (99_999_999, "100.0 MB/s"), (100_000_000, "100 MB/s"),
    (999_999_999, "1000 MB/s"), (1_000_000_000, "1.0 GB/s"),
    (999_999_999_999, "1000.0 GB/s"), (1_000_000_000_000, "1.0 TB/s"),
    (99_999_900_000_000_000, "99999.9 TB/s")
]
for (rate, expected) in formats {
    check(NetworkSpeedStatusImage.formatRate(rate) == expected, "\(rate) must display as \(expected)")
}
for rate in [Double.nan, Double.infinity, -Double.infinity, -1] {
    check(NetworkSpeedStatusImage.formatRate(rate) == "0 KB/s", "invalid or negative rates must not reach the renderer")
}
let longRate = NetworkSpeedStatusImage.formatRate(99_999_900_000_000_000)
let cases: [(String, String, String)] = [
    ("maximum KB", "1000 KB/s", "1000 KB/s"),
    ("user 2 / 6", "2 KB/s", "6 KB/s"),
    ("user 64 / 6", "64 KB/s", "6 KB/s"),
    ("mixed", "8.0 MB/s", "999 KB/s"),
    ("idle", "0 KB/s", "0 KB/s"),
    ("pending", "—", "—"),
    ("overflow", longRate, "1000.0 GB/s")
]
var renders = [String: RenderedImage]()
var evidence = [String]()
for scale in [1, 2] {
    for (name, download, upload) in cases {
        let image = NetworkSpeedStatusImage.make(download: download, upload: upload)
        check(image.isTemplate && image.size.height == 22, "\(name): preserve the 22 pt template image")
        check(name == "overflow" ? image.size.width > 75 : image.size.width == 75,
              "\(name): normal values use 75 pt; only oversized text expands the value column")
        let rendered = render(image, scale: scale)
        renders["\(name)-\(scale)"] = rendered
        let bounds = rendered.bounds()!
        let icon = rendered.bounds(x: 0..<(18 * scale))!
        let row1 = rendered.rowBounds(y: 0..<(11 * scale))
        let row2 = rendered.rowBounds(y: (11 * scale)..<rendered.height)
        let text1 = row1.text
        let text2 = row2.text
        let bottom = bounds.minY
        let top = rendered.height - bounds.maxY - 1
        check(bottom >= scale && top >= scale && abs(Double(bottom - top)) / Double(scale) <= 1,
              "\(name) @\(scale)x: centered content needs at least 1 pt above and below")
        check(abs(rendered.verticalCenter() - 11) <= 1 && abs(icon.centerY / Double(scale) - 11) <= 1,
              "\(name) @\(scale)x: the values and retained icon must remain vertically centered")
        check(text1.maxY < text2.minY - 1 && bounds.maxX < rendered.width - scale,
              "\(name) @\(scale)x: rows stay separate and all text fits within the right edge")
        let rowsFit = [row1, row2].allSatisfy { row -> Bool in
            let textRight = Double(row.text.maxX + 1) / Double(scale)
            let arrowCenter = Double(row.arrow.minX + row.arrow.maxX + 1) / Double(2 * scale)
            return abs(textRight - (Double(image.size.width) - 2)) <= 1
                && abs(arrowCenter - 22.5) <= 0.5 && row.text.minX > row.arrow.maxX
        }
        check(rowsFit, "\(name) @\(scale)x: fixed arrows and complete right-aligned rates must not overlap; "
              + "width=\(image.size.width), row1=\(row1), row2=\(row2)")
        let iconGaps = [row1, row2].map { Double($0.arrow.minX - icon.maxX - 1) / Double(scale) }
        check(iconGaps.allSatisfy { (1...6).contains($0) },
              "\(name) @\(scale)x: the retained icon must sit close to the fixed arrow column")
        evidence.append("\(name) @\(scale)x: alpha y=\(bounds.minY)...\(bounds.maxY), padding=\(bottom)/\(top) px, "
            + "visual center=\(String(format: "%.2f", rendered.verticalCenter())) pt; icon y=\(icon.minY)...\(icon.maxY), "
            + "text rows=\(text1.minY)...\(text1.maxY) / \(text2.minY)...\(text2.maxY), "
            + "text right=\(text1.maxX)/\(text2.maxX) px, "
            + "arrow gaps=\(text1.minX - row1.arrow.maxX - 1)/\(text2.minX - row2.arrow.maxX - 1) px")
    }
    let maximum = renders["maximum KB-\(scale)"]!
    for (name, _, _) in cases where name != "maximum KB" {
        let other = renders["\(name)-\(scale)"]!
        check(maximum.alphaRegion(x: 0..<(25 * scale), y: 0..<maximum.height)
              == other.alphaRegion(x: 0..<(25 * scale), y: 0..<other.height),
              "\(name) @\(scale)x: icon and fixed arrows must not move as the displayed rate changes")
    }
}

// Build a labelled, enlarged preview from the exact tested alpha masks. This is an
// offscreen rendering preview, not a screenshot of the user's live menu bar.
let tileWidth = max(244, renders.values.map(\.width).max()! + 56)
let previewWidth = 119 + 2 * tileWidth + 44
let previewHeight = cases.count * 62 + 102
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
label("离屏渲染预览 · 真实生产 renderer · 非菜单栏截图", at: NSPoint(x: 18, y: previewHeight - 34), size: 17)
label("Stats 格式与固定列：箭头固定、数值右对齐；2× 原样着色，橙线为中线", at: NSPoint(x: 18, y: previewHeight - 57), size: 12)
for (index, item) in cases.enumerated() {
    let name = item.0
    let rendered = renders["\(name)-2"]!
    let y = CGFloat(previewHeight - 119 - index * 62)
    label(name, at: NSPoint(x: 18, y: y + 15), size: 12)
    for (column, dark) in [false, true].enumerated() {
        let rect = NSRect(x: 119 + column * (tileWidth + 26), y: Int(y), width: tileWidth, height: 50)
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
        tinted.draw(in: NSRect(x: rect.midX - CGFloat(rendered.width) / 2, y: rect.minY + 3,
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
