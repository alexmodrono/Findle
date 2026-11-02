import AppKit
import ApplicationServices
import Combine
import OSLog

@MainActor
final class FinderWindowObserver: ObservableObject {
    struct Snapshot: Equatable {
        let folderURL: URL
        let frame: CGRect
        let settled: Bool
        /// The item selected in the window when exactly one is, in a Findle folder.
        var selectedURL: URL?
        /// How many items are selected there.
        var selectionCount = 0
    }

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var hasAccessibilityAccess: Bool
    private(set) var isRunning = false
    var isPolling: Bool { timer != nil }
    private var timer: Timer?
    private var observations: [NSObjectProtocol] = []
    private let notificationCenter: NotificationCenter
    private let accessibilityTrusted: () -> Bool
    private let finderActive: () -> Bool
    private let windowSample: (() -> Snapshot?)?
    private let uptime: () -> TimeInterval
    private let makeTimer: (@escaping @MainActor () -> Void) -> Timer
    private var placement = FinderPanelPlacement()
    private var previousFolder: URL?
    private let logger = Logger(subsystem: "es.amodrono.findle", category: "FinderObserver")
    private var lastDiagnostic: String?
    var locationRootURL: URL?
    var locationNames = Set<String>()
    /// The selection is read at most this often, so following it costs Finder little.
    private static let selectionInterval: TimeInterval = 0.5
    private var lastSelection: (folder: URL, at: TimeInterval, url: URL?, count: Int)?

