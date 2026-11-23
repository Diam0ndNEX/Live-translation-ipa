import SwiftUI

// 2.6.0: why a confirmed unit missed memory (measurement only; see LooseUnitIndex).
extension TranslatorEngine {
    func noteMissKind(_ unit: String) {
        let kind = looseUnits.classifyMiss(unit)
        guard diag.enabled else { return }
        switch kind {
        case .new: diag.s.missNew += 1
        case .nearMiss: diag.s.missNearMiss += 1
        case .repeatedExact: diag.s.missRepeatedExact += 1
        }
    }
}
