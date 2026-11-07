// ScreenLingo – App – Non-observing engine access (2.0.0 build 86)
import SwiftUI
import Combine

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

/// Holds one snapshot of the engine and refreshes it (at most ~4 times a second) only when the snapshot changes.
@MainActor
final class FactsBox<Value: Equatable>: ObservableObject {
    private(set) var current: Value?
    private var cancellable: AnyCancellable?

    func attach(_ engine: TranslatorEngine, read: @escaping @MainActor (TranslatorEngine) -> Value) {
        guard cancellable == nil else { return }
        current = read(engine)   // not published: this happens while the view is being updated
        cancellable = engine.objectWillChange
            .receive(on: DispatchQueue.main)
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self, weak engine] _ in
                guard let self, let engine else { return }
                let next = read(engine)
                if next != self.current { self.current = next; self.objectWillChange.send() }
            }
    }
}

/// For pages that must show a few live engine values: `@EngineFacts(MyFacts.read) private var facts`.
/// The page redraws only when one of those values changes, not on every engine change.
@propertyWrapper
struct EngineFacts<Value: Equatable>: DynamicProperty {
    @Environment(\.engineRef) private var ref
    @StateObject private var box = FactsBox<Value>()
    private let read: @MainActor (TranslatorEngine) -> Value

    init(_ read: @escaping @MainActor (TranslatorEngine) -> Value) { self.read = read }

    var wrappedValue: Value {
        guard let value = box.current else { preconditionFailure("EngineFacts read before the app root provided the engine") }
        return value
    }
    func update() {
        if box.current == nil, let ref { box.attach(ref, read: read) }
    }
}
