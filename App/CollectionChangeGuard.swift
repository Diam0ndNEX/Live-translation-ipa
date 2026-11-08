// ScreenLingo – App – Confirm before a collection change ends the current Test Run (2.2.1, U6)
import SwiftUI

/// A change to diagnostics collection that is waiting for the person to confirm it.
struct PendingCollectionChange: Identifiable {
    let id = UUID()
    let apply: () -> Void
}

extension Binding where Value == Bool {
    /// Writes go straight through when no run is recording. While a run is recording the write waits in `pending`
    /// until the person confirms, because any collection change resets the diagnostics and ends the run.
    @MainActor
    func guardedByActiveRun(_ diag: Diagnostics, pending: Binding<PendingCollectionChange?>) -> Binding<Bool> {
        Binding<Bool>(
            get: { wrappedValue },
            set: { newValue in
                guard newValue != wrappedValue else { return }
                if diag.activeRun != nil {
                    pending.wrappedValue = PendingCollectionChange { wrappedValue = newValue }
                } else {
                    wrappedValue = newValue
                }
            })
    }
}

extension View {
    func confirmCollectionChange(_ pending: Binding<PendingCollectionChange?>) -> some View {
        confirmationDialog("This ends the current run.", isPresented: Binding(
            get: { pending.wrappedValue != nil },
            set: { if !$0 { pending.wrappedValue = nil } }), titleVisibility: .visible) {
            Button("Change and end run", role: .destructive) {
                pending.wrappedValue?.apply()
                pending.wrappedValue = nil
            }
            Button("Keep recording", role: .cancel) { pending.wrappedValue = nil }
        } message: {
            Text("Changing collection starts a new diagnostic session. Save the run first if you want to keep it.")
        }
    }
}
