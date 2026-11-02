import Foundation

@MainActor
struct CompanionActions {
    let toggleMode: () -> Void
    let sync: () -> Void
    let openMoodle: () -> Void
    let openSettings: () -> Void
    let openNode: (CompanionNode) -> Void
    /// For the item selected in Finder.
    let openSelectionInMoodle: (CompanionSelection) -> Void
    let keepSelection: (CompanionSelection) -> Void
    let removeSelectionDownload: (CompanionSelection) -> Void
}
