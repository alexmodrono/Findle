// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import CoreServices
import Foundation
import OSLog

/// Watches the personal files folder and calls `onChange` when its contents change.
///
/// Bursts of events are coalesced. The callback fires once the folder has been quiet for
/// `quietPeriod`, and never later than `maxWait` after the first event of the burst, so a long
/// copy produces one callback at the end and a steady stream of writes still gets through.
///
/// Events are delivered on a private serial queue. Every mutable property is touched only on
/// that queue, which is what makes `@unchecked Sendable` sound here.
final class PersonalFilesWatcher: @unchecked Sendable {
    /// Staging files written by the reconciler are hidden and renamed into place when complete,
    /// so their events alone are not a change worth reconciling.
    private static let stagingPrefix = ".findle-staging-"
    private static let quietPeriod: Double = 1.5
    private static let maxWait: Double = 5.0

    private let rootURL: URL
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "es.amodrono.findle.personal-files-watcher", qos: .utility)
    /// Marks `queue` so `stop()` can tell when it is already running on it.
    private let queueKey = DispatchSpecificKey<Void>()
    private let logger = Logger(subsystem: "es.amodrono.findle", category: "PersonalFilesWatcher")

    // Confined to `queue`.
    private var stream: FSEventStreamRef?
    private var pendingCallback: DispatchWorkItem?
    private var firstPendingEvent: DispatchTime?

    init(rootURL: URL, onChange: @escaping @Sendable () -> Void) {
        self.rootURL = rootURL
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        stop()
    }

    /// Starts watching the root recursively. Calling it again restarts the stream.
    func start() {
        queue.sync {
            teardown()

            // The context holds an unretained pointer to self. `stop()` runs in deinit and
            // invalidates the stream before the object goes away, so the callback never sees a
            // dangling pointer.
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<PersonalFilesWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                watcher.handle(paths: paths)
            }

            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagUseCFTypes
            )
            guard let created = FSEventStreamCreate(
                nil,
                callback,
                &context,
                [rootURL.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                1.0,
                flags
            ) else {
                logger.error("Could not create personal files event stream")
                return
            }

            stream = created
            FSEventStreamSetDispatchQueue(created, queue)
            if !FSEventStreamStart(created) {
                logger.error("Could not start personal files event stream")
                teardown()
            }
        }
    }

    /// Stops watching and releases the stream. Safe to call when not started.
    func stop() {
        // The last reference can be dropped on `queue` itself (by a pending callback), and
        // `deinit` calls this. A `sync` onto the current queue would trap, so tear down directly.
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            teardown()
        } else {
            queue.sync {
                teardown()
            }
        }
    }

    /// Runs on `queue`, which the stream callback is delivered on.
    private func handle(paths: [String]) {
        let isRelevant = paths.contains {
            !URL(fileURLWithPath: $0).lastPathComponent.hasPrefix(Self.stagingPrefix)
        }
        guard isRelevant else { return }
        scheduleCallback()
    }

    /// Runs on `queue`. Restarts the quiet period, capped by `maxWait` from the burst's first event.
    private func scheduleCallback() {
        let now = DispatchTime.now()
        let burstStart = firstPendingEvent ?? now
        firstPendingEvent = burstStart
        let elapsed = Double(now.uptimeNanoseconds - burstStart.uptimeNanoseconds) / 1_000_000_000
        let delay = min(Self.quietPeriod, max(0, Self.maxWait - elapsed))

        pendingCallback?.cancel()
        let onChange = self.onChange
        let work = DispatchWorkItem { [weak self] in
            self?.pendingCallback = nil
            self?.firstPendingEvent = nil
            onChange()
        }
        pendingCallback = work
        queue.asyncAfter(deadline: now + delay, execute: work)
    }

    /// Runs on `queue`. Invalidation waits for any callback in progress and stops new ones.
    private func teardown() {
        pendingCallback?.cancel()
        pendingCallback = nil
        firstPendingEvent = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
