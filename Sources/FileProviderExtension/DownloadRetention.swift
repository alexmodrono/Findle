// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import FileProvider
import SharedDomain
import FindlePersistence

/// Keep Downloaded and Remove Download, expressed through each item's content
/// policy. The system owns materialization in the replicated model, so Findle
/// only says which items must stay on disk and asks the system to evict.
enum DownloadRetention {
    static func contentPolicy(for item: LocalItem) -> NSFileProviderContentPolicy {
        item.isPinned ? .downloadEagerlyAndKeepDownloaded : .inherited
    }

    /// Part of the metadata version, so a pin change reaches the system as new metadata.
    static func metadataVersionSuffix(for item: LocalItem) -> String {
        item.isPinned ? "|kept" : ""
    }

    static func keep(_ ids: [String], database: Database) throws {
        for id in ids {
            try database.pinItemsRecursively(id: id, isPinned: true)
        }
    }

    /// Unpin, let the system see the lazier policy, then evict each synced file.
    ///
    /// Files are evicted one by one: evicting a folder stops at the first child
    /// that can't be evicted, and personal files never can. Eviction can briefly
    /// fail as non-evictable while the system still holds the old policy, so
    /// those failures are retried. Other failures (such as a file being open)
    /// don't stop the remaining files and the first one is rethrown at the end.
    static func remove(
        _ ids: [String],
        database: Database,
        signal: () async -> Void,
        evict: (String) async throws -> Void,
        retryDelay: Duration = .seconds(1),
        attempts: Int = 5
    ) async throws {
        for id in ids {
            try database.pinItemsRecursively(id: id, isPinned: false)
        }
        await signal()

        var seen = Set<String>()
        var firstFailure: Error?
        for id in ids {
            for file in try database.fetchSyncedFiles(underItemID: id) where seen.insert(file.id).inserted {
                do {
                    try await evictRetryingPolicyChange(file.id, evict: evict, retryDelay: retryDelay, attempts: attempts)
                    if file.syncState != .placeholder {
                        _ = try database.updateDownloadState(for: file, state: .placeholder)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    firstFailure = firstFailure ?? error
                }
            }
        }
        if let firstFailure { throw firstFailure }
    }

    private static func evictRetryingPolicyChange(
        _ id: String,
        evict: (String) async throws -> Void,
        retryDelay: Duration,
        attempts: Int
    ) async throws {
        var attempt = 1
        while true {
            do {
                try await evict(id)
                return
            } catch let error as NSFileProviderError where error.code == .nonEvictable && attempt < attempts {
                attempt += 1
                try await Task.sleep(for: retryDelay)
            }
        }
    }
}
