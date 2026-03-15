import SwiftUI
import SharedDomain
import FoodleNetworking

@MainActor
final class OnboardingState: ObservableObject {
    @Published var serverURL = ""
    @Published var username = ""
    @Published var password = ""
    @Published var validatedSite: MoodleSite?
    @Published var errorMessage: String?
    @Published var showEmbeddedSSO = false
    @Published var embeddedAuthCoordinator: EmbeddedAuthCoordinator?
}
