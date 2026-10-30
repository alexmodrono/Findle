import AppKit
import Airlock
import FindleNetworking
import SharedDomain
import Testing

@Suite(.serialized)
@MainActor
struct OnboardingPreviewTests {
    @Test func literalInputDisablesProseCheckingBeforeFieldEditorResigns() throws {
        _ = NSApplication.shared
        let state = AppState()
        let session = SetupSession(state: state)
        session.serverURL = "https://moodle.example.edu"
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let server = ServerSetupController(state: state, session: session)
        window.contentViewController = server
        _ = server.view
        server.prepareForPresentation()
        let address = try #require(descendants(of: server.view, as: NSTextField.self)
            .first { $0.placeholderString == "https://moodle.example.edu" })
        let editor = try #require(address.currentEditor() as? NSTextView)
        #expect(!editor.isAutomaticDataDetectionEnabled)
        #expect(!editor.isContinuousSpellCheckingEnabled)
        #expect(!editor.isAutomaticSpellingCorrectionEnabled)
        #expect(!editor.isAutomaticTextReplacementEnabled)
        #expect(address.accessibilityLabel() == "Moodle site address")
        #expect(address.stringValue == "https://moodle.example.edu")
        // Exercise the actual responder teardown reported in the QoS warning.
        address.removeFromSuperview()

