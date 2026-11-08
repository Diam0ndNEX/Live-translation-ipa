import Foundation

/// The live drain is serialized on MainActor. A speculative session is owned
/// separately from the confirmed session so cancellation cannot poison it.
@MainActor
final class SpeculativeSessionOwner<Session: AnyObject> {
    @MainActor
    final class Lease {
        let session: Session
        let key: String
        let epoch: UUID
        let ticket: UUID
        private(set) var cancellationRequestedAt: TimeInterval?

        init(session: Session, key: String, epoch: UUID, ticket: UUID) {
            self.session = session; self.key = key; self.epoch = epoch; self.ticket = ticket
        }

        fileprivate func requestCancellation(at now: TimeInterval) {
            cancellationRequestedAt = now
        }
    }

    private var epoch = UUID()
    private var sharedLease = AppleDefaultLeaseState()
    private var idle: (key: String, session: Session)?
    private var active: Lease?
    /// v2.0.0 G5: the idle session is lent to one confirmed request.
    private var lent = false
    private let cancel: @MainActor (Session) -> Void

    init(cancel: @escaping @MainActor (Session) -> Void) { self.cancel = cancel }

    /// 2.2.1 (E11): set when begin() found the owner busy. Read once with takeConflict().
    private var conflicted = false

    func takeConflict() -> Bool { defer { conflicted = false }; return conflicted }

    func begin(key: String, make: () -> Session) -> Lease {
        // 2.2.1 (E11): a second request while one is active (or while the physical Default call still
        // owns the session) used to trap. It now gets its own fresh session. That
        // lease is never stored as active, so finish() ignores it and it is never reused or cancelled here.
        guard active == nil, let ticket = sharedLease.begin() else {
            conflicted = true
            return Lease(session: make(), key: key, epoch: epoch, ticket: UUID())
        }
        // Never start a prediction on a session lent to a confirmed request.
        let session = !lent && idle?.key == key ? idle!.session : make()
        idle = nil
        let lease = Lease(session: session, key: key, epoch: epoch, ticket: ticket)
        active = lease
        return lease
    }

    /// Idempotent. The lease stays active until its awaited request unwinds;
    /// requesting cancellation never authorizes a competing model call.
    @discardableResult
    func cancelActive(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let active, active.cancellationRequestedAt == nil else { return false }
        active.requestCancellation(at: now)
        sharedLease.requestCancellation()
        cancel(active.session)
        return true
    }

    func finish(_ lease: Lease, reusable: Bool) {
        guard active === lease else { return }
        active = nil
        let physicalReusable = sharedLease.finish(lease.ticket, successful: reusable)
        if physicalReusable, lease.epoch == epoch, lease.cancellationRequestedAt == nil {
            idle = (lease.key, lease.session)
        }
    }

    /// v2.0.0 G5: lend the idle, uncancelled session to a confirmed request
    /// so consecutive model calls stay on one session. Ownership does not
    /// change and cancelActive() never reaches a lent session.
    func lendIdle(key: String) -> Session? {
        guard active == nil, !lent, let idle, idle.key == key else { return nil }
        lent = true
        return idle.session
    }

    /// A failed borrowed call may leave the session unusable: drop it.
    func returnLent(usable: Bool) {
        lent = false
        if !usable { idle = nil }
    }

    /// Context changes discard idle state and prevent late completions from
    /// restoring a previous language/model session into the reusable slot.
    func reset() {
        epoch = UUID()
        sharedLease.reset()
        idle = nil
        lent = false
        cancelActive()
    }
}
