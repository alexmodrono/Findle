import Foundation

/// Main-actor ownership of asynchronous session work. Cancellation asks work to
/// stop; leases also reject replies from APIs that finish after cancellation.
@MainActor
final class SessionWorkCoordinator {
    struct Lease: Equatable, Sendable { fileprivate let id: UUID }
    struct AuthenticationLease: Equatable, Sendable { fileprivate let id: UUID }

    private(set) var lease = Lease(id: UUID())
    private(set) var isTransitioning = false
    private var authentication: AuthenticationLease?
    private var transitionWaiters: [CheckedContinuation<Void, Never>] = []
    private var adoptions: Set<UUID> = []

    var isAdoptingDatabase: Bool { !adoptions.isEmpty }

    /// Terminal cleanup/reporting still belongs to a cancelled task until its
    /// session is retired. New writes and requests also require isCurrent.
    func owns(_ candidate: Lease) -> Bool { candidate == lease }

    func isCurrent(_ candidate: Lease) -> Bool {
        owns(candidate) && !Task.isCancelled
    }

    func isCurrent(_ candidate: AuthenticationLease) -> Bool {
        authentication == candidate && !Task.isCancelled
    }

    func beginAuthentication() throws -> AuthenticationLease {
        try Task.checkCancellation()
        guard !isTransitioning else { throw CancellationError() }
        let attempt = AuthenticationLease(id: UUID())
        authentication = attempt
        return attempt
    }

    func finishAuthentication(_ candidate: AuthenticationLease) {
        if authentication == candidate { authentication = nil }
    }

    func invalidateAuthentication() { authentication = nil }

    /// The production authentication boundary: a delayed request cannot enter
    /// persistence after logout, and a logout during draining wins before any
    /// credential or identity write. Persistence itself never suspends.
    func authenticate<Response: Sendable, Identity: Sendable>(
        attempt: AuthenticationLease,
        request: () async throws -> Response,
        beginPersistence: () async -> Bool,
        endPersistence: () -> Void,
        persist: (Response) throws -> Identity
    ) async throws -> (lease: Lease, identity: Identity) {
        guard isCurrent(attempt) else { throw CancellationError() }
        let response = try await request()
        guard isCurrent(attempt) else { throw CancellationError() }
        guard await beginPersistence() else { throw CancellationError() }
        defer { endPersistence() }
        guard isCurrent(attempt) else { throw CancellationError() }
        return (lease, try persist(response))
    }

    /// All cancellation happens before any suspension. The owner keeps the
    /// transition until its storage changes finish, then calls endTransition.
    func beginTransition(
        preservingAuthentication attempt: AuthenticationLease? = nil,
        cancel: () -> Void,
        drain: () async -> Void
    ) async -> Bool {
        guard !isTransitioning else { return false }
        if let attempt, !isCurrent(attempt) { return false }
        isTransitioning = true
        lease = Lease(id: UUID())
        if attempt == nil { invalidateAuthentication() }
        cancel()
        await drain()
        return true
    }

    func endTransition() {
        guard isTransitioning else { return }
        isTransitioning = false
        let waiters = transitionWaiters
        transitionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitForTransition() async {
        guard isTransitioning else { return }
        await withCheckedContinuation { transitionWaiters.append($0) }
    }

    /// Independent tokens avoid an old adoption restoring a transition flag
    /// after a newer reset or adoption has acquired ownership.
    func beginAdoption() -> UUID {
        let token = UUID()
        adoptions.insert(token)
        return token
    }

    func endAdoption(_ token: UUID) { adoptions.remove(token) }
}