        session.site = AppState.sampleSite
        let signIn = SignInSetupController(state: state, session: session)
        window.contentViewController = signIn
        _ = signIn.view
        signIn.prepareForPresentation()
        let username = try #require(descendants(of: signIn.view, as: NSTextField.self)
            .first { $0.placeholderString == "Username" })
        let usernameEditor = try #require(username.currentEditor() as? NSTextView)
        #expect(!usernameEditor.isAutomaticDataDetectionEnabled)
        #expect(!usernameEditor.isContinuousSpellCheckingEnabled)
        let password = try #require(descendants(of: signIn.view, as: NSSecureTextField.self).first)
        #expect(password.accessibilityLabel() == "Moodle password")
        #expect((password.cell as? NSSecureTextFieldCell)?.echosBullets == true)
        username.removeFromSuperview()
    }

    @Test func previewRejectsRealSitesAndCredentials() async throws {
        let state = AppState()
        await #expect(throws: (any Error).self) {
            _ = try await state.validateSite(urlString: "https://university.example.org")
        }
        let site = try await state.validateSite(urlString: " moodle.example.edu ")
        #expect(!site.capabilities.requiresSSO)
        await #expect(throws: (any Error).self) {
            try await state.signInAndPersist(site: site, username: "real-user", password: "not-a-sample")
        }
        #expect(!state.isSignedIn)
        await #expect(throws: (any Error).self) {
            try await state.persistSignIn(site: site, token: AuthToken(token: "unused"))
        }
        var providerRan = false
        await #expect(throws: (any Error).self) {
            try await state.signInAndPersist(site: site) {
                providerRan = true
                return AuthToken(token: "unused")
            }
        }
        #expect(!providerRan)
        #expect(!state.isSignedIn)
    }

    @Test func courseChoicesStayInThisPreviewOnly() async throws {
        let state = try await signedInState()
        await state.loadCourses()
        let course = try #require(state.courses.first)
        state.setCourseSyncEnabled(false, for: course)
        await state.loadCourses()
        #expect(state.courses.first?.isSyncEnabled == false)
        let otherSession = try await signedInState()
        await otherSession.loadCourses()
        #expect(otherSession.courses.first?.isSyncEnabled == true)
    }

    @Test func finderAccessIsLocalToEachPreview() {
        let observer = FinderWindowObserver()
        #expect(!observer.hasAccessibilityAccess)
        observer.requestAccessibilityAccess()
        #expect(observer.hasAccessibilityAccess)
        #expect(!FinderWindowObserver().hasAccessibilityAccess)
    }

    @Test func cancellingSyncDoesNotFinishIt() async throws {
        let state = try await signedInState()
        let sync = Task { await state.syncAll() }
        try await waitUntil { state.syncStatus == .syncing }
        sync.cancel()
        await sync.value
        #expect(state.syncStatus == .idle)
    }

    @Test(arguments: ["sync", "skip", "empty"])
    func sharedOnboardingCompletes(mode: String) async throws {
        _ = NSApplication.shared
        let state = AppState()
        let observer = FinderWindowObserver()
        var completions = 0
        let window = FindleOnboarding.make(state: state, observer: observer,
                                          playsIntro: false, autosavesFrame: false) { completions += 1 }
        defer { window.close() }
        let flow = try #require(window.window?.contentViewController)
        _ = flow.view
        flow.viewDidAppear()
        let navigator = window.navigator
        try await waitUntil { navigator.canContinue }
        #expect(flow.children.first is WelcomeSetupController)
        navigator.goToNext()
        try await waitUntil { flow.children.first is ServerSetupController && navigator.canContinue }
        #expect(navigator.buttonLabel == "Connect")
        navigator.goToNext()
        try await waitUntil { !navigator.isBusy }
        #expect(navigator.currentIndex == 1)
        navigator.goToNext()
        try await waitUntil { flow.children.first is SignInSetupController }
        #expect(!navigator.canContinue)

        // Back navigation keeps the validated site and restores Continue.
        navigator.goToPrevious()
        try await waitUntil { flow.children.first is ServerSetupController && navigator.canContinue }
        #expect(navigator.buttonLabel == nil)
        navigator.goToNext()
        try await waitUntil { flow.children.first is SignInSetupController }
        let signIn = try #require(flow.children.first as? SignInSetupController)
        let username = try #require(descendants(of: signIn.view, as: NSTextField.self)
            .first { $0.placeholderString == "Username" })
        let password = try #require(descendants(of: signIn.view, as: NSSecureTextField.self).first)
        username.stringValue = "student"
        password.stringValue = "preview"
        signIn.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        navigator.goToNext()
        try await waitUntil { !navigator.isBusy }
        #expect(state.isSignedIn)
        #expect(password.stringValue.isEmpty)

        navigator.goToNext()
        try await waitUntil { flow.children.first is CoursesSetupController && navigator.canContinue }
        #expect(state.courses.count == 3)
        #expect(!navigator.canGoBack)
        if mode == "empty" {
            for course in state.courses { state.setCourseSyncEnabled(false, for: course) }
        }
        navigator.goToNext()
        try await waitUntil { flow.children.first is FinderSetupController && navigator.canContinue }
        let finder = try #require(flow.children.first as? FinderSetupController)
        let access = try #require(descendants(of: finder.view, as: ActionButton.self).first)
        access.performClick(nil)
        #expect(observer.hasAccessibilityAccess)
        #expect(access.isHidden)
        #expect(descendants(of: finder.view, as: NSTextField.self).contains { $0.stringValue == "Allowed" && !$0.isHidden })
        navigator.goToNext()
        try await waitUntil { flow.children.first is SyncSetupController && navigator.canContinue }
        let sync = try #require(flow.children.first as? SyncSetupController)
        let skip = try #require(sync.stack.arrangedSubviews.compactMap { $0 as? ActionButton }.first)
        #expect(skip.isHidden == (mode == "empty"))
        if mode == "sync" {
            navigator.goToNext()
            try await waitUntil { !navigator.isBusy }
            #expect(state.syncStatus == .completed)
        } else if mode == "skip" {
            skip.performClick(nil)
        }
        #expect(skip.isHidden)
        #expect(navigator.buttonLabel == "Finish")
        navigator.goToNext()
        navigator.goToNext()
        #expect(completions == 1)
        if mode != "sync" { #expect(state.syncStatus == .idle) }
    }

    private func signedInState() async throws -> AppState {
        let state = AppState()
        try await state.signInAndPersist(site: AppState.sampleSite, username: "student", password: "preview")
        return state
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { child in
            (child as? T).map { [$0] } ?? []
        } + view.subviews.flatMap { descendants(of: $0, as: type) }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Onboarding did not reach the expected state")
                throw WaitError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private enum WaitError: Error { case timedOut }
}
