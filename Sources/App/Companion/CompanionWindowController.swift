import AppKit
import Combine
import FileProvider
import OSLog
import SharedDomain

@MainActor
final class CompanionWindowController: NSWindowController {
    let observer = FinderWindowObserver()
    private let state: AppState
    private let content: CompanionViewController
    private var subscriptions = Set<AnyCancellable>()
    private var rootURL: URL?
    private var rootSiteID: String?
    private var resolvingRoot: Task<Void, Never>?
    private var refresh: Task<Void, Never>?
    private var visibilityGeneration = UUID()
    private var isShowing = false
    private var isRunning = false
    private var companionEnabled = UserDefaults.standard.object(forKey: "finderCompanionEnabled") as? Bool != false
    private let frameAnimator = CompanionFrameAnimator()
    private var pendingModeAnimation = false
    private var preferredMode: FinderPanelPlacement.Mode = UserDefaults.standard.bool(forKey: "finderCompanionCollapsed") ? .compact : .expanded
    private let logger = Logger(subsystem: "com.amodrono.findle", category: "FinderCompanion")
    private var lastDiagnostic: String?
    /// The folder last recorded as opened, so each visit is recorded once.
    private var recordedFolder: URL?
    /// The File Provider identity of the folder Finder shows, looked up once per folder.
    private var resolvedFolder: (url: URL, siteID: String, identity: FolderIdentity)?
    private var resolvingFolder: URL?
    private var resolvingFolderTask: Task<Void, Never>?
    /// The same for the single item selected in Finder.
    private var resolvedSelection: (url: URL, identity: FolderIdentity)?
    private var resolvingSelection: URL?
    private var resolvingSelectionTask: Task<Void, Never>?

    enum FolderIdentity: Sendable, Equatable {
        case root
        case item(String)
        /// Not an item of the domain, or the system couldn't say.
        case unknown
    }

