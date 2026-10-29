import Combine

/// Matches the setup screen's permission interface without querying or changing
/// Accessibility permissions, observing Finder, or opening System Settings.
@MainActor
final class FinderWindowObserver: ObservableObject {
    @Published private(set) var hasAccessibilityAccess = false

    func requestAccessibilityAccess() { hasAccessibilityAccess = true }
}
