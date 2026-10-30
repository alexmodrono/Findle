import Foundation
import CoreGraphics

/// Geometry policy shared by the native observer and focused unit tests.
struct FinderPanelPlacement {
    enum Mode: String {
        case expanded
        case compact

        var preferredSize: CGSize {
            switch self {
            case .expanded: CGSize(width: 280, height: 360)
            case .compact: CGSize(width: 96, height: 360)
            }
        }

        var minimumSize: CGSize {
            switch self {
            case .expanded: CGSize(width: 240, height: 320)
            case .compact: CGSize(width: 96, height: 340)
            }
        }
    }

    struct Layout: Equatable {
        let frame: CGRect
        let mode: Mode
    }

    enum Visibility: Equatable {
        case hidden
        case waiting
        case visible
    }

    private(set) var frame: CGRect?
    private var changedAt: TimeInterval = 0
    let settleDelay: TimeInterval

    init(settleDelay: TimeInterval = 0.3) { self.settleDelay = settleDelay }

    mutating func update(frame candidate: CGRect?, now: TimeInterval) -> Visibility {
        guard let candidate, candidate.width > 0, candidate.height > 0 else {
            frame = nil
            return .hidden
        }
        if frame != candidate {
            frame = candidate
            changedAt = now
            return .waiting
        }
        return now - changedAt >= settleDelay ? .visible : .waiting
    }

    static func layout(beside finder: CGRect, screen: CGRect, preferredMode: Mode, gap: CGFloat = 12) -> Layout? {
        let modes: [Mode] = preferredMode == .expanded ? [.expanded, .compact] : [.compact]
        for mode in modes {
            if let frame = responsiveFrame(beside: finder, screen: screen, mode: mode, gap: gap) {
                return Layout(frame: frame, mode: mode)
            }
        }
        return nil
    }

    static func responsiveFrame(beside finder: CGRect, screen: CGRect, mode: Mode, gap: CGFloat = 12) -> CGRect? {
        guard gap.isFinite, gap >= 0, screen.height >= mode.minimumSize.height else { return nil }
        let height = min(mode.preferredSize.height, screen.height)
        // Right first, then left. Use the space that is actually available rather
        // than reserving the preferred width even when the content can be narrower.
        for availableWidth in [screen.maxX - finder.maxX - gap, finder.minX - screen.minX - gap] {
            let width = min(mode.preferredSize.width, availableWidth)
            guard width >= mode.minimumSize.width else { continue }
            if let frame = panelFrame(beside: finder, size: CGSize(width: width, height: height), screen: screen, gap: gap) {
                return frame
            }
        }
        return nil
    }

    /// A panel must fit beside Finder at its full size. Return nil when there is
    /// no room instead of covering Finder's contents or moving its window.
    static func panelFrame(beside finder: CGRect, size: CGSize, screen: CGRect, gap: CGFloat = 12) -> CGRect? {
        guard !finder.isEmpty, !finder.isInfinite, !screen.isEmpty, !screen.isInfinite,
              screen.intersects(finder), gap.isFinite, gap >= 0,
              size.width > 0, size.height > 0,
              size.width <= screen.width, size.height <= screen.height else { return nil }

        let y = min(max(finder.maxY - size.height, screen.minY), screen.maxY - size.height)
        for x in [finder.maxX + gap, finder.minX - gap - size.width] {
            let candidate = CGRect(origin: CGPoint(x: x, y: y), size: size)
            if screen.contains(candidate) && !finder.intersects(candidate) { return candidate }
        }
        return nil
    }

    /// Interpolate only on the same side, so a resize can never pass across Finder.
    static func canAnimateTransition(from start: CGRect, to end: CGRect, beside finder: CGRect, gap: CGFloat = 12) -> Bool {
        guard gap.isFinite, gap >= 0,
              [start, end, finder].allSatisfy({ !$0.isEmpty && !$0.isInfinite && !$0.isNull }) else { return false }
        return (start.minX >= finder.maxX + gap && end.minX >= finder.maxX + gap)
            || (start.maxX <= finder.minX - gap && end.maxX <= finder.minX - gap)
    }

    static func relativePath(of folder: URL, under root: URL) -> [String]? {
        let rootParts = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parts = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard parts.starts(with: rootParts) else { return nil }
        return Array(parts.dropFirst(rootParts.count))
    }
}
