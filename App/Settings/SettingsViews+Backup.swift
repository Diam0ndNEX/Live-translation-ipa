import SwiftUI

struct BackupSettings: View {
    @EngineHandle private var engine
    @State private var message = ""
    @State private var confirmReset = false

    var body: some View {
        List {
            Section {
                Button { Sharer.shareFile(text: engine.exportSettings(), name: "screen-translator-settings.json") } label: {
                    Label("Share all settings", systemImage: "square.and.arrow.up")
                }
                Button {
                    UIPasteboard.general.string = engine.exportSettings()
                    message = "Settings copied to the clipboard."
                } label: { Label("Copy all settings", systemImage: "doc.on.doc") }
                Button {
                    message = engine.importSettings(UIPasteboard.general.string ?? "")
                        ? "Settings imported from the clipboard."
                        : "The clipboard doesn't contain exported settings."
                } label: { Label("Import settings from clipboard", systemImage: "square.and.arrow.down") }
                if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("Settings backup")
            } footer: {
                Text("Share or copy your settings as text, keep it somewhere safe, and import it later to restore. Backups from earlier builds still restore. Presets have their own export.")
            }
            Section {
                Button("Reset every setting", role: .destructive) { confirmReset = true }
            } footer: {
                Text("Presets and history are kept.")
            }
        }
        .settingsPage("Backup and reset")
        .confirmDestructive("Reset every setting to its default?", message: "Presets and history are kept.", isPresented: $confirmReset, button: "Reset every setting") {
            engine.resetAllSettings()
        }
    }
}

// MARK: - About
struct AboutSettings: View {
    @EngineHandle private var engine
    @AppStorage("onboarded") private var onboarded = true

    var body: some View {
        List {
            Section("Version") {
                LabeledContent("App", value: AppVersion.full)
                LabeledContent("Capture extension",
                               value: engine.extensionVersion == "–" ? "not seen yet" : "v\(engine.extensionVersion)")
                LabeledContent("Legacy system", value: "based on \(TranslationSystem.referenceVersion)")
            }
            Section("How to use") {
                Text("1. On Translate, tap a language in the pair to choose it and get its pack.\n2. Tap the round Start button, choose ScreenLingo Capture, then Start Broadcast.\n3. Switch to your app. If nothing shows, tap the status at the top of Translate, or open Diagnostics.")
                    .font(.footnote)
                Button("Run setup again") { onboarded = false }
            }
            Section("What's new") {
                ForEach(Array(AppVersion.changelog.prefix(3)), id: \.1) { v in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("v\(v.0)").bold()
                        Text(v.1).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                NavigationLink("Full changelog") {
                    List(AppVersion.changelog, id: \.1) { v in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("v\(v.0)").bold()
                            Text(v.1).font(.footnote).foregroundStyle(.secondary)
                        }
                    }.settingsPage("Changelog")
                }
            }
        }
        .settingsPage("About ScreenLingo")
    }
}

struct PrivacySettings: View {
    @EngineHandle private var engine
    @AppStorage("privateSession") private var privateSession = false
    @AppStorage("diagIncludeText") private var includeText = false
    @AppStorage("showSessionSpeakers") private var showSpeakers = true

    var body: some View {
        List {
            Section {
                Toggle("Private session", isOn: $privateSession)
                Hint("New translations are not added to your Library or saved translation memory. Things saved earlier stay.")
            } header: { Text("Translation privacy") }
            Section {
                Toggle("Show recognized speaker labels", isOn: $showSpeakers)
                Hint("Only reads visible \"Name:\" labels. It does not identify voices or people without a label.")
                Toggle("Include recognized text in diagnostic exports", isOn: $includeText)
                Hint("Leave off unless a troubleshooting export needs the text. Reading and translating happen on your phone.")
            } header: { Text("Personal content") }
            Section {
                NavigationLink {
                    HistoryStorageSettings()
                } label: {
                    Label("Manage stored history", systemImage: "clock.arrow.circlepath")
                }
                NavigationLink {
                    MemoryManagementView()
                } label: {
                    Label("Manage translation memory", systemImage: "externaldrive")
                }
            } header: { Text("Review local data") }
            ResetSection(keys: ["privateSession", "diagIncludeText", "showSessionSpeakers"])
        }
        .settingsPage("Privacy")
    }
}
