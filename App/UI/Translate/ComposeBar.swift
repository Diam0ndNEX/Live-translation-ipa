// ScreenLingo – App – Translate: compose bar and result (2.1.0, spec §13.5.1; replaces the Text & photos sheet)
// Type or paste, or read a photo or file with the same on-device OCR the old workspace used.
import SwiftUI
import PhotosUI
import Vision
import ImageIO
import UniformTypeIdentifiers

struct ComposeBar: View {
    let engine: TranslatorEngine
    @Binding var composing: Bool
    @EnvironmentObject private var feedback: FeedbackCenter
    @State private var input = ""
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var recognizing = false
    @State private var ocrTask: Task<Void, Never>?
    @State private var ocrRequestID = UUID()
    @FocusState private var fieldFocused: Bool
    @AppStorage("photoOCREdge") private var photoEdge = 2400
    @AppStorage("photoAutoTranslate") private var photoAutoTranslate = false

    private var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(alignment: .bottom, spacing: KitSpace.tight) {
            TextField(recognizing ? "Reading the image…" : "Type or paste…", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .focused($fieldFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, KitSpace.row)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityLabel("Text to translate")
            if trimmed.isEmpty {
                PhotosPicker(selection: $photo, matching: .images) {
                    Image(systemName: "photo").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Translate a photo")
                Button { importing = true } label: { Image(systemName: "folder").frame(width: 44, height: 44) }
                    .accessibilityLabel("Translate a file")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Translate")
            }
        }
        .disabled(recognizing)
        .padding(.horizontal, KitSpace.tight)
        .padding(.vertical, KitSpace.unit)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, KitSpace.margin)
        .padding(.vertical, KitSpace.tight)
        .onChange(of: input) { _, value in if value.count > 12000 { input = String(value.prefix(12000)) } }
        .onChange(of: photo) { _, value in
            guard let value else { return }
            ocrTask?.cancel()
            let requestID = UUID()
            ocrRequestID = requestID
            recognizing = true
            ocrTask = Task {
                defer { if ocrRequestID == requestID { recognizing = false; photo = nil } }
                do {
                    guard let data = try await value.loadTransferable(type: Data.self), !Task.isCancelled else { return }
                    await readImage(data, requestID: requestID)
                } catch {
                    if ocrRequestID == requestID && !Task.isCancelled { feedback.show(error.localizedDescription, severity: .error) }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .plainText]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 25_000_000 {
                    feedback.show("That file is too large to read. Try one under 25 MB.", severity: .warning)
                    return
                }
                let data = try Data(contentsOf: url)
                let isText = UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .text) ?? false
                if isText, let text = String(data: data, encoding: .utf8) {
                    input = String(text.prefix(12000))
                } else {
                    ocrTask?.cancel()
                    let requestID = UUID()
                    ocrRequestID = requestID
                    ocrTask = Task { await readImage(data, requestID: requestID) }
                }
            } catch { feedback.show(error.localizedDescription, severity: .error) }
        }
        .onDisappear { ocrRequestID = UUID(); ocrTask?.cancel(); recognizing = false }
    }

    private func send() {
        guard !trimmed.isEmpty else { return }
        if !composing { engine.beginWorkspace(); composing = true }
        engine.translateText(input)
        fieldFocused = false
        input = ""
    }

    @MainActor private func readImage(_ data: Data, requestID: UUID) async {
        guard ocrRequestID == requestID, !Task.isCancelled else { return }
        recognizing = true
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
            if text.isEmpty { feedback.show("No readable text found. Try a sharper image.", severity: .warning) }
            else if photoAutoTranslate { send() }
        } catch {
            if !Task.isCancelled && ocrRequestID == requestID {
                let unreadable = (error as? CocoaError)?.code == .fileReadCorruptFile
                feedback.show(unreadable ? "ScreenLingo can read images and plain text files. This file is neither." : error.localizedDescription,
                              severity: .error)
            }
        }
    }
}

/// The typed or photo translation, shown where the live caption would be. Close returns to live capture.
struct ComposeResult: View {
    let engine: TranslatorEngine
    let translated: String
    let original: String
    var close: () -> Void
    @EnvironmentObject private var feedback: FeedbackCenter

    var body: some View {
        VStack(alignment: .leading, spacing: KitSpace.row) {
            HStack {
                Label("Your text", systemImage: "character.cursor.ibeam").font(.headline)
                Spacer()
                Button("Done", action: close).frame(minHeight: 44)
            }
            if translated.isEmpty {
                ProgressView("Translating…").frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(translated).font(.title2.weight(.semibold)).textSelection(.enabled)
                if !original.isEmpty {
                    Text(original).font(.body).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack(spacing: KitSpace.tight) {
                    Button { UIPasteboard.general.string = translated; feedback.show("Copied", severity: .success) } label: {
                        Label("Copy", systemImage: "doc.on.doc").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    Button { engine.speak(translated) } label: {
                        Label("Listen", systemImage: "speaker.wave.2").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    ShareLink(item: translated) {
                        Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .buttonStyle(.bordered)
                .font(.subheadline.weight(.medium))
            }
        }
        .padding(KitSpace.margin)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
