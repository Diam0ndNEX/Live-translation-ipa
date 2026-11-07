import SwiftUI
import PhotosUI
import Vision
import ImageIO
import UniformTypeIdentifiers

struct TranslationWorkspace: View {
    let engine: TranslatorEngine
    @StateObject private var pair: EngineSlice<PairSnapshot>
    @StateObject private var output: EngineSlice<OutputSnapshot>
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

    init(engine: TranslatorEngine) {
        self.engine = engine
        _pair = StateObject(wrappedValue: EngineSlice(engine) { PairSnapshot.read($0) })
        _output = StateObject(wrappedValue: EngineSlice(engine) { OutputSnapshot.read($0) })
    }

    var body: some View {
        SheetScaffold(title: "Text & photos") {
            ScreenScaffold {
                Text("Translate typed text, a photo, a screenshot or a file. Live screen reading continues when you close this.")
                    .font(.subheadline).foregroundStyle(.secondary)
                LanguagePairBar(source: Binding(get: { pair.value.source }, set: { engine.sourceCode = $0 }),
                                target: Binding(get: { pair.value.target }, set: { engine.targetCode = $0 }),
                                items: pair.value.languages, swapDisabled: pair.value.source == "auto") { engine.swapLanguages() }
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
                PrimaryButton(title: output.value.translating ? "Translating…" : "Translate", symbol: "sparkles",
                              enabled: !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !recognizing && !output.value.translating) {
                    engine.translateText(input)
                }
                if !output.value.translated.isEmpty {
                    VStack(alignment: .leading, spacing: Space.m) {
                        SectionHeader(title: "Translation")
                        Text(output.value.translated).font(.title3).textSelection(.enabled)
                        HStack(spacing: Space.s) {
                            SecondaryButton(title: "Copy", symbol: "doc.on.doc") { UIPasteboard.general.string = output.value.translated; feedback.show("Copied", severity: .success) }
                            SecondaryButton(title: "Listen", symbol: "speaker.wave.2") { engine.speak(output.value.translated) }
                            ShareLink(item: output.value.translated) { Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.bordered)
                        }
                    }.infoCard()
                }
                Text(output.value.status).font(.footnote).foregroundStyle(.secondary)
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
    @EngineHandle private var engine
    @EnvironmentObject private var feedback: FeedbackCenter
    @Environment(\.dismiss) private var dismiss
    @AppStorage("customY0") private var lower = 0.0
    @AppStorage("customY1") private var upper = 0.5
    @AppStorage("area") private var area = "smart"
    @State private var base: (Double, Double)?
    // Preview only, never saved: the band is a fraction of the screen height in the screen's own orientation,
    // so the same two numbers apply to portrait and landscape. These just change the picture it is drawn on.
    @State private var landscape = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var photo: UIImage?
    private var previewSize: CGSize { landscape ? CGSize(width: 340, height: 190) : CGSize(width: 150, height: 300) }
    private var range: ClosedRange<Double> { ExportFormat.normalizedArea(lower, upper) }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

    var body: some View {
        SheetScaffold(title: "Capture area") {
            ScreenScaffold {
                Text("The highlighted band is the part of the screen ScreenLingo reads. Move it away from player controls, or shrink it to the subtitles.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Banner(text: "This is a preview, not your live screen. iOS gives capture only to the broadcast extension.", severity: .info)
                Picker("Preview shape", selection: $landscape) {
                    Text("Portrait").tag(false)
                    Text("Landscape").tag(true)
                }.pickerStyle(.segmented)
                Hint("The area is a share of the screen height, counted from the bottom, and follows the screen's orientation. The same band works in portrait and landscape.")
                GeometryReader { geo in
                    let h = geo.size.height
                    let top = h * (1 - range.upperBound)
                    let bottom = h * (1 - range.lowerBound)
                    ZStack(alignment: .top) {
                        previewBackground(width: geo.size.width, height: h)
                        VStack { Text("Top of screen"); Spacer(); Text("Bottom of screen") }
                            .font(.caption.bold()).foregroundStyle(photo == nil ? Color.secondary : Color.white)
                            .shadow(radius: photo == nil ? 0 : 2).padding(Space.s)
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
                }.frame(width: previewSize.width, height: previewSize.height).frame(maxWidth: .infinity)
                HStack(spacing: Space.s) {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label(photo == nil ? "Use my own screenshot" : "Choose another", systemImage: "photo")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.bordered)
                    if photo != nil {
                        SecondaryButton(title: "Use the example") { photo = nil; pickerItem = nil }
                    }
                }
                Hint("Your picture stays on this screen as a guide. It is not saved or uploaded.")
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
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                    feedback.show("That picture could not be opened", severity: .warning)
                    return
                }
                photo = await image.byPreparingThumbnail(ofSize: CGSize(width: 900, height: 900)) ?? image
            }
        }
    }

    /// The picture the band is drawn on: your own screenshot, or a drawn example frame with a subtitle line.
    @ViewBuilder private func previewBackground(width: CGFloat, height: CGFloat) -> some View {
        if let photo {
            Image(uiImage: photo).resizable().scaledToFill()
                .frame(width: width, height: height).clipped()
                .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                .accessibilityHidden(true)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                    .fill(LinearGradient(colors: [Color.indigo.opacity(0.55), Color.teal.opacity(0.45)], startPoint: .top, endPoint: .bottom))
                VStack(spacing: 0) {
                    Spacer()
                    Text("Example subtitle line")
                        .font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, Space.s).padding(.vertical, 3)
                        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    Spacer().frame(height: height * 0.12)
                }
                Text("Example picture").font(.caption2).foregroundStyle(.white.opacity(0.8))
            }
            .accessibilityHidden(true)
        }
    }

    private var handle: some View {
        Capsule().fill(Color.accentColor).frame(width: 64, height: 20)
            .overlay(Image(systemName: "line.3.horizontal").font(.caption2).foregroundStyle(.white))
            .frame(maxWidth: .infinity)
    }
}
