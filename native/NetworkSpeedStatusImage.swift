import Cocoa
import CoreText

/// Draw both rows in one centered template image, rather than a multiline button title.
enum NetworkSpeedStatusImage {
    static let size = NSSize(width: 94, height: 22)

    static func make(download: String, upload: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.black.cgColor
        ]
        let icon = NSImage(systemSymbolName: "cursorarrow.click", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.textMatrix = .identity
            icon?.draw(in: NSRect(x: 1, y: 4, width: 14, height: 14))

            // A shared reference baseline keeps the rows still when digits/units change.
            context.textPosition = .zero
            let reference = CTLineCreateWithAttributedString(NSAttributedString(string: "999.9 KB/s", attributes: attributes))
            let baselineOffset = CTLineGetImageBounds(reference, context).midY
            drawRow(download, centerY: 16, down: true, baselineOffset: baselineOffset,
                    attributes: attributes, context: context)
            drawRow(upload, centerY: 6, down: false, baselineOffset: baselineOffset,
                    attributes: attributes, context: context)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "下载 \(download)，上传 \(upload)"
        return image
    }

    private static func drawRow(_ text: String, centerY: CGFloat, down: Bool,
                                baselineOffset: CGFloat, attributes: [NSAttributedString.Key: Any],
                                context: CGContext) {
        let baseline = centerY - baselineOffset
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let textX = 90 - CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.textPosition = CGPoint(x: textX, y: baseline)
        CTLineDraw(line, context)

        // Right-align each complete rate, moving its arrow along with the text.
        let arrowX = textX - 7
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
