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
    private let cancel: @MainActor (Session) -> Void

    init(cancel: @escaping @MainActor (Session) -> Void) { self.cancel = cancel }

    func begin(key: String, make: () -> Session) -> Lease {
        precondition(active == nil, "Speculative requests must remain serialized")
        guard let ticket = sharedLease.begin() else { preconditionFailure("Actual Apple Default call still owns the speculative session") }
        let session = idle?.key == key ? idle!.session : make()
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

    /// Context changes discard idle state and prevent late completions from
    /// restoring a previous language/model session into the reusable slot.
    func reset() {
        epoch = UUID()
        sharedLease.reset()
        idle = nil
        cancelActive()
    }
}