    init(state: AppState, openSettings: @escaping @MainActor () -> Void) {
        self.state = state
        content = CompanionViewController(state: state, openSettings: openSettings)
        content.setMode(preferredMode)
        let panel = CompanionPanel(contentRect: NSRect(origin: .zero, size: preferredMode.preferredSize),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary, .moveToActiveSpace]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentViewController = content
        panel.setContentSize(preferredMode.preferredSize)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        content.onToggleMode = { [weak self] in
            guard let self else { return }
            self.preferredMode = self.content.mode == .compact ? .expanded : .compact
            self.pendingModeAnimation = CompanionMotion.isPointerInteraction
            UserDefaults.standard.set(self.preferredMode == .compact, forKey: "finderCompanionCollapsed")
            self.scheduleRefresh()
        }
        observer.$snapshot.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        state.objectWillChange.sink { [weak self] in self?.scheduleRefresh() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: UserDefaults.standard)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let enabled = UserDefaults.standard.object(forKey: "finderCompanionEnabled") as? Bool != false
                guard self.companionEnabled != enabled else { return }
                self.companionEnabled = enabled
                self.scheduleRefresh()
            }.store(in: &subscriptions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func start() { isRunning = true; scheduleRefresh() }

    func stop() {
        isRunning = false
        refresh?.cancel()
        refresh = nil
        resolvingRoot?.cancel()
        resolvingRoot = nil
        resolvingFolderTask?.cancel()
        resolvingFolderTask = nil
        resolvingFolder = nil
        resolvedFolder = nil
        resolvingSelectionTask?.cancel()
        resolvingSelectionTask = nil
        resolvingSelection = nil
        resolvedSelection = nil
        rootURL = nil
        rootSiteID = nil
        observer.locationRootURL = nil
        observer.locationNames = []
        observer.stop()
        hide()
    }

    private func scheduleRefresh() {
        guard isRunning else { return }
        refresh?.cancel()
        refresh = Task { [weak self] in
            guard !Task.isCancelled else { return }
            self?.update()
        }
    }

    private func update() {
        guard isRunning else { return }
        defer { pendingModeAnimation = false }
        if state.currentScreen != .workspace {
            rootURL = nil
            rootSiteID = nil
            observer.locationRootURL = nil
            observer.locationNames = []
            resolvingRoot?.cancel()
            resolvingRoot = nil
        }
        guard state.currentScreen == .workspace, companionEnabled else {
            diagnose("Companion is disabled or setup is incomplete")
            observer.stop()
            rootURL = nil
            rootSiteID = nil
            observer.locationRootURL = nil
            observer.locationNames = []
            resolvingRoot?.cancel()
            resolvingRoot = nil
            hide(); return
        }
        observer.start()
        let siteID = state.currentSite?.id
        if rootSiteID != siteID || rootURL == nil {
            diagnose("Resolving the Findle location")
            hide()
            guard resolvingRoot == nil else { return }
            let state = self.state
            resolvingRoot = Task { [weak self] in
                let root = await state.companionRootURL()
                guard let self, self.isRunning, !Task.isCancelled else { return }
                self.diagnose(root == nil ? "Findle location could not be resolved" : "Findle location resolved")
                if self.state.currentSite?.id == siteID {
                    self.rootURL = root
                    self.rootSiteID = siteID
                    self.observer.locationRootURL = root
                    self.observer.locationNames = [BundleIdentifiers.appDisplayName, self.state.currentSite?.displayName ?? ""]
                }
                self.resolvingRoot = nil
                if root != nil { self.update() }
            }
            return
        }
        guard let snapshot = observer.snapshot, snapshot.settled,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else {
            diagnose("Waiting for settled Finder context")
            hide(); return
        }
        guard let rootURL, let parts = FinderPanelPlacement.relativePath(of: snapshot.folderURL, under: rootURL) else {
            diagnose("Finder folder is outside the Findle location")
            hide(); return
        }
        // The folder's File Provider identity names its course even after a
        // rename; its name stands in only until the system answers.
        let identity = siteID.flatMap { identity(of: snapshot.folderURL, siteID: $0) }
        var location: CompanionLocation?
        if case .item(let id)? = identity, let siteID { location = state.companionLocation(itemID: id, siteID: siteID) }
        let course: MoodleCourse?
        if let location {
            course = location.course
        } else if identity == .root {
            course = nil
        } else {
            course = parts.first.flatMap { name in
                FinderFolderResolver.course(folderName: name, siteID: siteID, in: state.courses)
            }
        }
        // Unknown subfolders must not inherit context from the previously visited course.
        guard parts.isEmpty || course != nil else {
            diagnose("Finder folder does not match a course")
            hide(); return
        }
        guard let window else { return }
        let screen = NSScreen.screens.max { left, right in
            let l = left.frame.intersection(snapshot.frame), r = right.frame.intersection(snapshot.frame)
            return l.width * l.height < r.width * r.height
        } ?? NSScreen.main
        guard let screen else { hide(); return }
        guard let layout = FinderPanelPlacement.layout(beside: snapshot.frame, screen: screen.visibleFrame, preferredMode: preferredMode) else {
            diagnose("No room beside Finder; companion hidden. Finder: \(snapshot.frame), usable display: \(screen.visibleFrame)")
            hide()
            return
        }
        let frame = layout.frame
        let canExpand = FinderPanelPlacement.responsiveFrame(beside: snapshot.frame, screen: screen.visibleFrame, mode: .expanded) != nil
        let animate = pendingModeAnimation && isShowing && content.mode != layout.mode
            && FinderPanelPlacement.canAnimateTransition(from: window.frame, to: frame, beside: snapshot.frame)
        content.setMode(layout.mode, canExpand: canExpand, attachedOnRight: frame.minX >= snapshot.frame.maxX,
                        width: frame.width, animated: animate)
        content.show(course: course, folderIDs: location?.folderIDs ?? [])
        content.showSelection(siteID.flatMap { selection(in: snapshot, siteID: $0) })
        if let course, recordedFolder != snapshot.folderURL {
            recordedFolder = snapshot.folderURL
            if let folderID = location?.folderIDs.first, let siteID {
                state.recordItemOpened(id: folderID, siteID: siteID)
            } else {
                state.recordFolderOpened(course: course, subpath: Array(parts.dropFirst()))
            }
        }
        frameAnimator.setFrame(frame, of: window,
                               animated: animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        guard !isShowing else { return }
        diagnose("Showing the Finder companion. Finder: \(snapshot.frame), panel: \(frame), usable display: \(screen.visibleFrame)")
        visibilityGeneration = UUID()
        isShowing = true
        window.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
            window.animator().alphaValue = 1
        }
    }

    /// The identity of `folderURL`, or nil while the system looks it up.
    private func identity(of folderURL: URL, siteID: String) -> FolderIdentity? {
        if let resolvedFolder, resolvedFolder.url == folderURL, resolvedFolder.siteID == siteID {
            return resolvedFolder.identity
        }
        guard resolvingFolder != folderURL else { return nil }
        resolvingFolderTask?.cancel()
        resolvingFolder = folderURL
        let domainID = BundleIdentifiers.fileProviderDomainID(siteID: siteID)
        resolvingFolderTask = Task { [weak self] in
            let identity = await Self.lookUpIdentity(of: folderURL, domainID: domainID)
            guard let self, !Task.isCancelled, self.resolvingFolder == folderURL else { return }
            self.resolvingFolder = nil
            self.resolvedFolder = (folderURL, siteID, identity)
            if identity == .unknown { self.diagnose("Finder folder has no File Provider identity; matching by name") }
            self.scheduleRefresh()
        }
        return nil
    }

    /// The Findle item selected in Finder, when exactly one is. Nothing or
    /// several selected falls back to the course view.
    private func selection(in snapshot: FinderWindowObserver.Snapshot, siteID: String) -> CompanionSelection? {
        guard snapshot.selectionCount == 1, let url = snapshot.selectedURL else { return nil }
        if let resolvedSelection, resolvedSelection.url == url {
            guard case .item(let id) = resolvedSelection.identity else { return nil }
            return state.companionSelection(itemID: id, url: url)
        }
        guard resolvingSelection != url else { return nil }
        resolvingSelectionTask?.cancel()
        resolvingSelection = url
        let domainID = BundleIdentifiers.fileProviderDomainID(siteID: siteID)
        resolvingSelectionTask = Task { [weak self] in
            let identity = await Self.lookUpIdentity(of: url, domainID: domainID)
            guard let self, !Task.isCancelled, self.resolvingSelection == url else { return }
            self.resolvingSelection = nil
            self.resolvedSelection = (url, identity)
            self.scheduleRefresh()
        }
        return nil
    }

    // The system answers on a background queue, so this must not be main-actor isolated.
    private nonisolated static func lookUpIdentity(of url: URL, domainID: String) async -> FolderIdentity {
        await withCheckedContinuation { continuation in
            NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) { item, domain, _ in
                guard let item, domain?.rawValue == domainID else {
                    continuation.resume(returning: .unknown)
                    return
                }
                continuation.resume(returning: item == .rootContainer ? .root : .item(item.rawValue))
            }
        }
    }

    private func diagnose(_ message: String) {
        guard message != lastDiagnostic else { return }
        lastDiagnostic = message
        logger.info("\(message, privacy: .public)")
    }

    private func hide() {
        // Coming back to the same folder later is another visit.
        recordedFolder = nil
        guard let window, isShowing else { return }
        isShowing = false
        visibilityGeneration = UUID()
        let generation = visibilityGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.1
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibilityGeneration == generation else { return }
                self.window?.orderOut(nil)
            }
        }
    }
}
