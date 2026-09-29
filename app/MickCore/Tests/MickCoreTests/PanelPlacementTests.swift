import CoreGraphics
import Foundation
import Testing
import MickCore

/// Positioning rules (SPEC §9.1), with synthetic display layouts.
@Suite struct PanelPlacementTests {
    // A 1512x982 laptop display with a 33pt menu bar, primary.
    let laptop = ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949)
    )
    // A 2560x1440 external display to the right, top-aligned, with its own menu bar.
    let external = ScreenGeometry(
        frame: CGRect(x: 1512, y: -458, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: -458, width: 2560, height: 1415)
    )
    let size = CGSize(width: 320, height: 180)

    @Test func centeredJustBelowTheStatusItem() {
        let anchor = CGRect(x: 1000, y: 949, width: 30, height: 33)
        let f = PanelPlacement.frame(panelSize: size, anchor: anchor, screens: [laptop], fallbackScreen: 0)
        #expect(f.midX == anchor.midX)
        #expect(f.maxY == anchor.minY - PanelPlacement.gap)
        #expect(f.size == size)
    }

    @Test func clampedAtTheRightEdge() {
        let anchor = CGRect(x: 1480, y: 949, width: 30, height: 33)
        let f = PanelPlacement.frame(panelSize: size, anchor: anchor, screens: [laptop], fallbackScreen: 0)
        #expect(f.maxX == laptop.visibleFrame.maxX - PanelPlacement.margin)
        #expect(f.maxY == anchor.minY - PanelPlacement.gap)
    }

    @Test func clampedAtTheLeftEdge() {
        let anchor = CGRect(x: 2, y: 949, width: 30, height: 33)
        let f = PanelPlacement.frame(panelSize: size, anchor: anchor, screens: [laptop], fallbackScreen: 0)
        #expect(f.minX == laptop.visibleFrame.minX + PanelPlacement.margin)
    }

    @Test func staysInsideTheVisibleFrameVertically() {
        // Anchor reported inside the menu bar area of a screen whose visible frame
        // reaches the top (menu bar auto-hidden): never above the visible frame.
        let autoHidden = ScreenGeometry(frame: laptop.frame, visibleFrame: laptop.frame)
        let anchor = CGRect(x: 700, y: 990 - 33, width: 30, height: 33)
        let f = PanelPlacement.frame(panelSize: size, anchor: anchor, screens: [autoHidden], fallbackScreen: 0)
        #expect(f.maxY <= autoHidden.visibleFrame.maxY)
        #expect(autoHidden.visibleFrame.contains(f))
    }

    @Test func anchorOnTheSecondDisplayUsesThatDisplay() {
        let anchor = CGRect(x: 3500, y: 957, width: 30, height: 25)
        let f = PanelPlacement.frame(panelSize: size, anchor: anchor, screens: [laptop, external], fallbackScreen: 0)
        #expect(external.visibleFrame.contains(f))
        #expect(f.maxY == anchor.minY - PanelPlacement.gap)
        #expect(f.midX == anchor.midX)
    }

    @Test func secondaryDisplayBelowThePrimary() {
        let below = ScreenGeometry(
            frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: -1080, width: 1920, height: 1055)
        )
        let anchor = CGRect(x: 1500, y: -25, width: 30, height: 25)
        let f = PanelPlacement.frame(panelSize: size, anchor: anchor, screens: [laptop, below], fallbackScreen: 0)
        #expect(below.visibleFrame.contains(f))
    }

    @Test func missingAnchorFallsBackToTopRightOfActiveScreen() {
        let f = PanelPlacement.frame(panelSize: size, anchor: nil, screens: [laptop, external], fallbackScreen: 1)
        #expect(f.maxX == external.visibleFrame.maxX - PanelPlacement.margin)
        #expect(f.maxY == external.visibleFrame.maxY - PanelPlacement.margin)
    }

    @Test func emptyAnchorFallsBack() {
        let f = PanelPlacement.frame(panelSize: size, anchor: .zero, screens: [laptop], fallbackScreen: 0)
        #expect(f == PanelPlacement.topRight(panelSize: size, visibleFrame: laptop.visibleFrame))
    }

    @Test func offScreenAnchorFallsBack() {
        // Notch overflow / auto-hidden menu bar: the button window sits above or
        // beside every display.
        for anchor in [
            CGRect(x: 700, y: 1000, width: 30, height: 33),
            CGRect(x: -500, y: 949, width: 30, height: 33),
            CGRect(x: 10_000, y: 10_000, width: 30, height: 33),
        ] {
            let f = PanelPlacement.frame(panelSize: size, anchor: anchor, screens: [laptop], fallbackScreen: 0)
            #expect(f == PanelPlacement.topRight(panelSize: size, visibleFrame: laptop.visibleFrame))
        }
    }

    // The real layout observed on this machine: 1728x1117 built-in display, notch
    // between x 771 and 956, the spike's status item overflowed to x 822.
    let notched = ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        visibleFrame: CGRect(x: 0, y: 92, width: 1728, height: 992),
        menuBarAreasBesideNotch: [
            CGRect(x: 0, y: 1085, width: 771, height: 32),
            CGRect(x: 956, y: 1085, width: 772, height: 32),
        ]
    )

    @Test func statusItemBehindTheNotchFallsBackToTopRight() {
        let overflowed = CGRect(x: 822, y: 1085.5, width: 22, height: 31)
        #expect(notched.isBehindNotch(overflowed))
        let f = PanelPlacement.frame(panelSize: size, anchor: overflowed, screens: [notched], fallbackScreen: 0)
        #expect(f == PanelPlacement.topRight(panelSize: size, visibleFrame: notched.visibleFrame))
        #expect(f.maxX == notched.visibleFrame.maxX - PanelPlacement.margin)
        #expect(f.maxY == notched.visibleFrame.maxY - PanelPlacement.margin)
    }

    @Test func statusItemRightOfTheNotchIsAnchored() {
        let visible = CGRect(x: 1300, y: 1085.5, width: 22, height: 31)
        #expect(!notched.isBehindNotch(visible))
        let f = PanelPlacement.frame(panelSize: size, anchor: visible, screens: [notched], fallbackScreen: 0)
        #expect(f.midX == visible.midX)
        #expect(f.maxY == visible.minY - PanelPlacement.gap)
    }

    @Test func screenWithoutNotchNeverReportsBehindNotch() {
        #expect(!laptop.isBehindNotch(CGRect(x: 740, y: 949, width: 30, height: 33)))
    }

    @Test func outOfRangeFallbackIndexUsesFirstScreen() {
        let f = PanelPlacement.frame(panelSize: size, anchor: nil, screens: [laptop], fallbackScreen: 5)
        #expect(laptop.visibleFrame.contains(f))
    }

    @Test func panelBiggerThanScreenKeepsTopLeft() {
        let tiny = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 200, height: 100),
                                  visibleFrame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let f = PanelPlacement.clamp(CGRect(origin: CGPoint(x: 50, y: -50), size: size), to: tiny.visibleFrame)
        #expect(f.minX == PanelPlacement.margin)
        #expect(f.maxY == tiny.visibleFrame.maxY)
    }

    @Test func quartzToCocoaConversion() {
        // A window at the very top-left of the primary display in Quartz space.
        let r = PanelPlacement.cocoaRect(fromQuartz: CGRect(x: 10, y: 0, width: 100, height: 50), primaryScreenHeight: 982)
        #expect(r == CGRect(x: 10, y: 932, width: 100, height: 50))
        // A window on a display above the primary (negative Quartz y).
        let above = PanelPlacement.cocoaRect(fromQuartz: CGRect(x: 0, y: -600, width: 100, height: 100), primaryScreenHeight: 982)
        #expect(above.minY == 1482)
    }

    @Test func activeWindowScreenPicksLargestOverlap() {
        let straddling = CGRect(x: 1400, y: 100, width: 600, height: 400) // mostly on external
        #expect(PanelPlacement.screenIndex(containingMostOf: straddling, in: [laptop, external]) == 1)
        let onLaptop = CGRect(x: 100, y: 100, width: 600, height: 400)
        #expect(PanelPlacement.screenIndex(containingMostOf: onLaptop, in: [laptop, external]) == 0)
        let nowhere = CGRect(x: -5000, y: -5000, width: 10, height: 10)
        #expect(PanelPlacement.screenIndex(containingMostOf: nowhere, in: [laptop, external]) == nil)
    }
}
