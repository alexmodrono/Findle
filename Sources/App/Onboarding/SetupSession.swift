import SharedDomain

@MainActor
final class SetupSession {
    var serverURL: String
    var site: MoodleSite?
    var signedInSiteID: String?
    var username = ""
    var password = ""

    init(state: AppState) {
        serverURL = state.currentSite?.baseURL.absoluteString ?? ""
    }
}
