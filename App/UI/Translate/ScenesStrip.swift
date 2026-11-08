// ScreenLingo – App – Translate: Scenes chips (2.1.0, spec §13.5.6; presets are called scenes in the UI)
// Tap applies. Long-press: Edit, Duplicate, Use at start-up, Delete. One horizontal row, no grid.
import SwiftUI

struct ScenesStrip: View {
    @ObservedObject var store: PresetStore
    @EnvironmentObject private var feedback: FeedbackCenter
    @State private var editor: PresetEditorMode?
    @State private var pendingDelete: Preset?

    var body: some View {
        VStack(alignment: .leading, spacing: KitSpace.tight) {
            HStack {
                Text("Scenes").font(.headline)
                Spacer()
                NavigationLink("Manage") { PresetManagerView(store: store) }
                    .font(.subheadline)
                    .frame(minHeight: 44)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: KitSpace.tight) {
                    ForEach(store.all) { chip($0) }
                    Button { editor = .new } label: {
                        Label("Save current", systemImage: "plus")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, KitSpace.row)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Save current settings as a scene")
                }
            }
            .scrollClipDisabled()
            if let active = store.active, store.isModified {
                Text("\(active.name) has unsaved changes")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .sheet(item: $editor) { PresetEditor(store: store, mode: $0) }
        .confirmationDialog("Delete this scene?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { scene in
            Button("Delete \(scene.name)", role: .destructive) {
                store.delete(scene.id)
                feedback.show("\(scene.name) deleted", severity: .info)
            }
        }
    }

    private func chip(_ scene: Preset) -> some View {
        let active = store.activeID == scene.id.uuidString
        return Button {
            store.apply(scene)
            feedback.show("\(scene.name) applied", severity: .success)
        } label: {
            HStack(spacing: KitSpace.unit + 2) {
                Image(systemName: scene.symbol)
                Text(scene.name).lineLimit(1)
                if active && store.isModified {
                    Circle().fill(Color.orange).frame(width: 8, height: 8).accessibilityLabel("Changed")
                }
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, KitSpace.row)
            .frame(minHeight: 44)
            .foregroundStyle(active ? Color.white : Color.primary)
            .background(active ? scene.color : Color(uiColor: .secondarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: active)
        .contextMenu {
            if !scene.builtIn {
                Button { editor = .edit(scene) } label: { Label("Edit…", systemImage: "pencil") }
            }
            Button { _ = store.duplicate(scene); feedback.show("Duplicated \(scene.name)", severity: .info) } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button {
                store.startupID = store.startupID == scene.id.uuidString ? nil : scene.id.uuidString
            } label: {
                Label(store.startupID == scene.id.uuidString ? "Don't use at start-up" : "Use at start-up", systemImage: "power")
            }
            if !scene.builtIn {
                Button(role: .destructive) { pendingDelete = scene } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }
}
