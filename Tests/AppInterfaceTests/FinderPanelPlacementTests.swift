import Foundation
import CoreGraphics
import Testing

struct FinderPanelPlacementTests {
    @Test func panelWaitsUntilTheWindowSettles() {
        var policy = FinderPanelPlacement(settleDelay: 0.3)
        let first = CGRect(x: 10, y: 10, width: 600, height: 400)
        let moved = CGRect(x: 100, y: 10, width: 600, height: 400)
        #expect(policy.update(frame: first, now: 0) == .waiting)
        #expect(policy.update(frame: first, now: 0.4) == .visible)
        #expect(policy.update(frame: moved, now: 1) == .waiting)
        #expect(policy.update(frame: moved, now: 1.2) == .waiting)
        #expect(policy.update(frame: moved, now: 1.4) == .visible)
    }

    @Test func resizingRestartsTheSettlePeriod() {
        var policy = FinderPanelPlacement(settleDelay: 0.3)
        let frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        _ = policy.update(frame: frame, now: 0)
        #expect(policy.update(frame: frame, now: 1) == .visible)
        var resized = frame
        resized.size.width = 700
        #expect(policy.update(frame: resized, now: 2) == .waiting)
        #expect(policy.update(frame: resized, now: 2.4) == .visible)
    }

    @Test func leavingFinderClearsThePreviousFrame() {
        var policy = FinderPanelPlacement()
        let frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        _ = policy.update(frame: frame, now: 0)
        #expect(policy.update(frame: nil, now: 1) == .hidden)
        #expect(policy.update(frame: frame, now: 2) == .waiting)
    }

