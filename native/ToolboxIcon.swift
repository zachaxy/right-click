import Cocoa

/// The open tray projects past the box; the diagonal gap marks its folding linkage.
enum ToolboxIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: bounds.minX, y: bounds.minY)
            context.scaleBy(x: bounds.width / 20, y: bounds.height / 20)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            defer { context.endTransparencyLayer() }

            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.setLineWidth(1.6)
            context.move(to: CGPoint(x: 1.8, y: 8))
            context.addLine(to: CGPoint(x: 1.8, y: 13.8))
            context.addQuadCurve(to: CGPoint(x: 4, y: 16), control: CGPoint(x: 1.8, y: 16))
            context.addLine(to: CGPoint(x: 14.3, y: 16))
            context.addQuadCurve(to: CGPoint(x: 16.5, y: 13.8), control: CGPoint(x: 16.5, y: 16))
            context.addLine(to: CGPoint(x: 16.5, y: 11))
            context.strokePath()

            context.addPath(CGPath(roundedRect: CGRect(x: 0.4, y: 3.2, width: 17, height: 6.8),
                                   cornerWidth: 0.8, cornerHeight: 0.8, transform: nil))
            context.addPath(CGPath(roundedRect: CGRect(x: 10, y: 9, width: 9.6, height: 3.3),
                                   cornerWidth: 0.55, cornerHeight: 0.55, transform: nil))
            context.fillPath()

            context.setBlendMode(.clear)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(1.5)
            context.move(to: CGPoint(x: 8.5, y: 5.7))
            context.addLine(to: CGPoint(x: 11.9, y: 9.1))
            context.addLine(to: CGPoint(x: 20, y: 9.1))
            context.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "趁手"
        return image
    }()
}
