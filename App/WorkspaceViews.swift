import SwiftUI
import PhotosUI
import Vision
import ImageIO
import UniformTypeIdentifiers

struct TranslationWorkspace: View {
    @EnvironmentObject private var engine: TranslatorEngine
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var recognizing = false
    @State private var errorText: String?
    @State private var ocrTask: Task<Void, Never>?
    @AppStorage("photoOCREdge") private var photoEdge = 2400
    @AppStorage("photoAutoTranslate") private var photoAutoTranslate = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        BrandMark().frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Translate anything").font(.system(.title2, design: .rounded, weight: .bold))
                            Text("Text · photos · screenshots").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Translate a screenshot, a photo or your own text. Live screen reading resumes when you close this workspace.")
                        .foregroundStyle(.secondary)
                    HStack {
                        LangMenu(code: $engine.sourceCode, items: engine.languages, allowAuto: true)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        LangMenu(code: $engine.targetCode, items: engine.languages)
                    }
                    HStack {
                        PhotosPicker(selection: $photo, matching: .images) { Label("Photo", systemImage: "photo") }
                        Button { importing = true } label: { Label("File", systemImage: "folder") }
                        Button { input = String((UIPasteboard.general.string ?? "").prefix(12000)) } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(recognizing)
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $input).frame(minHeight: 180).scrollContentBackground(.hidden)
                            .accessibilityLabel("Text to translate")
                        HStack {
                            Text("\(input.count) / 12,000 characters").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Clear", role: .destructive) { input = "" }
                        }
                    }.card()
                    if recognizing { ProgressView("Reading image on your device…") }
                    if let errorText { Label(errorText, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    Button {
                        engine.translateText(input)
                    } label: {
                        HStack {
                            if engine.isTranslating { ProgressView().tint(.white) }
                            Label("Translate", systemImage: "sparkles").font(.headline)
                        }
                        .frame(maxWidth: .infinity).padding()
                        .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 18))
                    }
                    .foregroundStyle(.white)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || recognizing || engine.isTranslating)
                    if !engine.translated.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("YOUR TRANSLATION", systemImage: "sparkles").font(.caption.bold()).foregroundStyle(.mint)
                            Text(engine.translated).font(.title3).textSelection(.enabled)
                            HStack {
                                Button { UIPasteboard.general.string = engine.translated; engine.toast("Copied") } label: { Label("Copy", systemImage: "doc.on.doc") }
                                Button { engine.speak(engine.translated) } label: { Label("Listen", systemImage: "speaker.wave.2") }
                                ShareLink(item: engine.translated) { Image(systemName: "square.and.arrow.up") }
                            }.buttonStyle(.bordered)
                        }.card()
                    }
                    Text(engine.status).font(.footnote).foregroundStyle(.secondary)
                }.padding(20)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .onAppear { engine.beginWorkspace() }
        .onDisappear { ocrTask?.cancel(); engine.endWorkspace() }
        .onChange(of: input) { _, value in if value.count > 12000 { input = String(value.prefix(12000)) } }
        .onChange(of: photo) { _, value in
            ocrTask?.cancel()
            ocrTask = Task {
                do {
                    guard let data = try await value?.loadTransferable(type: Data.self), !Task.isCancelled else { return }
                    await readImage(data)
                } catch { errorText = error.localizedDescription }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .plainText]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                if let text = String(data: data, encoding: .utf8), url.pathExtension.lowercased() == "txt" {
                    input = String(text.prefix(12000))
                } else {
                    ocrTask?.cancel()
                    ocrTask = Task { await readImage(data) }
                }
            } catch { errorText = error.localizedDescription }
        }
    }

    @MainActor private func readImage(_ data: Data) async {
        recognizing = true; errorText = nil
        defer { recognizing = false }
        let language = engine.sourceCode
        let edge = max(1600, min(3200, photoEdge))
        let task = Task.detached(priority: .userInitiated) { () throws -> String in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: edge
                  ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = language == "auto"
            if language == "auto" {
                request.recognitionLanguages = try request.supportedRecognitionLanguages()
            } else {
                let supported = try request.supportedRecognitionLanguages()
                let base = language.split(separator: "-").first.map(String.init) ?? language
                if let match = supported.first(where: { $0 == language || $0.hasPrefix(base + "-") }) {
                    request.recognitionLanguages = [match]
                }
            }
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                let b = observation.boundingBox
                return OCRLine(t: text, x: Double(b.midX), y: Double(b.midY), h: Double(b.height), w: Double(b.width))
            }
            return OCRGrouping.readingOrder(lines).map(\.t).joined(separator: "\n")
        }
        do {
            let text = try await task.value
            guard !Task.isCancelled else { return }
            input = String(text.prefix(12000))
            if text.isEmpty { errorText = "No readable text found. Try a sharper image." }
            else if photoAutoTranslate { engine.translateText(input) }
        } catch { if !Task.isCancelled { errorText = error.localizedDescription } }
    }
}

