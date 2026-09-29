import CoreGraphics

/// A display as the placement math sees it, in Cocoa global coordinates
/// (origin at the bottom-left of the primary display, y grows upwards).
public struct ScreenGeometry: Equatable, Sendable {
    public var frame: CGRect
    public var visibleFrame: CGRect
    /// On a display with a camera housing: the usable menu bar areas left and right
    /// of it (`NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`). Empty otherwise.
    public var menuBarAreasBesideNotch: [CGRect]

    public init(frame: CGRect, visibleFrame: CGRect, menuBarAreasBesideNotch: [CGRect] = []) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.menuBarAreasBesideNotch = menuBarAreasBesideNotch
    }

    /// True if a status item at `anchor` sits behind the camera housing. macOS keeps an
    /// overflowed status item's window "visible" at a real on-screen position there
    /// (observed on macOS 26.6: x 814-852 on a 1728pt display whose notch spans 771-956).
    public func isBehindNotch(_ anchor: CGRect) -> Bool {
        guard !menuBarAreasBesideNotch.isEmpty else { return false }
        return !menuBarAreasBesideNotch.contains { anchor.midX >= $0.minX && anchor.midX <= $0.maxX }
    }
}

/// Pure positioning rules for the reminder panel (SPEC §9.1).
public enum PanelPlacement {
    /// Space between the status item's bottom edge and the panel's top edge.
    public static let gap: CGFloat = 4
    /// Inset from the visible frame's edges (clamping and the top-right fallback).
    public static let margin: CGFloat = 8

    /// Where the panel goes.
    ///
    /// - Parameters:
    ///   - panelSize: the panel's size.
    ///   - anchor: the status item button's screen frame, or nil if the button
    ///     has no window or its window isn't on screen.
    ///   - screens: every attached display.
    ///   - fallbackScreen: index into `screens` of the screen with the active
    ///     window; used when the anchor is unusable.
    public static func frame(
        panelSize: CGSize,
        anchor: CGRect?,
        screens: [ScreenGeometry],
        fallbackScreen: Int
    ) -> CGRect {
        precondition(!screens.isEmpty, "at least one screen")
        if let anchor, let index = screenIndex(forAnchor: anchor, in: screens) {
            return anchored(panelSize: panelSize, anchor: anchor, visibleFrame: screens[index].visibleFrame)
        }
        let index = screens.indices.contains(fallbackScreen) ? fallbackScreen : 0
        return topRight(panelSize: panelSize, visibleFrame: screens[index].visibleFrame)
    }

    /// The screen an anchor belongs to, or nil if the anchor is empty, off every
    /// screen (menu bar auto-hidden in fullscreen) or behind the notch (notch overflow).
    public static func screenIndex(forAnchor anchor: CGRect, in screens: [ScreenGeometry]) -> Int? {
        guard !anchor.isNull, !anchor.isInfinite, anchor.width > 0, anchor.height > 0 else { return nil }
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        guard let i = screens.firstIndex(where: { $0.frame.contains(center) }) else { return nil }
        return screens[i].isBehindNotch(anchor) ? nil : i
    }

    /// Centered under the anchor, top edge `gap` below it, clamped to the visible frame.
    public static func anchored(panelSize: CGSize, anchor: CGRect, visibleFrame: CGRect) -> CGRect {
        let x = anchor.midX - panelSize.width / 2
        let y = anchor.minY - gap - panelSize.height
        return clamp(CGRect(origin: CGPoint(x: x, y: y), size: panelSize), to: visibleFrame)
    }

    /// Top-right corner of the visible frame, inset by `margin`.
    public static func topRight(panelSize: CGSize, visibleFrame: CGRect) -> CGRect {
        let origin = CGPoint(
            x: visibleFrame.maxX - margin - panelSize.width,
            y: visibleFrame.maxY - margin - panelSize.height
        )
        return clamp(CGRect(origin: origin, size: panelSize), to: visibleFrame)
    }

    /// Keeps the rect inside `bounds` (inset by `margin` horizontally). If the rect is
    /// larger than the bounds, its top-left corner wins.
    public static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        var r = rect
        let minX = bounds.minX + margin
        let maxX = bounds.maxX - margin - r.width
        r.origin.x = maxX < minX ? minX : min(max(r.origin.x, minX), maxX)
        let minY = bounds.minY
        let maxY = bounds.maxY - r.height
        r.origin.y = maxY < minY ? maxY : min(max(r.origin.y, minY), maxY)
        return r
    }

    /// Converts a rect from Quartz window-list coordinates (origin at the top-left
    /// of the primary display, y grows downwards) to Cocoa global coordinates.
    public static func cocoaRect(fromQuartz rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Index of the screen that contains most of `rect`, or nil if it's on none.
    public static func screenIndex(containingMostOf rect: CGRect, in screens: [ScreenGeometry]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (i, s) in screens.enumerated() {
            let inter = s.frame.intersection(rect)
            guard !inter.isNull else { continue }
            let area = inter.width * inter.height
            if area > 0, area > (best?.area ?? 0) { best = (i, area) }
        }
        return best?.index
    }
}
