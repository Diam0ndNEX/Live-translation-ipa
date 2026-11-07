// ScreenLingo – App – Non-observing engine access (2.0.0 build 85)
import SwiftUI

private struct EngineRefKey: EnvironmentKey {
    static let defaultValue: TranslatorEngine? = nil
}
extension EnvironmentValues {
    var engineRef: TranslatorEngine? {
        get { self[EngineRefKey.self] }
        set { self[EngineRefKey.self] = newValue }
    }
}

/// Gives a view the engine to CALL methods on, without subscribing to its changes.
/// Use it where a screen only calls engine methods; screens that display live engine values use a slice instead.
@propertyWrapper
struct EngineHandle: DynamicProperty {
    @Environment(\.engineRef) private var ref
    var wrappedValue: TranslatorEngine {
        guard let ref else { preconditionFailure("EngineHandle used outside the app root") }
        return ref
    }
}
