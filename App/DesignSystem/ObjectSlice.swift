// ScreenLingo – App – Narrow observation core (2.1.0)
import SwiftUI
import Combine

/// Publishes a small Equatable snapshot of an observable object (the engine, Diagnostics).
/// Views observe the slice instead of the 246 KB engine, so a caption or status change redraws only the views
/// whose own snapshot changed. It only READS properties after the source announces a change (at most ~4 times a
/// second); it never writes to the source.
@MainActor
final class ObjectSlice<Source: ObservableObject, Value: Equatable>: ObservableObject
    where Source.ObjectWillChangePublisher == ObservableObjectPublisher {
    @Published private(set) var value: Value
    private var cancellable: AnyCancellable?

    /// `milliseconds` is the throttle: dashboards that are live by design use a slower one than the default.
    init(_ source: Source, milliseconds: Int = 250, read: @escaping @MainActor (Source) -> Value) {
        value = read(source)
        cancellable = source.objectWillChange
            .receive(on: DispatchQueue.main)   // hop first: willChange fires before the new value is stored
            .throttle(for: .milliseconds(milliseconds), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self, weak source] _ in
                guard let self, let source else { return }
                let next = read(source)
                if next != self.value { self.value = next }
            }
    }
}

