import Foundation

@MainActor
struct CompanionActions {
    let toggleMode: () -> Void
    let sync: () -> Void
    let openMoodle: () -> Void
    let openSettings: () -> Void
    let openNode: (CompanionNode) -> Void
}
