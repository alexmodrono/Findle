#if DEBUG
import AppKit
import Airlock
import SharedDomain

/// Debug-only native rendering, with an in-memory database and no auth or Finder access.
@MainActor
final class InterfacePreview: NSObject, NSWindowDelegate {
    private let state: AppState
    private let mode: String
    private var controller: NSWindowController?
    private var task: Task<Void, Never>?
    private let frameAnimator = CompanionFrameAnimator()

    init(mode: String) throws { self.mode = mode; state = try AppState.interfacePreview(); super.init() }

    func run() {
        let observer = FinderWindowObserver()
        switch mode {
        case "onboarding":
            controller = FindleOnboarding.make(state: state, observer: observer, playsIntro: false, autosavesFrame: false) {}
        case "settings":
            controller = SettingsWindowController(state: state, updates: UpdateController(automaticallyStart: false), companion: observer, autosavesFrame: false, reconnect: {})
        default:
            if mode.contains("long"), let course = state.courses.first {
                state.courses[0] = MoodleCourse(id: course.id, shortName: "COMPUTER-SYSTEMS-2026",
                    fullName: "Operating Systems and Computer Architecture", siteID: course.siteID)
            }
            if mode.contains("error") {
                state.errorMessage = "Could not sync this course. Check your connection and try again."
            }
            if mode.contains("expired") { state.sessionExpired = true }
            if mode.contains("syncing"), let course = state.courses.first { state.courseSyncStates[course.id] = .syncing }
            let content = CompanionViewController(state: state, openSettings: {})
            let compact = mode.contains("compact")
            let panelMode: FinderPanelPlacement.Mode = compact ? .compact : .expanded
            var size = panelMode.preferredSize
            if mode.contains("narrow") { size.width = panelMode.minimumSize.width }
            if mode.contains("minimum") { size = panelMode.minimumSize }
            let attachedOnRight = !mode.contains("left")
            content.setMode(panelMode, attachedOnRight: attachedOnRight, width: size.width)
            content.show(course: mode.contains("root") ? nil : mode.contains("empty") ? state.courses.last : state.courses.first)
            let rect = NSRect(origin: CGPoint(x: 100, y: 100), size: size)
            // A standard test window lets UI tools exercise content controls even
            // when they cannot re-query a nonactivating panel. Default previews
            // still use the same panel class and focus policy as the real app.
            let window: NSWindow = mode.contains("interactive")
                ? NSWindow(contentRect: rect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
                : CompanionPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            (window as? NSPanel)?.becomesKeyOnlyIfNeeded = true
            window.title = "Findle Companion Preview"
            window.contentViewController = content
            window.setContentSize(size)
            let narrow = mode.contains("narrow")
            let minimum = mode.contains("minimum")
            content.onToggleMode = { [weak content, weak window, frameAnimator] in
                guard let content, let window else { return }
                let mode: FinderPanelPlacement.Mode = content.mode == .compact ? .expanded : .compact
                var size = mode.preferredSize
                if narrow { size.width = mode.minimumSize.width }
                if minimum { size = mode.minimumSize }
                let animate = CompanionMotion.isPointerInteraction
                content.setMode(mode, attachedOnRight: attachedOnRight, width: size.width, animated: animate)
                let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
                let x = attachedOnRight ? window.frame.minX : window.frame.maxX - frameSize.width
                let frame = NSRect(x: x, y: window.frame.maxY - frameSize.height,
                                   width: frameSize.width, height: frameSize.height)
                frameAnimator.setFrame(frame, of: window,
                                       animated: animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            }
            controller = NSWindowController(window: window)
        }
        controller?.window?.appearance = NSAppearance(named: mode.contains("dark") ? .darkAqua : .aqua)
        controller?.window?.delegate = self
        controller?.showWindow(nil)
        task = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(0.8)) } catch { return }
            guard let self, let window = self.controller?.window, let view = window.contentView else { return }
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { NSApp.terminate(nil); return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("findle-\(self.mode).png")
            do { try bitmap.representation(using: .png, properties: [:])?.write(to: url) }
            catch { print("Could not write preview: \(error)") }
            print("Native preview: \(url.path)")
            if !ProcessInfo.processInfo.arguments.contains("--stay-open") { NSApp.terminate(nil) }
        }
    }

    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}
#endif
