import Cocoa
import CoreText

/// Value-equatable snapshot of the menu bar item's visual and accessibility state,
/// allowing 1 Hz timer updates to skip NSStatusItem redraws when the formatted output is unchanged.
enum TrayAppearanceState: Equatable {
    case iconOnly
    case networkSpeed(download: String, upload: String, detail: String)

    static func make(showNetworkSpeed: Bool, available: Bool, unavailable: Bool = false,
                     downloadBytesPerSecond: Double = 0, uploadBytesPerSecond: Double = 0,
                     interfaces: [String] = []) -> TrayAppearanceState {
        guard showNetworkSpeed else { return .iconOnly }
        let download = available ? NetworkSpeedStatusImage.formatRate(downloadBytesPerSecond) : "—"
        let upload = available ? NetworkSpeedStatusImage.formatRate(uploadBytesPerSecond) : "—"
        let detail: String
        if available {
            detail = "下载 \(download) · 上传 \(upload)\n接口：\(interfaces.joined(separator: ", "))（含局域网流量）"
        } else {
            detail = unavailable ? "暂无法读取网速，请检查网络连接" : "正在采样网速…"
        }
        return .networkSpeed(download: download, upload: upload, detail: detail)
    }

    func hasSameRates(as other: TrayAppearanceState?) -> Bool {
        guard case let .networkSpeed(d1, u1, _) = self,
              case let .networkSpeed(d2, u2, _)? = other else { return false }
        return d1 == d2 && u1 == u2
    }
}

/// Draw both rows in one centered template image, rather than a multiline button title.
enum NetworkSpeedStatusImage {
    private static let font = NSFont.systemFont(ofSize: 9, weight: .light)
    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.black.cgColor
    ]
    private static let referenceLine = CTLineCreateWithAttributedString(
        NSAttributedString(string: "999.9 KB/s", attributes: attributes)
    )

    // Stats' two-row layout uses a 7 pt icon column and a 48 pt rate column.
    // https://github.com/exelban/stats/blob/3e97046d7032c514fe631812b2a3ed36122a706b/Kit/Widgets/Speed.swift#L338-L401
    // Prefix our 14 pt app icon, with Stats' 2 pt combined-widget spacing/margins.
    static func formatRate(_ bytesPerSecond: Double) -> String {
        // Match Stats' decimal byte display, including its sub-KB idle display.
        // https://github.com/exelban/stats/blob/3e97046d7032c514fe631812b2a3ed36122a706b/Kit/helpers.swift#L152-L180
        guard bytesPerSecond.isFinite, bytesPerSecond >= 1000 else { return "0 KB/s" }
        let units = ["KB/s", "MB/s", "GB/s", "TB/s"]
        var value = bytesPerSecond / 1000
        var unit = 0
        while value >= 1000 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let fractional = unit >= 2 || (unit == 1 && value < 100)
        return String(format: fractional ? "%.1f %@" : "%.0f %@",
                      locale: Locale(identifier: "en_US_POSIX"), value, units[unit])
    }

    static func make(download: String, upload: String) -> NSImage {
        let lines = [download, upload].map {
            CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes))
        }
        // Keep ordinary values at Stats' fixed width. Allow unusually long rates
        // to grow instead of clipping (e.g. a rounded 1000.0 GB/s).
        let valueWidth = max(48, ceil(lines.map { CTLineGetTypographicBounds($0, nil, nil, nil) }.max()!))
        let size = NSSize(width: 25 + valueWidth + 2, height: 22)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.textMatrix = .identity
            ToolboxIcon.image.draw(in: NSRect(x: 2, y: 4, width: 14, height: 14))

            // A shared reference baseline keeps the rows still when digits/units change.
            context.textPosition = .zero
            let baselineOffset = CTLineGetImageBounds(referenceLine, context).midY
            drawRow(lines[0], rightEdge: size.width - 2, centerY: 16, down: true,
                    baselineOffset: baselineOffset, context: context)
            drawRow(lines[1], rightEdge: size.width - 2, centerY: 6, down: false,
                    baselineOffset: baselineOffset, context: context)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "下载 \(download)，上传 \(upload)"
        return image
    }

    private static func drawRow(_ line: CTLine, rightEdge: CGFloat, centerY: CGFloat, down: Bool,
                                baselineOffset: CGFloat,
                                context: CGContext) {
        let baseline = centerY - baselineOffset
        let textX = rightEdge - CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.textPosition = CGPoint(x: textX, y: baseline)
        CTLineDraw(line, context)

        // Stats keeps both arrows in one fixed column, independent of the digits.
        let arrowX: CGFloat = 22.5
        let tipY = centerY + (down ? -2.5 : 2.5)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(1)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: arrowX, y: centerY + (down ? 2.5 : -2.5)))
        context.addLine(to: CGPoint(x: arrowX, y: tipY))
        context.move(to: CGPoint(x: arrowX - 2, y: tipY + (down ? 2 : -2)))
        context.addLine(to: CGPoint(x: arrowX, y: tipY))
        context.addLine(to: CGPoint(x: arrowX + 2, y: tipY + (down ? 2 : -2)))
        context.strokePath()
    }

}
