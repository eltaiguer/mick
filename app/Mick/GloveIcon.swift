import AppKit
import MickCore

/// Mick's menu bar glyph: an original boxing glove drawn in code (no film imagery,
/// decision 13). Template images, so the menu bar tints them.
///
/// - calm: the glove.
/// - armed: the glove with two motion strokes (a jab on the way).
/// - glaring: the glove with three heavier strokes and an impact spark.
/// - warning: the glove with a "!" badge.
/// Snoozed and paused use the calm glove until #10 gives them their own look.
enum GloveIcon {
    static let size = NSSize(width: 18, height: 18)

    static func image(for icon: MenuBarIcon) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            switch icon {
            case .armed:
                drawGlove(shiftedBy: -1.5)
                drawMotionStrokes(count: 2, width: 1.2)
            case .glaring:
                drawGlove(shiftedBy: -2)
                drawMotionStrokes(count: 3, width: 1.5)
                drawSpark()
            case .warning:
                drawGlove()
                drawWarningBadge()
            case .calm, .snoozed, .paused:
                drawGlove()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description(for: icon)
        return image
    }

    static func description(for icon: MenuBarIcon) -> String {
        switch icon {
        case .calm: "Mick"
        case .armed: "Mick, armed: you've been sitting a while"
        case .glaring: "Mick, glaring: you've been sitting way too long"
        case .warning: "Mick, hooks not detected"
        case .snoozed: "Mick, snoozed"
        case .paused: "Mick, paused"
        }
    }

    /// Short horizontal strokes to the right of the fist, knocked out where they touch it.
    private static func drawMotionStrokes(count: Int, width: CGFloat) {
        let ys: [CGFloat] = count >= 3 ? [14.5, 11.25, 8] : [13, 9.5]
        let lengths: [CGFloat] = count >= 3 ? [3, 4, 3] : [3, 3]
        NSColor.black.setStroke()
        for (y, length) in zip(ys, lengths) {
            let stroke = NSBezierPath()
            stroke.move(to: NSPoint(x: 17.5 - length, y: y))
            stroke.line(to: NSPoint(x: 17.5, y: y))
            stroke.lineWidth = width
            stroke.lineCapStyle = .round
            stroke.stroke()
        }
    }

    /// A small four-point spark in the top right corner.
    private static func drawSpark() {
        NSColor.black.setFill()
        let c = NSPoint(x: 15.5, y: 3)
        let spark = NSBezierPath()
        spark.move(to: NSPoint(x: c.x, y: c.y + 2.5))
        spark.line(to: NSPoint(x: c.x + 0.7, y: c.y + 0.7))
        spark.line(to: NSPoint(x: c.x + 2.5, y: c.y))
        spark.line(to: NSPoint(x: c.x + 0.7, y: c.y - 0.7))
        spark.line(to: NSPoint(x: c.x, y: c.y - 2.5))
        spark.line(to: NSPoint(x: c.x - 0.7, y: c.y - 0.7))
        spark.line(to: NSPoint(x: c.x - 2.5, y: c.y))
        spark.line(to: NSPoint(x: c.x - 0.7, y: c.y + 0.7))
        spark.close()
        spark.fill()
    }

    private static func drawGlove(shiftedBy dx: CGFloat = 0) {
        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }
        let shift = NSAffineTransform()
        shift.translateX(by: dx, yBy: 0)
        shift.concat()
        NSColor.black.setFill()
        // Fist: a rounded mitt leaning slightly right.
        let fist = NSBezierPath(roundedRect: NSRect(x: 4, y: 6, width: 11, height: 10.5), xRadius: 5, yRadius: 5)
        fist.fill()
        // Thumb along the left side.
        let thumb = NSBezierPath(roundedRect: NSRect(x: 2, y: 7, width: 4.5, height: 6.5), xRadius: 2.25, yRadius: 2.25)
        thumb.fill()
        // Cuff, separated from the fist by a thin gap.
        let cuff = NSBezierPath(roundedRect: NSRect(x: 5, y: 1.5, width: 8.5, height: 3.5), xRadius: 1.2, yRadius: 1.2)
        cuff.fill()
        // The seam between thumb and fist.
        NSGraphicsContext.current?.compositingOperation = .clear
        let seam = NSBezierPath()
        seam.move(to: NSPoint(x: 6.6, y: 8))
        seam.curve(to: NSPoint(x: 6.2, y: 13), controlPoint1: NSPoint(x: 7.4, y: 9.5), controlPoint2: NSPoint(x: 7.2, y: 12))
        seam.lineWidth = 0.9
        seam.stroke()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }

    /// A round "!" badge in the lower right, knocked out of the glove.
    private static func drawWarningBadge() {
        let badge = NSRect(x: 10, y: 0, width: 8, height: 8)
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: badge.insetBy(dx: -1, dy: -1)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        NSColor.black.setFill()
        NSBezierPath(ovalIn: badge).fill()
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(roundedRect: NSRect(x: 13.4, y: 3.2, width: 1.2, height: 3.6), xRadius: 0.6, yRadius: 0.6).fill()
        NSBezierPath(ovalIn: NSRect(x: 13.4, y: 1.3, width: 1.2, height: 1.2)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }
}