struct CaptureAreaEditor: View {
    @EnvironmentObject private var engine: TranslatorEngine
    @Environment(\.dismiss) private var dismiss
    @AppStorage("customY0") private var lower = 0.0
    @AppStorage("customY1") private var upper = 0.5
    @AppStorage("area") private var area = "smart"
    private var range: ClosedRange<Double> { ExportFormat.normalizedArea(lower, upper) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Choose where to read").font(.title.bold())
                    Text("The highlighted band is the part of the screen ScreenLingo will read. Adjust it to avoid player controls or focus on subtitles.").foregroundStyle(.secondary)
                    GeometryReader { geometry in
                        ZStack(alignment: .top) {
                            RoundedRectangle(cornerRadius: 22).fill(Theme.cardStrong)
                            VStack { Text("TOP"); Spacer(); Text("BOTTOM") }
                                .font(.caption.bold()).foregroundStyle(.secondary).padding()
                            Rectangle().fill(Theme.accent.start.opacity(0.35))
                                .frame(height: geometry.size.height * (range.upperBound - range.lowerBound))
                                .overlay(Rectangle().stroke(Theme.accent.start, lineWidth: 2))
                                .offset(y: geometry.size.height * (1 - range.upperBound))
                        }.clipShape(RoundedRectangle(cornerRadius: 22))
                    }.frame(height: 280).frame(maxWidth: 200).frame(maxWidth: .infinity)
                    VStack(alignment: .leading) {
                        Text("Lower edge · \(Int(range.lowerBound * 100))% from bottom")
                        Slider(value: $lower, in: 0...0.9).accessibilityLabel("Lower capture edge")
                        Text("Upper edge · \(Int(range.upperBound * 100))% from bottom")
                        Slider(value: $upper, in: 0.1...1).accessibilityLabel("Upper capture edge")
                    }
                    HStack {
                        Button("Full screen") { lower = 0; upper = 1 }
                        Button("Subtitles") { lower = 0; upper = 0.35 }
                        Button("Middle") { lower = 0.3; upper = 0.7 }
                    }.buttonStyle(.bordered)
                    Button("Use this area") {
                        let selection = range
                        lower = selection.lowerBound; upper = selection.upperBound; area = "custom"
                        engine.syncConfig(); engine.toast("Capture area updated"); dismiss()
                    }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                }.padding(24)
            }.background(Theme.bg.ignoresSafeArea())
                .navigationTitle("Capture area").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

struct SessionControls: View {
    @EnvironmentObject private var engine: TranslatorEngine
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sessionLimit") private var limit = 0
    @AppStorage("privateSession") private var privateSession = false
    @State private var confirmClear = false
    var body: some View {
        NavigationStack {
            List {
                Section("This session") {
                    if let started = engine.sessionStarted { LabeledContent("Started", value: started.formatted(date: .omitted, time: .shortened)) }
                    LabeledContent("Translations", value: "\(engine.sessionTranslations)")
                    LabeledContent("Characters", value: "\(engine.sessionCharacters)")
                    Text(engine.status).font(.footnote).foregroundStyle(.secondary)
                }
                LatencyDetail(monitor: engine.latency)
                Section("Session controls") {
                    Toggle("Pause live translation", isOn: $engine.paused)
                    Toggle("Private session", isOn: $privateSession)
                    Text("Private sessions skip new history entries and writing translation memory to disk.").font(.footnote).foregroundStyle(.secondary)
                    Picker("Pause session after", selection: $limit) {
                        Text("No limit").tag(0); Text("15 minutes").tag(15); Text("30 minutes").tag(30); Text("1 hour").tag(60)
                    }
                    Button("Restart session timer") { engine.resetSession() }
                    Button("Clear current output", role: .destructive) { confirmClear = true }
                }
                Section("Recovery") {
                    Button("Refresh language readiness") { Task { await engine.refreshStatus() } }
                    Button("Reopen floating window") { engine.startPiP() }
                    Button("Copy diagnostic report") { UIPasteboard.general.string = engine.diag.report(engine: engine); engine.toast("Report copied") }
                }
            }.scrollContentBackground(.hidden).background(Theme.bg.ignoresSafeArea())
                .navigationTitle("Session").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
                .confirmationDialog("Clear the current output?", isPresented: $confirmClear) {
                    Button("Clear output", role: .destructive) { engine.clearOutput() }
                }
        }
    }
}
