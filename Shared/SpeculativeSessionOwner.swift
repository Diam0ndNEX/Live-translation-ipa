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
        private(set) var cancellationRequestedAt: TimeInterval?

        init(session: Session, key: String, epoch: UUID) {
            self.session = session; self.key = key; self.epoch = epoch
        }

        fileprivate func requestCancellation(at now: TimeInterval) {
            cancellationRequestedAt = now
        }
    }

    private var epoch = UUID()
    private var idle: (key: String, session: Session)?
    private var active: Lease?
    private let cancel: @MainActor (Session) -> Void

    init(cancel: @escaping @MainActor (Session) -> Void) { self.cancel = cancel }

    func begin(key: String, make: () -> Session) -> Lease {
        precondition(active == nil, "Speculative requests must remain serialized")
        let session = idle?.key == key ? idle!.session : make()
        idle = nil
        let lease = Lease(session: session, key: key, epoch: epoch)
        active = lease
        return lease
    }

    /// Idempotent. The lease stays active until its awaited request unwinds;
    /// requesting cancellation never authorizes a competing model call.
    @discardableResult
    func cancelActive(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let active, active.cancellationRequestedAt == nil else { return false }
        active.requestCancellation(at: now)
        cancel(active.session)
        return true
    }

    func finish(_ lease: Lease, reusable: Bool) {
        guard active === lease else { return }
        active = nil
        if reusable, lease.epoch == epoch, lease.cancellationRequestedAt == nil {
            idle = (lease.key, lease.session)
        }
    }

    /// Transfer sole ownership back to the confirmed lane. The session cannot
    /// remain in both slots: a later speculative cancellation must not poison
    /// a handle still advertised as ready for confirmed work.
    func takeReusable(key: String) -> Session? {
        guard active == nil, let idle, idle.key == key else { return nil }
        self.idle = nil
        return idle.session
    }

    /// Context changes discard idle state and prevent late completions from
    /// restoring a previous language/model session into the reusable slot.
    func reset() {
        epoch = UUID()
        idle = nil
        cancelActive()
    }
}
