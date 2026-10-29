import Foundation
import FileProvider

enum HelperFileLocation {
    /// File Provider XPC does not guarantee cooperative cancellation. A bounded
    /// stream race lets the helper start its structural tools at the deadline
    /// even when the OS never answers. At most one startup probe can remain.
    static func resolve(
        timeout: Duration = .seconds(3),
        probe: @escaping @MainActor @Sendable () async -> URL?
    ) async -> URL? {
        let (stream, continuation) = AsyncStream<URL?>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let query = Task { @MainActor in
            guard !Task.isCancelled else { return }
            continuation.yield(await probe())
            continuation.finish()
        }
        let deadline = Task {
            do {
                try await Task.sleep(for: timeout)
                continuation.yield(nil)
                continuation.finish()
            } catch {}
        }
        defer {
            query.cancel()
            deadline.cancel()
            continuation.finish()
        }
        for await result in stream { return result }
        return nil
    }

    static func resolve(channel: HelperConfiguration.Channel, siteID: String) async -> URL? {
        await resolve {
            let domain = NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(channel.bundleIdentifier + ".domain." + siteID),
                displayName: siteID)
            return try? await NSFileProviderManager(for: domain)?.getUserVisibleURL(for: .rootContainer)
        }
    }
}
