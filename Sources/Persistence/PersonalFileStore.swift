// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import SharedDomain

/// Errors raised while resolving or writing the personal files folder.
public enum PersonalFileStoreError: Error, LocalizedError, Sendable {
    /// A `local-` directory row has no on-disk directory to hold its children.
    case missingLocalDirectory(itemID: String)
    /// A row in the parent chain of a Moodle directory is absent from the database.
    case missingParentRow(itemID: String)
    /// The parent chain of a Moodle directory loops back on itself.
    case cyclicParentChain(itemID: String)
    case incompleteScan(path: String)
    case invalidMarker(path: String)
    case extendedAttributeReadFailed(path: String, errno: Int32)
    /// `setxattr` failed for the given path.
    case extendedAttributeWriteFailed(path: String, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .missingLocalDirectory(let id):
            return "The folder for personal item \(id) is missing from disk."
        case .missingParentRow(let id):
            return "The database has no row for \(id), so its folder cannot be located."
        case .cyclicParentChain(let id):
            return "The parent chain of \(id) contains a cycle."
        case .incompleteScan(let path):
            return "Personal files changed or could not be read at \(path). Existing files were kept; try again."
        case .invalidMarker(let path):
            return "Findle could not read the folder marker at \(path). Existing files were kept."
        case .extendedAttributeReadFailed(let path, let code):
            return "Could not read the Findle item id on \(path) (errno \(code))."
        case .extendedAttributeWriteFailed(let path, let code):
            return "Could not store the Findle item id on \(path) (errno \(code))."
        }
    }
}

/// Owns the on-disk folder that holds the user's own files and folders.
///
/// The folder is a plain directory outside the File Provider domain, so the
/// files survive unsyncing a course, signing out, wiping the database, or
/// deleting the app. The database only caches what is found here.
///
/// Layout:
/// - `<root>/README.txt` explains the folder to the user.
/// - `<root>/<Site>/.findle-site.json` identifies the site directory.
/// - `<root>/<Site>/<Course>/.findle-anchor.json` marks a directory that mirrors
///   a Moodle directory. Directories without a marker are user folders.
/// - Each user file or folder carries the `es.amodrono.findle.item-id` extended
///   attribute with its `local-` item id, so ids survive a database rebuild.
public struct PersonalFileStore: Sendable {
    /// Default name of the folder under `~/Library/Application Support`.
    public static let defaultFolderName = "Findle Personal Files"
    /// Info.plist key that overrides the folder name for a build.
    public static let infoPlistFolderNameKey = "FindlePersonalFilesFolderName"

    /// Folder name from the running bundle's Info.plist, else `defaultFolderName`.
    public static var configuredFolderName: String {
        if let name = Bundle.main.object(forInfoDictionaryKey: infoPlistFolderNameKey) as? String,
           !name.isEmpty {
            return name
        }
        return defaultFolderName
    }

