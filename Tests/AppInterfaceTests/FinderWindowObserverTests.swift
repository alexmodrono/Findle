import AppKit
import Combine
import Testing
import Darwin

@Suite(.serialized)
@MainActor
struct FinderWindowObserverTests {
    @Test func startIsIdempotentAndStopRejectsQueuedSignals() {
        let runtime = FinderObserverFixture()
        let observer = runtime.observer()
        observer.start()
        observer.start()
        #expect(runtime.samples == 1)
        #expect(runtime.timerCreations == 1)
        #expect(observer.isRunning && observer.isPolling)
        observer.stop()
        #expect(!observer.isRunning && !observer.isPolling)
        #expect(runtime.timer?.isValid == false)
        runtime.notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        runtime.timer?.fire()
        #expect(runtime.samples == 1)
        #expect(observer.snapshot == nil)
    }

    @Test func deniedAndRevokedPermissionStopsSamplingWithoutPrompting() {
        let runtime = FinderObserverFixture()
        runtime.trusted = false
        let observer = runtime.observer()
        observer.start()
        #expect(!observer.hasAccessibilityAccess && !observer.isPolling)
        #expect(runtime.samples == 0 && runtime.timerCreations == 0)
        runtime.trusted = true
        runtime.notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        #expect(observer.hasAccessibilityAccess && observer.isPolling)
        #expect(runtime.samples == 1)
        runtime.trusted = false
        runtime.timer?.fire()
        #expect(!observer.hasAccessibilityAccess && !observer.isPolling)
        #expect(observer.snapshot == nil)
        #expect(runtime.samples == 1)
        observer.stop()
    }

    @Test func inactiveFinderDoesNotPollAndActivationRestartsOnce() {
        let runtime = FinderObserverFixture()
        runtime.active = false
        let observer = runtime.observer()
        observer.start()
        #expect(!observer.isPolling && runtime.samples == 0)
        runtime.active = true
        runtime.notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        #expect(observer.isPolling && runtime.samples == 1)
        runtime.active = false
        runtime.timer?.fire()
        #expect(!observer.isPolling && observer.snapshot == nil)
        observer.stop()
    }

    @Test func stableSamplesPublishOnceAndMissingContextClearsAttachment() {
        let runtime = FinderObserverFixture()
        let observer = runtime.observer()
        var publications = 0
        let subscription = observer.$snapshot.dropFirst().sink { _ in publications += 1 }
        observer.start()
        #expect(observer.snapshot?.settled == false)
        runtime.now = 0.31
        runtime.timer?.fire()
        #expect(observer.snapshot?.settled == true)
        let settledPublications = publications
        for _ in 0..<100 { runtime.timer?.fire() }
        #expect(publications == settledPublications)
        runtime.context = nil
        runtime.timer?.fire()
        #expect(observer.snapshot == nil)
        runtime.context = .init(folderURL: URL(fileURLWithPath: "/fixture/other"),
                                frame: CGRect(x: 100, y: 100, width: 800, height: 600), settled: false)
        runtime.timer?.fire()
        #expect(observer.snapshot?.settled == false)
        #expect(observer.snapshot?.folderURL.lastPathComponent == "other")
        observer.stop()
        subscription.cancel()
    }

    @Test func repeatedStartStopReleasesObserverAndTimerOwnership() {
        let runtime = FinderObserverFixture()
        for _ in 0..<100 {
            autoreleasepool {
                var observer: FinderWindowObserver? = runtime.observer()
                weak var retained = observer
                observer?.start()
                observer?.stop()
                observer = nil
                #expect(retained == nil)
                #expect(runtime.timer?.isValid == false)
            }
        }
        let samples = runtime.samples
        runtime.notifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        #expect(runtime.samples == samples)
        #expect(runtime.timerCreations == 100)
    }

    @Test func releasingAnActiveObserverInvalidatesItsTimer() {
        let runtime = FinderObserverFixture()
        var observer: FinderWindowObserver? = runtime.observer()
        weak var released = observer
        observer?.start()
        observer = nil
        #expect(released == nil)
        #expect(runtime.timer?.isValid == false)
        runtime.notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        #expect(runtime.samples == 1)
    }

