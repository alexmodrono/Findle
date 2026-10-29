import Foundation
import CryptoKit
import Darwin
import SharedDomain

/// Preserves legacy bytes that live outside the durable personal store before
/// the File Provider state directory can be removed. Archives are never reused.
public enum PersonalFileRecovery {
    public static func prepare(
        database: Database, store: PersonalFileStore, siteID: String, siteName: String, archiveRoot: URL,
        providerStateRoot: URL? = nil
    ) throws {
        try prepare(database: database, store: store, siteID: siteID, siteName: siteName,
                    archiveRoot: archiveRoot, providerStateRoot: providerStateRoot, operations: .live)
    }

    struct FileOperations: Sendable {
        var relocate: @Sendable (URL, URL) throws -> Void
        static let live = FileOperations(relocate: { source, destination in
            guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        })
    }

    static func prepare(
        database: Database, store: PersonalFileStore, siteID: String, siteName: String, archiveRoot: URL,
        providerStateRoot: URL?, operations: FileOperations
    ) throws {
        let rows = try database.fetchLocalItems(siteID: siteID).filter { $0.id.hasPrefix("local-") }
        let durableRoot = canonical(store.rootURL)
        if let providerStateRoot {
            let removedRoot = canonical(providerStateRoot)
            guard canonical(archiveRoot) != removedRoot, !canonical(archiveRoot).hasPrefix(removedRoot + "/"),
                  durableRoot != removedRoot, !durableRoot.hasPrefix(removedRoot + "/") else {
                throw FindleError.databaseError(detail: "The recovery folder must be outside the Finder state directory")
            }
        }
        let legacy = try rows.compactMap { row -> URL? in
            guard let path = row.localPath else {
                throw FindleError.databaseError(detail: "A personal file has no recovery path. Finder was not reset.")
            }
            let url = URL(fileURLWithPath: path)
            guard !canonical(url).hasPrefix(durableRoot + "/") else { return nil }
            return url
        }.sorted { $0.path.count < $1.path.count }
        if let providerStateRoot {
            let root = canonical(providerStateRoot)
            let legacyRoot = canonical(providerStateRoot.appendingPathComponent(".FindleState/LocalContent"))
            guard legacy.allSatisfy({ source in
                let path = canonical(source)
                return !path.hasPrefix(root + "/") || path == legacyRoot || path.hasPrefix(legacyRoot + "/")
            }) else {
                // Moving a single unexpected file leaves its parent available
                // for an editor to recreate it inside the removed domain.
                throw FindleError.databaseError(detail: "A personal file uses an unknown Finder storage folder. Reset was stopped to preserve the original.")
            }
        }
        var archived: [String] = []
        for source in legacy {
            let path = canonical(source)
            guard !archived.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
            let destination = archiveRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent(source.lastPathComponent)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = try fingerprint(source)
            try FileManager.default.copyItem(at: source, to: destination)
            guard try fingerprint(source) == original, try fingerprint(destination) == original else {
                throw FindleError.databaseError(detail: "Personal files changed while preparing recovery. Your originals were kept; try again.")
            }
            // Flush the verified archive before provider removal is allowed.
            try synchronizeTree(destination)
            archived.append(path)
        }
        _ = try PersonalFilesReconciler(store: store, database: database).reconcile(siteID: siteID, siteName: siteName)
        for row in try database.fetchLocalItems(siteID: siteID) where row.id.hasPrefix("local-") {
            guard let path = row.localPath,
                  canonical(URL(fileURLWithPath: path)).hasPrefix(durableRoot + "/"),
                  FileManager.default.fileExists(atPath: path) else {
                throw FindleError.databaseError(detail: "A personal file is not yet in its recovery folder. Finder was not reset; try again after the file is available.")
            }
        }
        if let providerStateRoot {
            // Copies do not protect a late write through an already-open file.
            // Move the original inode, including unindexed legacy children,
            // outside the removed domain. Cross-volume moves fail closed.
            let root = canonical(providerStateRoot)
            let legacyDirectory = providerStateRoot.appendingPathComponent(".FindleState/LocalContent", isDirectory: true)
            var originals = legacy.filter { canonical($0).hasPrefix(root + "/") }
            if FileManager.default.fileExists(atPath: legacyDirectory.path) { originals.append(legacyDirectory) }
            originals.sort { $0.path.count < $1.path.count }
            var relocated: [String] = []
            for source in originals {
                let path = canonical(source)
                guard !relocated.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
                let databasePath = canonical(URL(fileURLWithPath: database.filePath))
                guard databasePath != path, !databasePath.hasPrefix(path + "/") else {
                    throw FindleError.databaseError(detail: "A personal recovery path includes the active database. Finder was not reset.")
                }
                try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
                let destination = archiveRoot.appendingPathComponent("original-\(UUID().uuidString)-\(source.lastPathComponent)")
                try operations.relocate(source, destination)
                try synchronizeTree(destination)
                try synchronizeDirectory(archiveRoot)
                relocated.append(path)
            }
        }

    }

    private static func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    private static func fingerprint(_ url: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        func visit(_ entry: URL, relative: String) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: entry.path)
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory?:
                result[relative + "/"] = Data()
                for child in try FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil) {
                    try visit(child, relative: relative + "/" + child.lastPathComponent)
                }
            case .typeRegular?:
                let file = try FileHandle(forReadingFrom: entry)
                defer { try? file.close() }
                var digest = SHA256()
                while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data) }
                result[relative] = Data(digest.finalize())
            default:
                throw FindleError.databaseError(detail: "A personal recovery path could not be read safely. Finder was not reset.")
            }
        }
        try visit(url, relative: "")
        return result
    }

    private static func synchronizeTree(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if attributes[.type] as? FileAttributeType == .typeDirectory {
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try synchronizeTree(child)
            }
        }
        try synchronizeDirectory(url)
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
