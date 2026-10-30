import Airlock

@MainActor
enum FindleOnboarding {
    static func make(state: AppState, observer: FinderWindowObserver, playsIntro: Bool = true, autosavesFrame: Bool = true,
                     onComplete: @escaping @MainActor () -> Void) -> AirlockWindowController {
        let session = SetupSession(state: state)
        let navigator = AirlockNavigator(appName: "Findle") {
            AirlockStep(id: "welcome", title: "Welcome") { WelcomeSetupController(state: state, session: session) }.showsHeading(false)
            AirlockStep(id: "server", title: "Site") { ServerSetupController(state: state, session: session) }.showsHeading(false)
            AirlockStep(id: "signin", title: "Sign In") { SignInSetupController(state: state, session: session) }.showsHeading(false)
            AirlockStep(id: "courses", title: "Courses") { CoursesSetupController(state: state, session: session) }.showsHeading(false).allowsGoingBack(false)
            AirlockStep(id: "finder", title: "Finder") { FinderSetupController(state: state, session: session, observer: observer) }.showsHeading(false)
            AirlockStep(id: "sync", title: "Sync") { SyncSetupController(state: state, session: session) }.showsHeading(false)
        }
        navigator.onComplete = onComplete
        return AirlockWindowController(navigator: navigator, playsIntro: playsIntro, playsSound: playsIntro, autosavesFrame: autosavesFrame)
    }
}