    init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        finderActive: @escaping () -> Bool = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" },
        windowSample: (() -> Snapshot?)? = nil,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        makeTimer: @escaping (@escaping @MainActor () -> Void) -> Timer = { sample in
            Timer(timeInterval: 0.12, repeats: true) { _ in MainActor.assumeIsolated { sample() } }
        }
    ) {
        self.notificationCenter = notificationCenter
        self.accessibilityTrusted = accessibilityTrusted
        self.finderActive = finderActive
        self.windowSample = windowSample
        self.uptime = uptime
        self.makeTimer = makeTimer
        hasAccessibilityAccess = accessibilityTrusted()
    }

    isolated deinit {
        timer?.invalidate()
        observations.forEach { notificationCenter.removeObserver($0) }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let center = notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observations.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applicationChanged() }
            })
        }
        applicationChanged()
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        observations.forEach { notificationCenter.removeObserver($0) }
        observations.removeAll()
        placement = FinderPanelPlacement()
        previousFolder = nil
        if snapshot != nil { snapshot = nil }
    }

    func requestAccessibilityAccess() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if !AXIsProcessTrusted(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        updateAccess()
        applicationChanged()
    }

    private func applicationChanged() {
        guard isRunning else { return }
        timer?.invalidate()
        timer = nil
        placement = FinderPanelPlacement()
        previousFolder = nil
        if snapshot != nil { snapshot = nil }
        updateAccess()
        guard finderActive(), hasAccessibilityAccess else {
            diagnose(hasAccessibilityAccess ? "Finder is not active" : "Accessibility access is unavailable")
            return
        }
        sample()
        guard hasAccessibilityAccess, finderActive() else { return }
        // AX move notifications arrive after a drag. Sample only the active Finder's
        // geometry so we can hide during the drag, without animating a follower.
        let timer = makeTimer { [weak self] in self?.sample() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateAccess() {
        let granted = accessibilityTrusted()
        if hasAccessibilityAccess != granted { hasAccessibilityAccess = granted }
    }

    private func sample() {
        guard isRunning else { return }
        updateAccess()
        guard hasAccessibilityAccess, finderActive() else {
            diagnose(hasAccessibilityAccess ? "Finder is not active" : "Accessibility access is unavailable")
            timer?.invalidate()
            timer = nil
            if snapshot != nil { snapshot = nil }
            return
        }
        let context: Snapshot?
        if let windowSample { context = windowSample() }
        else { context = sampleFinderWindow() }
        guard let context else {
            _ = placement.update(frame: nil, now: uptime())
            if snapshot != nil { snapshot = nil }
            return
        }
        if previousFolder != context.folderURL {
            placement = FinderPanelPlacement()
            previousFolder = context.folderURL
        }
        let visibility = placement.update(frame: context.frame, now: uptime())
        let candidate = Snapshot(folderURL: context.folderURL, frame: context.frame, settled: visibility == .visible,
                                 selectedURL: context.selectedURL, selectionCount: context.selectionCount)
        diagnose(candidate.settled ? "Finder folder and geometry are settled" : "Waiting for Finder geometry to settle")
        if snapshot != candidate { snapshot = candidate }
    }

    private func sampleFinderWindow() -> Snapshot? {
        guard let finder = NSWorkspace.shared.frontmostApplication,
              finder.bundleIdentifier == "com.apple.finder" else { return nil }
        let application = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.08)
        guard let windowValue = value(application, kAXFocusedWindowAttribute),
              CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
            diagnose("Finder has no accessible focused window")
            return nil
        }
        let window = windowValue as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.08)
        let folder = folderURL(of: window)
        guard
              (value(window, kAXMinimizedAttribute) as? Bool) != true,
              let url = folder,
              let position = value(window, kAXPositionAttribute),
              let size = value(window, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            diagnose("Finder window has no usable folder or geometry (folder present: \(folder != nil))")
            return nil
        }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        // Accessibility uses a top-left origin anchored to the primary display.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = CGRect(x: point.x, y: primaryTop - point.y - dimensions.height,
                           width: dimensions.width, height: dimensions.height)
        let selection = selection(in: window, folder: url)
        return Snapshot(folderURL: url, frame: frame, settled: false, selectedURL: selection.url, selectionCount: selection.count)
    }

    /// The selected items of a window showing a Findle folder, read within a
    /// small budget and reused for a moment so Finder isn't queried constantly.
    private func selection(in window: AXUIElement, folder: URL) -> (url: URL?, count: Int) {
        guard let root = locationRootURL?.standardizedFileURL,
              folder.standardizedFileURL.pathComponents.starts(with: root.pathComponents) else {
            lastSelection = nil
            return (nil, 0)
        }
        let now = uptime()
        if let lastSelection, lastSelection.folder == folder, now - lastSelection.at < Self.selectionInterval {
            return (lastSelection.url, lastSelection.count)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.03
        var budget = 80
        var url: URL?
        var count = 0
        if let content = contentView(in: window, depth: 0, budget: &budget, deadline: deadline) {
            var containers: [AXUIElement] = []
            collectSelectionContainers(in: content, depth: 0, budget: &budget, deadline: deadline, result: &containers)
            // Column view has a list per column; the rightmost selection is the user's.
            for container in containers.reversed() {
                let selected = value(container, kAXSelectedRowsAttribute) as? [AXUIElement]
                    ?? value(container, kAXSelectedChildrenAttribute) as? [AXUIElement] ?? []
                guard !selected.isEmpty else { continue }
                count = selected.count
                if count == 1 {
                    var found: [URL] = []
                    collectItemURLs(in: selected[0], depth: 0, budget: &budget, deadline: deadline, result: &found)
                    url = found.first
                }
                break
            }
        }
        lastSelection = (folder, now, url, count)
        return (url, count)
    }

    private func collectSelectionContainers(in element: AXUIElement, depth: Int, budget: inout Int,
                                            deadline: TimeInterval, result: inout [AXUIElement]) {
        guard budget > 0, depth < 6, ProcessInfo.processInfo.systemUptime < deadline else { return }
        budget -= 1
        AXUIElementSetMessagingTimeout(element, 0.02)
        let role = value(element, kAXRoleAttribute) as? String
        if [kAXOutlineRole, kAXTableRole, kAXListRole, kAXBrowserRole, "AXCollection", "AXGrid"].contains(role) {
            result.append(element)
            // A browser's columns are lists of their own.
            guard role == kAXBrowserRole else { return }
        }
        for child in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            collectSelectionContainers(in: child, depth: depth + 1, budget: &budget, deadline: deadline, result: &result)
        }
    }

    private func folderURL(of window: AXUIElement) -> URL? {
        if let url = FinderFolderResolver.fileURL(value(window, kAXDocumentAttribute)) { return url }
        if let url = FinderFolderResolver.fileURL(value(window, kAXURLAttribute)) { return url }
        if let proxy = value(window, kAXProxyAttribute), CFGetTypeID(proxy) == AXUIElementGetTypeID(),
           let url = FinderFolderResolver.fileURL(value(proxy as! AXUIElement, kAXURLAttribute)) { return url }

        guard let locationRootURL, let title = value(window, kAXTitleAttribute) as? String else { return nil }
        // Bound the fallback to the content view. Sidebar favorites and toolbar
        // items cannot establish which folder this window is displaying.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.04
        var budget = 100
        guard let content = contentView(in: window, depth: 0, budget: &budget, deadline: deadline) else { return nil }
        var urls: [URL] = []
        collectItemURLs(in: content, depth: 0, budget: &budget, deadline: deadline, result: &urls)
        return FinderFolderResolver.folderURL(windowTitle: title, itemURLs: urls, rootURL: locationRootURL,
                                               rootNames: locationNames,
                                               columnView: value(content, kAXIdentifierAttribute) as? String == "ColumnView")
    }

    private func contentView(in element: AXUIElement, depth: Int, budget: inout Int, deadline: TimeInterval) -> AXUIElement? {
        guard budget > 0, depth < 8, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        budget -= 1
        AXUIElementSetMessagingTimeout(element, 0.02)
        let identifier = value(element, kAXIdentifierAttribute) as? String
        if ["IconView", "ListView", "ColumnView", "GalleryView"].contains(identifier) { return element }
        let role = value(element, kAXRoleAttribute) as? String
        guard role != kAXOutlineRole, role != kAXToolbarRole else { return nil }
        for child in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let content = contentView(in: child, depth: depth + 1, budget: &budget, deadline: deadline) { return content }
        }
        return nil
    }

    private func collectItemURLs(in element: AXUIElement, depth: Int, budget: inout Int,
                                 deadline: TimeInterval, result: inout [URL]) {
        guard budget > 0, depth < 8, result.count < 24, ProcessInfo.processInfo.systemUptime < deadline else { return }
        budget -= 1
        AXUIElementSetMessagingTimeout(element, 0.02)
        if let url = FinderFolderResolver.fileURL(value(element, kAXURLAttribute)) {
            result.append(url)
            return
        }
        // Start with the rightmost column, which holds the current folder's items.
        for child in (value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).reversed() {
            collectItemURLs(in: child, depth: depth + 1, budget: &budget, deadline: deadline, result: &result)
        }
    }

    private func diagnose(_ message: String) {
        guard message != lastDiagnostic else { return }
        lastDiagnostic = message
        logger.info("\(message, privacy: .public)")
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }
}