    @Test func nativePanelRepositionsForOneHundredCompactExpandedCycles() throws {
        _ = NSApplication.shared
        let finder = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 700, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let panel = CompanionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        finder.isReleasedWhenClosed = false
        panel.isReleasedWhenClosed = false
        defer { panel.close(); finder.close() }
        let animator = CompanionFrameAnimator()
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        for cycle in 0..<100 {
            finder.setFrameOrigin(NSPoint(x: 160 + cycle % 20, y: 160))
            let mode: FinderPanelPlacement.Mode = cycle.isMultiple(of: 2) ? .compact : .expanded
            let layout = try #require(FinderPanelPlacement.layout(beside: finder.frame, screen: screen, preferredMode: mode))
            animator.setFrame(layout.frame, of: panel, animated: false)
            #expect(panel.frame == layout.frame)
            #expect(!panel.frame.intersects(finder.frame))
            #expect(screen.contains(panel.frame))
        }
    }

    @Test func nativeWindowChurnRecordsResourceUseWithoutOpeningUserFolders() async {
        _ = NSApplication.shared
        func churn(_ count: Int) -> [NativeWindowReferences] {
            (0..<count).map { _ in
                let references = NativeWindowReferences()
                autoreleasepool {
                    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 700, height: 500),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
                    let panel = CompanionPanel(contentRect: NSRect(x: 912, y: 200, width: 96, height: 360),
                                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                    references.window = window
                    references.panel = panel
                    window.isReleasedWhenClosed = false
                    panel.isReleasedWhenClosed = false
                    panel.contentView = NSTextField(labelWithString: "Fixture course")
                    panel.setFrameOrigin(NSPoint(x: 924, y: 212))
                    panel.close()
                    window.close()
                }
                return references
            }
        }
        _ = churn(20)
        await completeRunLoopTurn()
        let start = FinderStressResources.read()
        var previous = start
        for batch in 1...3 {
            let lifetimes = churn(100)
            await completeRunLoopTurn()
            #expect(lifetimes.allSatisfy { $0.window == nil && $0.panel == nil })
            let current = FinderStressResources.read()
            print("RS04_NATIVE_STRESS hidden native window/panel create-close cycles=\(batch * 100) " +
                  "batchWallMs=\((current.wall - previous.wall) * 1_000) " +
                  "totalCpuMs=\((current.cpu - start.cpu) * 1_000) " +
                  "residentBaseline=\(start.resident) residentCurrent=\(current.resident) releasedPairs=100")
            previous = current
        }
    }

    private func completeRunLoopTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform { continuation.resume() }
        }
    }

}

@MainActor
private final class NativeWindowReferences {
    weak var window: NSWindow?
    weak var panel: NSWindow?
}

private struct FinderStressResources {
    let wall: TimeInterval
    let cpu: TimeInterval
    let resident: UInt64

    static func read() -> Self {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
            Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        return Self(wall: ProcessInfo.processInfo.systemUptime, cpu: cpu,
                    resident: result == KERN_SUCCESS ? info.resident_size : 0)
    }
}

@MainActor
private final class FinderObserverFixture {
    let notifications = NotificationCenter()
    var trusted = true
    var active = true
    var now: TimeInterval = 0
    var samples = 0
    var timerCreations = 0
    var timer: Timer?
    var context: FinderWindowObserver.Snapshot? = .init(folderURL: URL(fileURLWithPath: "/fixture/course"),
                                                       frame: CGRect(x: 100, y: 100, width: 800, height: 600), settled: false)

    func observer() -> FinderWindowObserver {
        FinderWindowObserver(notificationCenter: notifications,
                             accessibilityTrusted: { self.trusted }, finderActive: { self.active },
                             windowSample: { self.samples += 1; return self.context }, uptime: { self.now },
                             makeTimer: { sample in
            self.timerCreations += 1
            let timer = Timer(timeInterval: 0.12, repeats: true) { _ in MainActor.assumeIsolated { sample() } }
            self.timer = timer
            return timer
        })
    }
}