    /// `<real home>/Library/Application Support/<folderName>`.
    ///
    /// The real home directory comes from the password database because a
    /// sandboxed process gets a container path from `NSHomeDirectory()`, which
    /// is not where the user expects to find these files.
    public static func defaultRootURL(folderName: String = PersonalFileStore.configuredFolderName) -> URL {
        let home: String
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            home = String(cString: directory)
        } else {
            home = NSHomeDirectory()
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    public let rootURL: URL
    private let files: FileOperations

    public init(rootURL: URL) {
        self.init(rootURL: rootURL, files: FileOperations())
    }

    /// File-system boundaries are injectable so recovery is tested without
    /// changing permissions or exhausting space on a user's real volume.
    struct FileOperations: Sendable {
        var attributes: @Sendable (URL) throws -> [FileAttributeKey: Any] = {
            try FileManager.default.attributesOfItem(atPath: $0.path)
        }
        var children: @Sendable (URL) throws -> [URL] = {
            try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        }
        var readID: @Sendable (URL) throws -> String? = { try PersonalFileStore.readItemID(at: $0) }
        var writeID: @Sendable (String, URL) throws -> Void = { try PersonalFileStore.setItemID($0, at: $1) }
        var copy: @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
        var move: @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
        var removeEmptyDirectory: @Sendable (URL) throws -> Void = { url in
            guard url.path.withCString({ rmdir($0) }) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    init(rootURL: URL, files: FileOperations) {
        self.rootURL = rootURL
        self.files = files
    }

    func writeItemID(_ id: String, at url: URL) throws { try files.writeID(id, url) }
    func copyItem(at source: URL, to target: URL) throws { try files.copy(source, target) }
    func moveItem(at source: URL, to target: URL) throws { try files.move(source, target) }


    /// Marks a directory that mirrors a Moodle directory.
    public struct Anchor: Codable, Sendable, Equatable {
        public var itemID: String
        public var parentItemID: String?
        public var courseID: Int
        public var name: String

        public init(itemID: String, parentItemID: String?, courseID: Int, name: String) {
            self.itemID = itemID
            self.parentItemID = parentItemID
            self.courseID = courseID
            self.name = name
        }
    }

    /// One entry found by `scan(siteID:)`.
    public struct ScannedEntry: Sendable {
        public enum Kind: Sendable {
            case anchor(Anchor)
            case userFolder
            case userFile
        }

        public let url: URL
        public let kind: Kind
        /// The directory that contains this entry (the site directory for top-level entries).
        public let parentURL: URL
        /// The `es.amodrono.findle.item-id` attribute, for user entries only.
        public let storedItemID: String?
    }

    private static let itemIDAttribute = "es.amodrono.findle.item-id"
    private static let siteMarkerName = ".findle-site.json"
    private static let anchorMarkerName = ".findle-anchor.json"
    private static let readmeName = "README.txt"

    private static let readmeText = """
        Personal files added to Findle
        ==============================

        This folder holds files and folders you added yourself in Finder, inside \
        your Findle courses. Findle keeps them here so they are never lost.

        - They stay here even if a course is unsynced, you sign out of Moodle, \
        or you remove Findle.
        - The folder structure mirrors your courses. Each course, and each \
        section inside it, has its own folder.
        - You can open, copy, move, or back up these files like any other files.
        - Do not delete the hidden .findle-* files. Findle uses them to recognise \
        each folder. If you delete them, Findle may create new folders for your \
        courses the next time it runs.

        """

    private struct SiteMarker: Codable, Sendable, Equatable {
        var siteID: String
        var name: String
    }

    // MARK: - Directories

    /// Returns the directory for a Moodle site, creating the root, README, and site folder if needed.
    ///
    /// An existing subdirectory whose `.findle-site.json` carries `siteID` is reused, even if
    /// the site has been renamed. Otherwise `<root>/<sanitized siteName>` is created, with
    /// " 2", " 3", and so on appended if that name is taken.
    public func siteDirectory(siteID: String, siteName: String) throws -> URL {
        try ensureRoot()
        if let existing = try existingSiteDirectory(siteID: siteID) {
            let marker = try readJSON(SiteMarker.self, at: existing.appendingPathComponent(Self.siteMarkerName))
            if marker?.name != siteName {
                try writeJSON(SiteMarker(siteID: siteID, name: siteName),
                              to: existing.appendingPathComponent(Self.siteMarkerName))
            }
            return existing
        }
        let directory = try createUniqueDirectory(
            named: FileNameSanitizer.sanitize(siteName),
            in: rootURL
        )
        try writeJSON(SiteMarker(siteID: siteID, name: siteName),
                      to: directory.appendingPathComponent(Self.siteMarkerName))
        return directory
    }

    /// Returns the deepest directory of an anchor chain, creating any missing levels.
    ///
    /// `chain` runs from the course root anchor (`parentItemID == nil`) down to the target
    /// Moodle directory. Each level is matched by `itemID`, so a renamed Moodle directory keeps
    /// its folder and only its marker changes.
    public func anchorDirectory(chain: [Anchor], siteID: String, siteName: String) throws -> URL {
        var current = try siteDirectory(siteID: siteID, siteName: siteName)
        for anchor in chain {
            if let match = try findAnchorChild(of: current, itemID: anchor.itemID) {
                if match.anchor != anchor {
                    try writeJSON(anchor, to: match.url.appendingPathComponent(Self.anchorMarkerName))
                }
                current = match.url
            } else {
                let created = try createUniqueDirectory(
                    named: FileNameSanitizer.sanitize(anchor.name),
                    in: current
                )
                try writeJSON(anchor, to: created.appendingPathComponent(Self.anchorMarkerName))
                current = created
            }
        }
        return current
    }

    /// Resolves the directory that should hold the children of `parentID`.
    ///
    /// - `nil` resolves to the site directory.
    /// - A `local-` id resolves to that row's `localPath`, which must be an existing directory.
    /// - Any other id is a Moodle directory. Its anchor chain is built by walking database rows
    ///   up through `parentID`, and the chain is then passed to `anchorDirectory`.
    public func directory(
        forParentID parentID: String?,
        siteID: String,
        siteName: String,
        database: Database
    ) throws -> URL {
        guard let parentID else {
            return try siteDirectory(siteID: siteID, siteName: siteName)
        }

        if parentID.hasPrefix("local-") {
            guard let row = try database.fetchItem(id: parentID),
                  let path = row.localPath else {
                throw PersonalFileStoreError.missingLocalDirectory(itemID: parentID)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw PersonalFileStoreError.missingLocalDirectory(itemID: parentID)
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        var chain: [Anchor] = []
        var visited = Set<String>()
        var currentID: String? = parentID
        while let id = currentID {
            guard visited.insert(id).inserted else {
                throw PersonalFileStoreError.cyclicParentChain(itemID: parentID)
            }
            guard let row = try database.fetchItem(id: id) else {
                throw PersonalFileStoreError.missingParentRow(itemID: id)
            }
            chain.insert(Anchor(itemID: row.id, parentItemID: row.parentID, courseID: row.courseID, name: row.filename), at: 0)
            currentID = row.parentID
        }
        return try anchorDirectory(chain: chain, siteID: siteID, siteName: siteName)
    }

    /// Returns a URL in `directory` for `filename` that does not exist yet.
    ///
    /// "name.ext" becomes "name 2.ext", then "name 3.ext", and so on. Strings
    /// whose "extension" contains spaces (for example "Lecture 1.5 notes") are
    /// treated as having no extension.
    public func uniqueURL(for filename: String, in directory: URL) -> URL {
        let candidate = directory.appendingPathComponent(filename)
        if !Self.entryExists(at: candidate) {
            return candidate
        }
        let (stem, ext) = Self.splitExtension(filename)
        var number = 2
        while true {
            let name = Self.numberedName(stem: stem, ext: ext, number: number)
            let url = directory.appendingPathComponent(name)
            if !Self.entryExists(at: url) {
                return url
            }
            number += 1
        }
    }

    /// Name for a user file that would shadow a Moodle item: "<stem> (mine).<ext>".
    ///
    /// Names without a usable extension get " (mine)" appended instead, so "README"
    /// becomes "README (mine)" and "Lecture 1.5 notes" becomes "Lecture 1.5 notes (mine)".
    public static func mineFilename(for filename: String) -> String {
        let (stem, ext) = splitExtension(filename)
        return ext.isEmpty ? "\(filename) (mine)" : "\(stem) (mine).\(ext)"
    }

    /// Returns a hidden URL in `directory` for writing content before it is renamed into place.
    /// Scans skip dotfiles, so a half-written file is never imported.
    public func stagingURL(in directory: URL) -> URL {
        directory.appendingPathComponent(".findle-staging-\(UUID().uuidString)")
    }

    // MARK: - Extended attributes

    /// Returns the stored `local-` item id of `url`, or `nil` when the attribute is absent.
    public static func itemID(at url: URL) -> String? {
        try? readItemID(at: url)
    }

    private static func readItemID(at url: URL) throws -> String? {
        let size = url.path.withCString { getxattr($0, itemIDAttribute, nil, 0, 0, XATTR_NOFOLLOW) }
        if size < 0, errno == ENOATTR { return nil }
        guard size > 0 else {
            throw PersonalFileStoreError.extendedAttributeReadFailed(path: url.path, errno: errno)
        }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = url.path.withCString { path in
            buffer.withUnsafeMutableBytes { getxattr(path, itemIDAttribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        }
        guard read == size, let value = String(bytes: buffer, encoding: .utf8), value.hasPrefix("local-") else {
            throw PersonalFileStoreError.extendedAttributeReadFailed(path: url.path, errno: errno)
        }
        return value
    }

    /// Stores `id` as the item id attribute of `url`.
    public static func setItemID(_ id: String, at url: URL) throws {
        let path = url.path
        let bytes = Array(id.utf8)
        let result = path.withCString { pathPointer in
            bytes.withUnsafeBytes { buffer in
                setxattr(pathPointer, itemIDAttribute, buffer.baseAddress, buffer.count, 0, XATTR_NOFOLLOW)
            }
        }
        guard result == 0 else {
            throw PersonalFileStoreError.extendedAttributeWriteFailed(path: path, errno: errno)
        }
    }

    // MARK: - Scanning

    /// Walks the site directory and returns every entry, parents before children.
    ///
    /// Names starting with "." (including `.findle-*` markers and staging files) are skipped,
    /// as are symbolic links. Returns an empty array when the site directory does not exist.
    public func scan(siteID: String) throws -> [ScannedEntry] {
        try snapshot(siteID: siteID).entries
    }

    struct ScanSnapshot {
        let siteDirectory: URL?
        let entries: [ScannedEntry]
        let directories: [URL: DirectoryVersion]
    }

    struct DirectoryVersion: Equatable {
        let inode: UInt64
        let modified: Date
    }

    func snapshot(siteID: String) throws -> ScanSnapshot {
        guard let directory = try existingSiteDirectory(siteID: siteID) else {
            return ScanSnapshot(siteDirectory: nil, entries: [], directories: [:])
        }
        var entries: [ScannedEntry] = []
        var directories: [URL: DirectoryVersion] = [:]
        try scanChildren(of: directory, into: &entries, directories: &directories)
        var anchorIDs = Set<String>()
        for entry in entries {
            if case .anchor(let anchor) = entry.kind, !anchorIDs.insert(anchor.itemID).inserted {
                throw PersonalFileStoreError.invalidMarker(path: entry.url.path)
            }
        }
        let result = ScanSnapshot(siteDirectory: directory, entries: entries, directories: directories)
        try validate(result, siteID: siteID)
        return result
    }

    /// A changing or unavailable tree is never evidence that a personal file was deleted.
    func validate(_ snapshot: ScanSnapshot, siteID: String) throws {
        guard try existingSiteDirectory(siteID: siteID) == snapshot.siteDirectory else {
            throw PersonalFileStoreError.incompleteScan(path: rootURL.path)
        }
        for (directory, expected) in snapshot.directories {
            guard try directoryVersion(directory) == expected else {
                throw PersonalFileStoreError.incompleteScan(path: directory.path)
            }
        }
    }

    func isDefinitelyAbsent(_ url: URL) throws -> Bool { try attributesIfPresent(url) == nil }

    private func directoryVersion(_ url: URL) throws -> DirectoryVersion {
        let values = try files.attributes(url)
        guard values[.type] as? FileAttributeType == .typeDirectory,
              let inode = values[.systemFileNumber] as? UInt64,
              let date = values[.modificationDate] as? Date else {
            throw PersonalFileStoreError.incompleteScan(path: url.path)
        }
        return DirectoryVersion(inode: inode, modified: date)
    }

    // MARK: - Cleanup

    /// Removes anchor directories that contain nothing but their marker, bottom-up.
    /// The site directory itself is never removed.
    public func removeEmptyAnchorDirectories(siteID: String) throws {
        guard let siteDirectory = try existingSiteDirectory(siteID: siteID) else {
            return
        }
        try removeEmptyAnchors(in: siteDirectory)
    }

    // MARK: - Internal helpers

    /// Returns the existing site directory for `siteID`, or `nil` when there is none.
    /// Never creates anything.
    func existingSiteDirectory(siteID: String) throws -> URL? {
        guard try attributesIfPresent(rootURL) != nil else { return nil }
        var match: URL?
        for child in try visibleChildren(of: rootURL) where try files.attributes(child)[.type] as? FileAttributeType == .typeDirectory {
            let marker = try readJSON(SiteMarker.self, at: child.appendingPathComponent(Self.siteMarkerName))
            if marker?.siteID == siteID {
                guard match == nil else { throw PersonalFileStoreError.incompleteScan(path: rootURL.path) }
                match = child
            }
        }
        return match
    }

    private func ensureRoot() throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
        let readme = rootURL.appendingPathComponent(Self.readmeName)
        if !fileManager.fileExists(atPath: readme.path) {
            try Self.readmeText.write(to: readme, atomically: true, encoding: .utf8)
        }
    }

    /// Creates `<parent>/<base>`, or `<parent>/<base> N` for the first free N from 2.
    private func createUniqueDirectory(named base: String, in parent: URL) throws -> URL {
        var number = 1
        while true {
            let name = number == 1 ? base : Self.numberedName(stem: base, ext: "", number: number)
            let candidate = parent.appendingPathComponent(name, isDirectory: true)
            if candidate.path.withCString({ mkdir($0, 0o700) }) == 0 { return candidate }
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            number += 1
        }
    }

    func createUserDirectory(named name: String, in parent: URL) throws -> URL {
        try createUniqueDirectory(named: name, in: parent)
    }

    private func findAnchorChild(of directory: URL, itemID: String) throws -> (url: URL, anchor: Anchor)? {
        for child in try visibleChildren(of: directory) where try files.attributes(child)[.type] as? FileAttributeType == .typeDirectory {
            if let anchor = try readJSON(Anchor.self, at: child.appendingPathComponent(Self.anchorMarkerName)),
               anchor.itemID == itemID {
                return (child, anchor)
            }
        }
        return nil
    }

    private func scanChildren(of directory: URL, into result: inout [ScannedEntry], directories: inout [URL: DirectoryVersion]) throws {
        directories[directory] = try directoryVersion(directory)
        for child in try visibleChildren(of: directory) {
            switch try files.attributes(child)[.type] as? FileAttributeType {
            case .typeDirectory?:
                let markerURL = child.appendingPathComponent(Self.anchorMarkerName)
                if let anchor = try readJSON(Anchor.self, at: markerURL) {
                    guard !anchor.itemID.isEmpty, !anchor.itemID.hasPrefix("local-"),
                          anchor.parentItemID != anchor.itemID, anchor.courseID >= 0 else {
                        throw PersonalFileStoreError.invalidMarker(path: markerURL.path)
                    }
                    result.append(ScannedEntry(url: child, kind: .anchor(anchor), parentURL: directory, storedItemID: nil))
                } else {
                    result.append(ScannedEntry(url: child, kind: .userFolder, parentURL: directory, storedItemID: try files.readID(child)))
                }
                try scanChildren(of: child, into: &result, directories: &directories)
            case .typeRegular?:
                result.append(ScannedEntry(url: child, kind: .userFile, parentURL: directory, storedItemID: try files.readID(child)))
            case .typeSymbolicLink?:
                // Symlinks remain on disk and are not followed outside the personal store.
                continue
            default:
                throw PersonalFileStoreError.incompleteScan(path: child.path)
            }
        }
    }

    private func removeEmptyAnchors(in directory: URL) throws {
        for child in try visibleChildren(of: directory) where try files.attributes(child)[.type] as? FileAttributeType == .typeDirectory {
            try removeEmptyAnchors(in: child)
            let markerURL = child.appendingPathComponent(Self.anchorMarkerName)
            guard let marker = try readJSON(Anchor.self, at: markerURL) else { continue }
            let contents = try FileManager.default.contentsOfDirectory(atPath: child.path)
            guard contents == [Self.anchorMarkerName] else { continue }
            try FileManager.default.removeItem(at: markerURL)
            // rmdir refuses a newly populated directory, unlike removeItem which
            // recursively removes files arriving after the contents check.
            do { try files.removeEmptyDirectory(child) }
            catch {
                if try attributesIfPresent(markerURL) == nil {
                    try writeJSON(marker, to: markerURL)
                }
                if (error as? POSIXError)?.code != .ENOTEMPTY { throw error }
            }
        }
    }

    /// Non-hidden children of `directory`, sorted by name for deterministic scans.
    private func visibleChildren(of directory: URL) throws -> [URL] {
        try files.children(directory)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// True when anything exists at `url`, including a dangling symbolic link.
    private static func entryExists(at url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func splitExtension(_ filename: String) -> (stem: String, ext: String) {
        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        guard !ext.isEmpty, !stem.isEmpty, ext.rangeOfCharacter(from: .whitespaces) == nil else {
            return (filename, "")
        }
        return (stem, ext)
    }

    private static func numberedName(stem: String, ext: String, number: Int) -> String {
        ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
    }

    private func attributesIfPresent(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try files.attributes(url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        catch let error as POSIXError where error.code == .ENOENT { return nil }
    }

    private func readJSON<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        guard let attributes = try attributesIfPresent(url) else { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw PersonalFileStoreError.invalidMarker(path: url.path)
        }
        do { return try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
        catch { throw PersonalFileStoreError.invalidMarker(path: url.path) }
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}