    @Test func placementChoosesAnAvailableSide() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 300, height: 420)
        let finder = CGRect(x: 100, y: 200, width: 700, height: 500)
        #expect(FinderPanelPlacement.panelFrame(beside: finder, size: size, screen: screen)?.minX == 812)
        let right = CGRect(x: 700, y: 200, width: 700, height: 500)
        #expect(FinderPanelPlacement.panelFrame(beside: right, size: size, screen: screen)?.maxX == 688)
    }

    @Test func centeredAndMaximizedFinderWindowsNeverGetAnOverlay() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 900)
        let size = CGSize(width: 300, height: 420)
        let centered = CGRect(x: 267, y: 200, width: 978, height: 550)
        #expect(FinderPanelPlacement.panelFrame(beside: centered, size: size, screen: screen) == nil)
        #expect(FinderPanelPlacement.panelFrame(beside: screen, size: size, screen: screen) == nil)
        let moved = CGRect(x: 20, y: 200, width: 978, height: 550)
        #expect(FinderPanelPlacement.panelFrame(beside: moved, size: size, screen: screen) != nil)
    }

    @Test func aTightFitStillRequiresTheEntireGap() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let size = CGSize(width: 300, height: 420)
        let exact = CGRect(x: 0, y: 200, width: 888, height: 500)
        #expect(FinderPanelPlacement.panelFrame(beside: exact, size: size, screen: screen)?.maxX == screen.maxX)
        var tooWide = exact
        tooWide.size.width += 1
        #expect(FinderPanelPlacement.panelFrame(beside: tooWide, size: size, screen: screen) == nil)
    }

    @Test func expandedPanelFitsTheUsersCenteredFinderWithoutMovingIt() throws {
        let screen = CGRect(x: 0, y: 75, width: 1512, height: 874)
        let finder = CGRect(x: 274, y: 199, width: 978, height: 547)
        let layout = try #require(FinderPanelPlacement.layout(beside: finder, screen: screen, preferredMode: .expanded))
        #expect(layout.mode == .expanded)
        #expect(layout.frame.width == 248)
        #expect(layout.frame.minX - finder.maxX == 12)
        #expect(screen.contains(layout.frame))
        #expect(!finder.intersects(layout.frame))
    }

    @Test func compactPanelCollapsesHorizontallyAndRetainsTheExpandedHeight() throws {
        let expanded = FinderPanelPlacement.Mode.expanded.preferredSize
        let compact = FinderPanelPlacement.Mode.compact.preferredSize
        #expect(compact.width < expanded.width * 0.35)
        #expect(compact.height == expanded.height)
        let layout = try #require(FinderPanelPlacement.layout(beside: CGRect(x: 0, y: 100, width: 700, height: 600),
                                                              screen: CGRect(x: 0, y: 0, width: 1440, height: 900), preferredMode: .compact))
        #expect(layout.mode == .compact)
        #expect(layout.frame.size == compact)
    }

    @Test func insufficientExpandedSpaceUsesCompactAndRestoresExpandedWhenSpaceReturns() throws {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 900)
        let wideFinder = CGRect(x: 0, y: 100, width: 1280, height: 600)
        let compact = try #require(FinderPanelPlacement.layout(beside: wideFinder, screen: screen, preferredMode: .expanded))
        #expect(compact.mode == .compact)
        #expect(compact.frame.width == 96)
        #expect(!compact.frame.intersects(wideFinder))
        let narrowerFinder = CGRect(x: 0, y: 100, width: 1000, height: 600)
        #expect(FinderPanelPlacement.layout(beside: narrowerFinder, screen: screen, preferredMode: .expanded)?.mode == .expanded)
        #expect(FinderPanelPlacement.layout(beside: narrowerFinder, screen: screen, preferredMode: .compact)?.mode == .compact)
    }

    @Test func responsivePlacementUsesTheLeftSideAndKeepsCompactControlsUsable() throws {
        let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let finder = CGRect(x: -1188, y: 100, width: 1188, height: 600)
        let layout = try #require(FinderPanelPlacement.layout(beside: finder, screen: screen, preferredMode: .expanded))
        #expect(layout.mode == .expanded)
        #expect(layout.frame.width == 240)
        #expect(finder.minX - layout.frame.maxX == 12)
        #expect(FinderPanelPlacement.layout(beside: screen, screen: screen, preferredMode: .compact) == nil)
        let narrowGap = CGRect(x: -1440, y: 100, width: 1333, height: 600)
        #expect(FinderPanelPlacement.layout(beside: narrowGap, screen: screen, preferredMode: .compact) == nil)
    }

    @Test func shortDisplaysUseCompactInsteadOfClippingTheExpandedView() throws {
        let finder = CGRect(x: 0, y: 0, width: 700, height: 200)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 300)
        let layout = try #require(FinderPanelPlacement.layout(beside: finder, screen: screen, preferredMode: .expanded))
        #expect(layout.mode == .compact)
        #expect(screen.contains(layout.frame))
        #expect(FinderPanelPlacement.layout(beside: finder, screen: CGRect(x: 0, y: 0, width: 1440, height: 270), preferredMode: .compact) == nil)
    }

    @Test func panelKeepsItsSizeOnOffsetScreensAndClampsVertically() throws {
        let screen = CGRect(x: -1280, y: -300, width: 1280, height: 800)
        let size = CGSize(width: 300, height: 420)
        let finder = CGRect(x: -1200, y: -250, width: 700, height: 300)
        let panel = try #require(FinderPanelPlacement.panelFrame(beside: finder, size: size, screen: screen))
        #expect(screen.contains(panel))
        #expect(panel.size == size)
        #expect(panel.minX - finder.maxX == 12)
        #expect(panel.minY == screen.minY)
        let raised = finder.offsetBy(dx: 0, dy: 650)
        let topPanel = try #require(FinderPanelPlacement.panelFrame(beside: raised, size: size, screen: screen))
        #expect(topPanel.maxY == screen.maxY)
    }

    @Test func insufficientHeightAndOffscreenFinderDoNotCreateClippedPanels() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 400)
        let finder = CGRect(x: 0, y: 0, width: 700, height: 300)
        let size = CGSize(width: 300, height: 420)
        #expect(FinderPanelPlacement.panelFrame(beside: finder, size: size, screen: screen) == nil)
        #expect(FinderPanelPlacement.panelFrame(beside: finder.offsetBy(dx: 2000, dy: 0), size: size,
                                              screen: CGRect(x: 0, y: 0, width: 1440, height: 900)) == nil)
    }

    @Test(arguments: [CGRect(x: 0, y: 40, width: 1440, height: 860),
                      CGRect(x: -1920, y: -300, width: 1920, height: 1080),
                      CGRect(x: 0, y: 900, width: 1200, height: 800)])
    func everyReturnedFrameFitsOutsideFinder(screen: CGRect) {
        let size = CGSize(width: 300, height: 420)
        for x in stride(from: screen.minX - 250, through: screen.maxX, by: 125) {
            for width: CGFloat in [500, 900, 1400] {
                let finder = CGRect(x: x, y: screen.minY + 100, width: width, height: 600)
                if let panel = FinderPanelPlacement.panelFrame(beside: finder, size: size, screen: screen) {
                    #expect(screen.contains(panel))
                    #expect(panel.size == size)
                    #expect(!finder.intersects(panel))
                    #expect(panel.minX - finder.maxX >= 12 || finder.minX - panel.maxX >= 12)
                }
                for mode: FinderPanelPlacement.Mode in [.expanded, .compact] {
                    if let layout = FinderPanelPlacement.layout(beside: finder, screen: screen, preferredMode: mode) {
                        #expect(screen.contains(layout.frame))
                        #expect(!finder.intersects(layout.frame))
                        #expect(layout.frame.width >= layout.mode.minimumSize.width)
                        #expect(layout.frame.height >= layout.mode.minimumSize.height)
                        #expect(layout.frame.minX - finder.maxX >= 12 || finder.minX - layout.frame.maxX >= 12)
                    }
                }
            }
        }
    }

    @Test func contextRequiresAnActualDescendant() {
        let root = URL(fileURLWithPath: "/tmp/findle-location")
        #expect(FinderPanelPlacement.relativePath(of: root, under: root) == [])
        #expect(FinderPanelPlacement.relativePath(of: root.appendingPathComponent("Course/Week 1"), under: root) == ["Course", "Week 1"])
        #expect(FinderPanelPlacement.relativePath(of: URL(fileURLWithPath: "/tmp/findle-location-other/Course"), under: root) == nil)
        #expect(FinderPanelPlacement.relativePath(of: root.appendingPathComponent("../outside"), under: root) == nil)
    }

    @Test func modeTransitionsKeepTheirEntirePathOutsideFinder() {
        let finder = CGRect(x: 400, y: 100, width: 700, height: 600)
        for right in [true, false] {
            let compact = CGRect(x: right ? 1112 : 292, y: 340, width: 96, height: 360)
            let expanded = CGRect(x: right ? 1112 : 108, y: 340, width: 280, height: 360)
            #expect(FinderPanelPlacement.canAnimateTransition(from: compact, to: expanded, beside: finder))
            #expect(FinderPanelPlacement.canAnimateTransition(from: expanded, to: compact, beside: finder))
            for progress: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
                let intermediate = CGRect(x: compact.minX + (expanded.minX - compact.minX) * progress,
                                          y: compact.minY,
                                          width: compact.width + (expanded.width - compact.width) * progress,
                                          height: compact.height)
                #expect(!intermediate.intersects(finder))
                #expect(right ? intermediate.minX - finder.maxX == 12 : finder.minX - intermediate.maxX == 12)
            }
        }
    }

    @Test func modeTransitionsCannotTravelAcrossOrTooCloseToFinder() {
        let finder = CGRect(x: 400, y: 100, width: 700, height: 600)
        let right = CGRect(x: 1112, y: 340, width: 96, height: 360)
        let left = CGRect(x: 108, y: 340, width: 280, height: 360)
        #expect(!FinderPanelPlacement.canAnimateTransition(from: right, to: left, beside: finder))
        #expect(!FinderPanelPlacement.canAnimateTransition(from: right, to: right.offsetBy(dx: -1, dy: 0), beside: finder))
        #expect(!FinderPanelPlacement.canAnimateTransition(from: .zero, to: right, beside: finder))
    }
}
