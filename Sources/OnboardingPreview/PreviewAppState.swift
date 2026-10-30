import AuthenticationServices
import Combine
import Foundation
import FindleNetworking
import SharedDomain

/// A sample-only substitute compiled into the preview, never into Findle.
/// Keeping the production AppState out of this target prevents the shared setup
/// screens from opening account storage, Keychain, sync, or File Provider domains.
@MainActor
final class AppState: ObservableObject {
    enum AppScreen { case onboarding, workspace }
    enum SyncStatus: Equatable { case idle, syncing, completed, error(String) }

    static let sampleSite = MoodleSite(
        id: "onboarding-preview", displayName: "Sample University",
        baseURL: URL(string: "https://moodle.example.edu")!
    )

    let currentScreen: AppScreen = .onboarding
    let currentSite: MoodleSite? = AppState.sampleSite
    @Published var courses: [MoodleCourse] = []
    private(set) var subscriptionRevisions: [Int: UUID] = [:]
    @Published private(set) var syncStatus: SyncStatus = .idle
    var errorMessage: String?
    private(set) var isSignedIn = false

    func validateSite(urlString: String) async throws -> MoodleSite {
        try Task.checkCancellation()
        let address = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["https://moodle.example.edu", "https://moodle.example.edu/", "moodle.example.edu"].contains(address) else {
            throw PreviewError.sampleSiteOnly
        }
        return Self.sampleSite
    }

    func signInAndPersist(site: MoodleSite, username: String, password: String) async throws {
        try Task.checkCancellation()
        guard site == Self.sampleSite else { throw PreviewError.sampleSiteOnly }
        guard username == "student", password == "preview" else { throw PreviewError.sampleCredentialsOnly }
        // Deliberately do not retain either field or create an auth token.
        isSignedIn = true
    }

    func signInWithBrowserSSOAndPersist(site: MoodleSite,
                                      presentationContext: ASWebAuthenticationPresentationContextProviding) async throws {
        throw PreviewError.ssoUnavailable
    }

    func persistSignIn(site: MoodleSite, token: AuthToken) async throws {
        throw PreviewError.ssoUnavailable
    }

    func signInAndPersist(site: MoodleSite, tokenProvider: @escaping @MainActor () async throws -> AuthToken) async throws {
        // Never execute a real embedded-login provider in the disposable preview.
        throw PreviewError.ssoUnavailable
    }

    func activateAfterOnboarding() {}

    func loadCourses() async {
        guard isSignedIn, !Task.isCancelled, courses.isEmpty else { return }
        courses = [
            MoodleCourse(id: 1, shortName: "OS", fullName: "Operating Systems", siteID: Self.sampleSite.id),
            MoodleCourse(id: 2, shortName: "DS", fullName: "Digital Systems", siteID: Self.sampleSite.id),
            MoodleCourse(id: 3, shortName: "CALC", fullName: "Calculus", siteID: Self.sampleSite.id, isSyncEnabled: false)
        ]
    }

    func setCourseSyncEnabled(_ enabled: Bool, for course: MoodleCourse) {
        guard let index = courses.firstIndex(where: { $0.id == course.id && $0.siteID == course.siteID }) else { return }
        subscriptionRevisions[course.id] = UUID()
        courses[index].isSyncEnabled = enabled
    }

    func syncAll() async {
        guard isSignedIn, !Task.isCancelled else { return }
        syncStatus = .syncing
        do { try await Task.sleep(for: .milliseconds(400)) }
        catch { syncStatus = .idle; return }
        syncStatus = .completed
    }

    func syncCourse(_ course: MoodleCourse) async -> Bool { false }
}

private enum PreviewError: LocalizedError {
    case sampleSiteOnly, sampleCredentialsOnly, ssoUnavailable

    var errorDescription: String? {
        switch self {
        case .sampleSiteOnly: "Use moodle.example.edu in this preview."
        case .sampleCredentialsOnly: "Use student as the username and preview as the password."
        case .ssoUnavailable: "Institutional sign-in is unavailable in this preview."
        }
    }
}
