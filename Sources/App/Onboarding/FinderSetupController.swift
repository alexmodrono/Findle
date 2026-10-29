import AppKit
import Combine

@MainActor
final class FinderSetupController: SetupStepController {
    private let observer: FinderWindowObserver
    private var subscription: AnyCancellable?

    init(state: AppState, session: SetupSession, observer: FinderWindowObserver) {
        self.observer = observer
        super.init(state: state, session: session)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func buildContent() {
        let context = SetupContextView(image: SetupAppearance.finderIcon,
                                       title: "Beside your Finder windows", detail: "Course information and shortcuts",
                                       imageSize: 80)
        addFullWidth(context)
        stack.setCustomSpacing(28, after: context)
        addFullWidth(NativeUI.label("Accessibility access lets Findle identify your current folder and window position.", size: 14))
        let access = ActionButton("Allow Finder Access…") { [weak self] _ in self?.observer.requestAccessibilityAccess() }
        access.controlSize = .large
        stack.addArrangedSubview(access)
        stack.addArrangedSubview(NativeUI.label("Optional for file sync.", secondary: true))
        subscription = observer.$hasAccessibilityAccess.sink { [weak self] granted in
            self?.message.stringValue = granted ? "Finder access is enabled." : ""
        }
    }
}
