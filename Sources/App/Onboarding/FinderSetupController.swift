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
        addFullWidth(SetupStepHeader(title: "Finder companion",
                                    detail: "Keep course information and shortcuts beside your Finder windows."))
        let image = NSImageView(image: SetupAppearance.finderIcon)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.setAccessibilityElement(false)
        let title = NativeUI.label("Accessibility", size: 13, weight: .semibold)
        let detail = NativeUI.label("Lets Findle read the active folder and window position.", secondary: true, size: 13)
        let explanation = NativeUI.stack([title, detail], spacing: 3)
        let access = ActionButton("Allow…") { [weak self] _ in self?.observer.requestAccessibilityAccess() }
        access.setAccessibilityLabel("Allow Finder access")
        let allowed = NativeUI.label("Allowed", size: 13)
        allowed.textColor = .systemGreen
        let status = NativeUI.stack([access, allowed], spacing: 0, horizontal: true)
        let row = NativeUI.stack([image, explanation, status], spacing: 12, horizontal: true)
        addFullWidth(SetupFormGroup([row]))
        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: 32),
            image.heightAnchor.constraint(equalToConstant: 32),
            explanation.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -56 - 74),
            detail.widthAnchor.constraint(equalTo: explanation.widthAnchor),
            status.widthAnchor.constraint(equalToConstant: 74)
        ])
        addFullWidth(NativeUI.label("File sync works without this permission.", secondary: true, size: 12))
        subscription = observer.$hasAccessibilityAccess.sink { [weak access, weak allowed] granted in
            access?.isHidden = granted
            allowed?.isHidden = !granted
        }
    }
}
