import XCTest

@MainActor
final class SessionWorkCoordinatorTests: XCTestCase {
    func testRetiredAttemptDoesNotStartItsEmbeddedProvider() async throws {
        let owner = SessionWorkCoordinator()
        let attempt = try owner.beginAuthentication()
        owner.invalidateAuthentication()
        var providerStarted = false
        do {
            _ = try await owner.authenticate(attempt: attempt) {
                providerStarted = true
                return "unused"
            } beginPersistence: { false } endPersistence: {} persist: { $0 }
            XCTFail("Retired attempt should fail before launching its provider")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(providerStarted)
    }

    func testLogoutDrainsSuspendedEmbeddedProviderWithoutPersistingItsLateToken() async throws {
        let owner = SessionWorkCoordinator()
        let attempt = try owner.beginAuthentication()
        let provider = SessionSuspension()
        let draining = SessionSuspension()
        var savedTokens: [String] = []
        let embeddedSignIn = Task {
            try await owner.authenticate(attempt: attempt) {
                // Models a callback provider that replies even after cancellation.
                await provider.suspend()
                return "late embedded token"
            } beginPersistence: {
                XCTFail("The retired embedded request must never begin persistence")
                return false
            } endPersistence: {
                XCTFail("The retired embedded request never acquired persistence")
            } persist: { token in
                savedTokens.append(token)
                return token
            }
        }
        await provider.waitForArrival()
        let logout = Task {
            await owner.beginTransition {
                embeddedSignIn.cancel()
            } drain: {
                draining.arrive()
                _ = try? await embeddedSignIn.value
            }
        }
        await draining.waitForArrival()
        XCTAssertTrue(embeddedSignIn.isCancelled)
        XCTAssertTrue(owner.isTransitioning)
        provider.resume()
        let began = await logout.value
        XCTAssertTrue(began)
        owner.endTransition()
        XCTAssertTrue(savedTokens.isEmpty)
        do { _ = try await embeddedSignIn.value; XCTFail("Late embedded token succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNoThrow(try owner.beginAuthentication(), "A fresh retry can start after the old request drained")
    }

    func testAuthenticationSequenceDrainsBeforePersistingAndReleasesAfterward() async throws {
        let owner = SessionWorkCoordinator()
        let attempt = try owner.beginAuthentication()
        var events: [String] = []
        let result = try await owner.authenticate(attempt: attempt) {
            events.append("request")
            return 7
        } beginPersistence: {
            await owner.beginTransition(preservingAuthentication: attempt) {
                events.append("cancel old work")
            } drain: {
                events.append("drain old work")
            }
        } endPersistence: {
            events.append("release storage")
            owner.endTransition()
        } persist: { response in
            XCTAssertTrue(owner.isTransitioning)
            events.append("persist identity")
            return response + 1
        }
        XCTAssertEqual(result.identity, 8)
        XCTAssertTrue(owner.isCurrent(result.lease))
        XCTAssertFalse(owner.isTransitioning)
        XCTAssertEqual(events, ["request", "cancel old work", "drain old work", "persist identity", "release storage"])
    }

    func testProductionAuthenticationBoundaryRejectsReplyAfterLogout() async throws {
        let owner = SessionWorkCoordinator()
        let attempt = try owner.beginAuthentication()
        let reply = SessionSuspension()
        let signIn = Task {
            try await owner.authenticate(attempt: attempt) {
                await reply.suspend()
                return 7
            } beginPersistence: {
                XCTFail("A retired request must never acquire persistence")
                return true
            } endPersistence: {
                XCTFail("This attempt never owned storage")
            } persist: { response in
                XCTFail("A retired request must never save credentials")
                return response
            }
        }
        await reply.waitForArrival()
        let began = await owner.beginTransition {} drain: {}
        XCTAssertTrue(began)
        owner.endTransition()
        reply.resume()
        do { _ = try await signIn.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testProductionAuthenticationBoundaryRejectsLogoutDuringDrainAndReleasesStorage() async throws {
        let owner = SessionWorkCoordinator()
        let attempt = try owner.beginAuthentication()
        let draining = SessionSuspension()
        var released = false
        let signIn = Task {
            try await owner.authenticate(attempt: attempt) { 7 } beginPersistence: {
                await owner.beginTransition(preservingAuthentication: attempt) {} drain: {
                    await draining.suspend()
                }
            } endPersistence: {
                released = true
                owner.endTransition()
            } persist: { response in
                XCTFail("Logout during draining must win before credentials are saved")
                return response
            }
        }
        await draining.waitForArrival()
        owner.invalidateAuthentication()
        draining.resume()
        do { _ = try await signIn.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(released)
        XCTAssertFalse(owner.isTransitioning)
    }

    func testTransitionInvalidatesRepliesAndCancelsBeforeWaitingForWorkers() async throws {
        let owner = SessionWorkCoordinator()
        let previous = owner.lease
        let authentication = try owner.beginAuthentication()
        let gate = SessionSuspension()
        var events: [String] = []
        let transition = Task {
            await owner.beginTransition {
                events.append("cancel")
            } drain: {
                events.append("drain")
                await gate.suspend()
                events.append("drained")
            }
        }
        await gate.waitForArrival()
        XCTAssertEqual(events, ["cancel", "drain"])
        XCTAssertFalse(owner.isCurrent(previous))
        XCTAssertFalse(owner.isCurrent(authentication))
        XCTAssertTrue(owner.isTransitioning)
        XCTAssertThrowsError(try owner.beginAuthentication())
        let overlapping = await owner.beginTransition { XCTFail("Must not cancel a newer owner's work") } drain: {
            XCTFail("Must not start a second drain")
        }
        XCTAssertFalse(overlapping)
        gate.resume()
        let began = await transition.value
        XCTAssertTrue(began)
        XCTAssertTrue(owner.isTransitioning, "The caller still owns its storage changes after draining")
        events.append("replace storage")
        owner.endTransition()
        XCTAssertEqual(events, ["cancel", "drain", "drained", "replace storage"])
        XCTAssertFalse(owner.isTransitioning)
        XCTAssertTrue(owner.isCurrent(owner.lease))
    }

    func testCancellationIgnoringWorkerIsDrainedBeforeStorageRetires() async {
        let owner = SessionWorkCoordinator()
        let gate = SessionSuspension()
        var writes: [String] = []
        // A synchronous filesystem scan or callback API can ignore cancellation.
        let worker = Task {
            await gate.suspend()
            writes.append("old database write")
        }
        await gate.waitForArrival()
        let drainEntered = SessionSuspension()
        let transition = Task {
            let began = await owner.beginTransition { worker.cancel() } drain: {
                await drainEntered.suspend()
                await worker.value
            }
            XCTAssertTrue(began)
            writes.append("retire database")
            owner.endTransition()
        }
        await drainEntered.waitForArrival()
        XCTAssertTrue(worker.isCancelled)
        XCTAssertTrue(writes.isEmpty)
        drainEntered.resume()
        gate.resume()
        await transition.value
        XCTAssertEqual(writes, ["old database write", "retire database"])
    }

    func testLateNetworkReplyCannotPublishForNewSessionWithSameCourseID() async {
        let owner = SessionWorkCoordinator()
        let oldLease = owner.lease
        let reply = SessionSuspension()
        var covers = [42: "new site's cover"]
        let oldRequest = Task {
            await reply.suspend()
            guard owner.isCurrent(oldLease) else { return }
            covers[42] = "old site's cover"
        }
        await reply.waitForArrival()
        let began = await owner.beginTransition {} drain: {}
        XCTAssertTrue(began)
        owner.endTransition()
        reply.resume()
        await oldRequest.value
        XCTAssertEqual(covers[42], "new site's cover")
    }

    func testOlderAuthenticationCleanupDoesNotClearNewAttempt() throws {
        let owner = SessionWorkCoordinator()
        let first = try owner.beginAuthentication()
        let second = try owner.beginAuthentication()
        owner.finishAuthentication(first)
        XCTAssertFalse(owner.isCurrent(first))
        XCTAssertTrue(owner.isCurrent(second))
        owner.finishAuthentication(second)
        XCTAssertFalse(owner.isCurrent(second))
    }

    func testLogoutInvalidatesSignInWhileItsPersistenceDrainIsSuspended() async throws {
        let owner = SessionWorkCoordinator()
        let attempt = try owner.beginAuthentication()
        let drain = SessionSuspension()
        var persisted = false
        let signIn = Task {
            let began = await owner.beginTransition(preservingAuthentication: attempt) {} drain: {
                await drain.suspend()
            }
            XCTAssertTrue(began)
            defer { owner.endTransition() }
            guard owner.isCurrent(attempt) else { return }
            persisted = true
        }
        await drain.waitForArrival()
        XCTAssertTrue(owner.isCurrent(attempt))
        owner.invalidateAuthentication()
        drain.resume()
        await signIn.value
        XCTAssertFalse(persisted)
    }

    func testExplicitTransitionWaiterResumesAfterStorageOwnershipEnds() async {
        let owner = SessionWorkCoordinator()
        let began = await owner.beginTransition {} drain: {}
        XCTAssertTrue(began)
        let entered = SessionSuspension()
        var waiterFinished = false
        let waiter = Task {
            entered.arrive()
            await owner.waitForTransition()
            waiterFinished = true
        }
        await entered.waitForArrival()
        XCTAssertFalse(waiterFinished)
        owner.endTransition()
        await waiter.value
        XCTAssertTrue(waiterFinished)
    }

    func testOverlappingAdoptionsCannotClearAnotherOwnerOrTransition() async {
        let owner = SessionWorkCoordinator()
        let first = owner.beginAdoption()
        let second = owner.beginAdoption()
        let began = await owner.beginTransition {} drain: {}
        XCTAssertTrue(began)
        owner.endAdoption(first)
        XCTAssertTrue(owner.isAdoptingDatabase)
        owner.endAdoption(first)
        XCTAssertTrue(owner.isAdoptingDatabase)
        owner.endAdoption(second)
        XCTAssertFalse(owner.isAdoptingDatabase)
        XCTAssertTrue(owner.isTransitioning)
        owner.endTransition()
    }

    func testCancelledTaskCannotUseOtherwiseCurrentLease() async {
        let owner = SessionWorkCoordinator()
        let lease = owner.lease
        let gate = SessionSuspension()
        let task = Task {
            await gate.suspend()
            XCTAssertTrue(owner.owns(lease), "Cancellation must still allow terminal cleanup for this session")
            return owner.isCurrent(lease)
        }
        await gate.waitForArrival()
        task.cancel()
        gate.resume()
        let current = await task.value
        XCTAssertFalse(current)
    }
}

/// Deterministic suspension, deliberately independent of task cancellation.
@MainActor
private final class SessionSuspension {
    private var arrived = false
    private var suspended: CheckedContinuation<Void, Never>?
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        await withCheckedContinuation { continuation in
            suspended = continuation
            arrive()
        }
    }

    func arrive() {
        arrived = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForArrival() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func resume() {
        let continuation = suspended
        suspended = nil
        continuation?.resume()
    }
}
