import SwiftUI

// 2.6.1: guards. A behaviour switch is turned off for the rest of the session (never saved) when the session's own
// numbers show it doing harm. Every trip is recorded and shown as a finding. Only one guard exists so far.
extension TranslatorEngine {
    /// Every 5 s from tick().
    func evaluateSwitchGuards() {
        guard tickCount % 5 == 0, diag.enabled, TranslationHotPathAB.growthSettle,
              SwitchGuard.growthShouldTrip(held: diag.s.growthHeld, dropped: diag.s.growthDropped) else { return }
        TranslationHotPathAB.sessionOff.insert("growthSettle")
        discardHeldGrowth()
        diag.noteModelState("switch_guard_tripped")
        diag.log("Growing-subtitle wait turned off for this session: most held captions were dropped")
    }
}
