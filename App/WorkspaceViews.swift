import SwiftUI
import PhotosUI
import Vision
import ImageIO
import UniformTypeIdentifiers

struct TranslationWorkspace: View {
    @EnvironmentObject private var engine: TranslatorEngine
    @EnvironmentObject private var feedback: FeedbackCenter
    @State private var input = ""
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var recognizing = false
    @State private var errorText: String?
    @State private var ocrTask: Task<Void, Never>?
    @State private var ocrRequestID = UUID()
    @AppStorage("photoOCREdge") private var photoEdge = 2400
    @AppStorage("photoAutoTranslate") private var photoAutoTranslate = false

    var body: some View {
        SheetScaffold(title: "Text & photos") {
            ScreenScaffold {
                Text("Translate typed text, a photo, a screenshot or a file. Live screen reading continues when you close this.")
                    .font(.subheadline).foregroundStyle(.secondary)
                LanguagePairBar(source: $engine.sourceCode, target: $engine.targetCode, items: engine.languages,
                                swapDisabled: engine.sourceCode == "auto") { engine.swapLanguages() }
                HStack(spacing: Space.s) {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Photo", systemImage: "photo").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    Button { importing = true } label: { Label("File", systemImage: "folder").frame(maxWidth: .infinity, minHeight: 44) }
                    Button { input = String((UIPasteboard.general.string ?? "").prefix(12000)) } label: {
                        Label("Paste", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(recognizing)
                VStack(alignment: .leading, spacing: Space.s) {
                    TextEditor(text: $input).frame(minHeight: 160).scrollContentBackground(.hidden)
                        .accessibilityLabel("Text to translate")
                    HStack {
                        Text("\(input.count) / 12,000 characters").font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear", role: .destructive) { input = "" }.disabled(input.isEmpty).frame(minHeight: 44)
                    }
                }.infoCard()
                if recognizing { ProgressRow(title: "Reading the image on your device…") }
                if let errorText { Banner(text: errorText, severity: .error) }
                PrimaryButton(title: engine.isTranslating ? "Translating…" : "Translate", symbol: "sparkles",
                              enabled: !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !recognizing && !engine.isTranslating) {
                    engine.translateText(input)
                }
                if !engine.translated.isEmpty {
                    VStack(alignment: .leading, spacing: Space.m) {
                        SectionHeader(title: "Translation")
                        Text(engine.translated).font(.title3).textSelection(.enabled)
                        HStack(spacing: Space.s) {
                            SecondaryButton(title: "Copy", symbol: "doc.on.doc") { UIPasteboard.general.string = engine.translated; feedback.show("Copied", severity: .success) }
                            SecondaryButton(title: "Listen", symbol: "speaker.wave.2") { engine.speak(engine.translated) }
                            ShareLink(item: engine.translated) { Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.bordered)
                        }
                    }.infoCard()
                }
                Text(engine.status).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onAppear { engine.beginWorkspace() }
        .onDisappear { ocrRequestID = UUID(); ocrTask?.cancel(); recognizing = false; engine.endWorkspace() }
        .onChange(of: input) { _, value in if value.count > 12000 { input = String(value.prefix(12000)) } }
        .onChange(of: photo) { _, value in
            ocrTask?.cancel()
            let requestID = UUID()
            ocrRequestID = requestID
            recognizing = true
            errorText = nil
            ocrTask = Task {
                defer { if ocrRequestID == requestID { recognizing = false } }
                do {
                    guard let data = try await value?.loadTransferable(type: Data.self), !Task.isCancelled else { return }
                    await readImage(data, requestID: requestID)
                } catch { if ocrRequestID == requestID && !Task.isCancelled { errorText = error.localizedDescription } }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .plainText]) { result in
            do {
                let url = try result.get()
                ocrTask?.cancel()
                ocrRequestID = UUID()
                recognizing = false
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                if let text = String(data: data, encoding: .utf8), url.pathExtension.lowercased() == "txt" {
                    input = String(text.prefix(12000))
                } else {
                    ocrTask?.cancel()
                    let requestID = UUID()
                    ocrRequestID = requestID
                    ocrTask = Task { await readImage(data, requestID: requestID) }
                }
            } catch { errorText = error.localizedDescription }
        }
    }

    @MainActor private func readImage(_ data: Data, requestID: UUID) async {
        guard ocrRequestID == requestID, !Task.isCancelled else { return }
        recognizing = true; errorText = nil
        defer { if ocrRequestID == requestID { recognizing = false } }
        let language = engine.sourceCode
        let edge = max(1600, min(3200, photoEdge))
        let task = Task.detached(priority: .userInitiated) { () throws -> String in
            try Task.checkCancellation()
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
            try Task.checkCancellation()
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            try Task.checkCancellation()
            let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                let b = observation.boundingBox
                return OCRLine(t: text, x: Double(b.midX), y: Double(b.midY), h: Double(b.height), w: Double(b.width))
            }
            return OCRGrouping.readingOrder(lines).map(\.t).joined(separator: "\n")
        }
        do {
            let text = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard !Task.isCancelled, ocrRequestID == requestID else { return }
            input = String(text.prefix(12000))
            if text.isEmpty { errorText = "No readable text found. Try a sharper image." }
            else if photoAutoTranslate { engine.translateText(input) }
        } catch { if !Task.isCancelled && ocrRequestID == requestID { errorText = error.localizedDescription } }
    }
}

/// Choose which part of the screen is read.
/// The broadcast extension owns capture, so the app has no live frame to show. The box is drawn over an honest
/// "Preview" placeholder, not over your screen. Drag the box or its handles, or use the sliders.
struct CaptureAreaEditor: View {
    @EnvironmentObject private var engine: TranslatorEngine
    @EnvironmentObject private var feedback: FeedbackCenter
    @Environment(\.dismiss) private var dismiss
    @AppStorage("customY0") private var lower = 0.0
    @AppStorage("customY1") private var upper = 0.5
    @AppStorage("area") private var area = "smart"
    @State private var base: (Double, Double)?
    private var range: ClosedRange<Double> { ExportFormat.normalizedArea(lower, upper) }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

    var body: some View {
        SheetScaffold(title: "Capture area") {
            ScreenScaffold {
                Text("The highlighted band is the part of the screen ScreenLingo reads. Move it away from player controls, or shrink it to the subtitles.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Banner(text: "This is a preview, not your live screen. iOS gives capture only to the broadcast extension.", severity: .info)
                GeometryReader { geo in
                    let h = geo.size.height
                    let top = h * (1 - range.upperBound)
                    let bottom = h * (1 - range.lowerBound)
                    ZStack(alignment: .top) {
                        RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Palette.surfaceRaised)
                        VStack { Text("Top of screen"); Spacer(); Text("Bottom of screen") }
                            .font(.caption.bold()).foregroundStyle(.secondary).padding(Space.m)
                        Rectangle().fill(Color.accentColor.opacity(0.3))
                            .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 2))
                            .frame(height: max(24, bottom - top)).offset(y: top)
                            .gesture(DragGesture()
                                .onChanged { v in
                                    if base == nil { base = (lower, upper) }
                                    guard let b = base else { return }
                                    let span = b.1 - b.0
                                    let lo = clamp(b.0 - Double(v.translation.height / h), 0, 1 - span)
                                    lower = lo; upper = lo + span
                                }.onEnded { _ in base = nil })
                            .accessibilityHidden(true)
                        handle.offset(y: top - 10)
                            .gesture(DragGesture()
                                .onChanged { v in
                                    if base == nil { base = (lower, upper) }
                                    guard let b = base else { return }
                                    upper = clamp(b.1 - Double(v.translation.height / h), b.0 + 0.1, 1)
                                }.onEnded { _ in base = nil })
                            .accessibilityHidden(true)
                        handle.offset(y: bottom - 10)
                            .gesture(DragGesture()
                                .onChanged { v in
                                    if base == nil { base = (lower, upper) }
                                    guard let b = base else { return }
                                    lower = clamp(b.0 - Double(v.translation.height / h), 0, b.1 - 0.1)
                                }.onEnded { _ in base = nil })
                            .accessibilityHidden(true)
                    }
                }.frame(height: 300).frame(maxWidth: 220).frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("Top edge: \(Int(range.upperBound * 100))% from the bottom")
                    Slider(value: $upper, in: 0.1...1).accessibilityLabel("Top edge of the capture area")
                    Text("Bottom edge: \(Int(range.lowerBound * 100))% from the bottom")
                    Slider(value: $lower, in: 0...0.9).accessibilityLabel("Bottom edge of the capture area")
                }.infoCard()
                HStack(spacing: Space.s) {
                    SecondaryButton(title: "Full screen") { lower = 0; upper = 1 }
                    SecondaryButton(title: "Subtitles") { lower = 0; upper = 0.35 }
                    SecondaryButton(title: "Middle") { lower = 0.3; upper = 0.7 }
                }
                PrimaryButton(title: "Use this area") {
                    let selection = range
                    lower = selection.lowerBound; upper = selection.upperBound; area = "custom"
                    engine.syncConfig(); feedback.show("Capture area updated", severity: .success); dismiss()
                }
            }
        }
    }

    private var handle: some View {
        Capsule().fill(Color.accentColor).frame(width: 64, height: 20)
            .overlay(Image(systemName: "line.3.horizontal").font(.caption2).foregroundStyle(.white))
            .frame(maxWidth: .infinity)
    }
}
