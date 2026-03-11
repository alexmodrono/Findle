import Foundation
import FileProvider
import SharedDomain
import FoodleNetworking
import FoodlePersistence

/// Encapsulates a download operation's state for use across isolation boundaries.
/// Marked @unchecked Sendable because the completion handler is called exactly once
/// and the File Provider framework guarantees serial access per item.
final class DownloadContext: @unchecked Sendable {
    private let item: LocalItem
    private let database: Database
    private let completionHandler: (URL?, NSFileProviderItem?, Error?) -> Void
    private let progress: Progress

    init(
        item: LocalItem,
        database: Database,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void,
        progress: Progress
    ) {
        self.item = item
        self.database = database
        self.completionHandler = completionHandler
        self.progress = progress
    }

    func execute() async {
        do {
            let downloadedURL = try await FileDownloader.download(item: item)
            var updatedItem = item
            updatedItem.syncState = .materialized
            updatedItem.localPath = downloadedURL.path
            try database.updateItemSyncState(
                id: item.id,
                state: .materialized,
                localPath: downloadedURL.path
            )
            completionHandler(downloadedURL, FileProviderItem(localItem: updatedItem), nil)
            progress.completedUnitCount = 100
        } catch {
            completionHandler(nil, nil, error)
        }
    }
}
