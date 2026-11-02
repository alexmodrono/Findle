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
    /// For rows of the outline, as Finder offers for its items.
    var item: CompanionItemActions
}

/// What the outline does with a row that stands for a Findle item.
@MainActor
struct CompanionItemActions {
    /// Resolves where the item is in Finder; dragging and previewing need it.
    let url: @Sendable (String) async -> URL?
    let quickLook: (String) -> Void
    let reveal: (String) -> Void
    let moodleURL: (String) -> URL?
    let keep: (String) -> Void
    let removeDownload: (String) -> Void
}
