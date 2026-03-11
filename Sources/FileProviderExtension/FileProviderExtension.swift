import FileProvider
import SharedDomain
import FoodleNetworking
import FoodlePersistence
import OSLog

/// The File Provider extension that exposes Moodle course content in Finder.
/// Uses the replicated extension model for modern macOS cloud-file behavior.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let logger = Logger(subsystem: "es.amodrono.foodle.file-provider", category: "Extension")
    private var database: Database?

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()

        do {
            self.database = try Database()
        } catch {
            logger.error("Failed to initialize database: \(error.localizedDescription, privacy: .public)")
        }

        logger.info("File Provider extension initialized for domain: \(domain.identifier.rawValue, privacy: .public)")
    }

    func invalidate() {
        logger.info("File Provider extension invalidated")
    }

    // MARK: - Item Lookup

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        logger.debug("Item requested: \(identifier.rawValue, privacy: .public)")

        let progress = Progress(totalUnitCount: 1)

        if identifier == .rootContainer {
            completionHandler(RootContainerItem(), nil)
            progress.completedUnitCount = 1
            return progress
        }

        guard let db = database,
              let localItem = try? db.fetchItem(id: identifier.rawValue) else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            progress.completedUnitCount = 1
            return progress
        }

        completionHandler(FileProviderItem(localItem: localItem), nil)
        progress.completedUnitCount = 1
        return progress
    }

    // MARK: - Enumeration

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        logger.debug("Enumerator requested for: \(containerItemIdentifier.rawValue, privacy: .public)")

        guard let db = database else {
            throw NSFileProviderError(.notAuthenticated)
        }

        if containerItemIdentifier == .workingSet {
            return WorkingSetEnumerator(database: db)
        }

        return ItemEnumerator(
            containerIdentifier: containerItemIdentifier,
            database: db
        )
    }

    // MARK: - Content Fetch (Download/Materialization)

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        logger.info("Fetch contents for: \(itemIdentifier.rawValue, privacy: .public)")

        let progress = Progress(totalUnitCount: 100)

        guard let db = database,
              let localItem = try? db.fetchItem(id: itemIdentifier.rawValue) else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        // If already materialized and local path exists, return it
        if localItem.syncState == .materialized, let localPath = localItem.localPath {
            let localURL = URL(fileURLWithPath: localPath)
            if FileManager.default.fileExists(atPath: localPath) {
                completionHandler(localURL, FileProviderItem(localItem: localItem), nil)
                progress.completedUnitCount = 100
                return progress
            }
        }

        // Perform the download asynchronously.
        let downloadContext = DownloadContext(
            item: localItem,
            database: db,
            completionHandler: completionHandler,
            progress: progress
        )
        Task.detached {
            await downloadContext.execute()
        }

        return progress
    }

    // Download logic moved to FileDownloader for Sendable compliance.

    // MARK: - Modification (Read-Only for now)

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        // Moodle content is read-only for now
        completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        return Progress()
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        return Progress()
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        return Progress()
    }
}
