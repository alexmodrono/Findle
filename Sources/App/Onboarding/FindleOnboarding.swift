import Airlock

@MainActor
enum FindleOnboarding {
    static func make(state: AppState, observer: FinderWindowObserver, playsIntro: Bool = true, autosavesFrame: Bool = true,
                     onComplete: @escaping @MainActor () -> Void) -> AirlockWindowController {
        let session = SetupSession(state: state)
        let navigator = AirlockNavigator(appName: "Findle") {
            AirlockStep(id: "server", title: "Moodle Site") { ServerSetupController(state: state, session: session) }
            AirlockStep(id: "signin", title: "Sign In") { SignInSetupController(state: state, session: session) }
            AirlockStep(id: "courses", title: "Courses") { CoursesSetupController(state: state, session: session) }.allowsGoingBack(false)
            AirlockStep(id: "finder", title: "Finder") { FinderSetupController(state: state, session: session, observer: observer) }
            AirlockStep(id: "sync", title: "First Sync") { SyncSetupController(state: state, session: session) }
        }
        navigator.onComplete = onComplete
        return AirlockWindowController(navigator: navigator, playsIntro: playsIntro, playsSound: playsIntro, autosavesFrame: autosavesFrame)
    }
}
