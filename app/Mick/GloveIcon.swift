import AppKit
import MickCore

/// Mick's menu bar glyph: an original boxing glove drawn in code (no film imagery,
/// decision 13). Template images, so the menu bar tints them. States other than
/// calm and warning use the calm glove until #5 and #10 give them their own look.
enum GloveIcon {
    static let size = NSSize(width: 18, height: 18)

    static func image(for icon: MenuBarIcon) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            drawGlove()
            if icon == .warning { drawWarningBadge() }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = icon == .warning ? "Mick, hooks not detected" : "Mick"
        return image
    }

    private static func drawGlove() {
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
