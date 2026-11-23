import Foundation
import Translation

extension ModeTranslationService {
    /// 2.6.1 (switch stallWatchdog): the 4 s time limit above only asks the session to cancel, and the lane stays
    /// occupied until the call returns. A call that ignores the cancel request would keep the lane busy for good.
    /// Six seconds after that request the call is abandoned: the lane is released as for a failed call (the
    /// session is dropped, a new one is created next time) and a late result is ignored. Switch off: as in 2.6.0.
    static let abandonAfterSeconds = 10.0

    static func awaitCall(_ call: Task<Result<[String]?, Error>, Never>) async -> Result<[String]?, Error> {
        guard TranslationHotPathAB.stallWatchdog else { return await call.value }
        let raced = try? await ModelCallRace.run(limit: abandonAfterSeconds) { await call.value }
        if case .some(.value(let result)) = raced { return result }
        return .failure(CancellationError())
    }
}
