// ScreenLingo – App – UI kit: AreaEditor (2.1.0, spec §13.4.3)
import SwiftUI
import PhotosUI
import UIKit

/// Full-screen editor for the reading band. The band is a fraction of the screen height counted from the bottom
/// (the stored `customY0`/`customY1` meaning, unchanged). Edits a draft; Save hands the result back, Cancel drops it.
/// iOS gives frames only to the broadcast extension, so the picture is a drawn example or the person's own screenshot,
/// and it says so.
struct AreaEditor: View {
    let initial: ClosedRange<Double>
    var onSave: (ClosedRange<Double>) -> Void
    var onCancel: () -> Void

    @State private var lower: Double
    @State private var upper: Double
    @State private var base: (Double, Double)?
    @State private var pickerItem: PhotosPickerItem?
    @State private var photo: UIImage?
    @Environment(\.dynamicTypeSize) private var typeSize

    init(initial: ClosedRange<Double>, onSave: @escaping (ClosedRange<Double>) -> Void, onCancel: @escaping () -> Void) {
        self.initial = initial
        self.onSave = onSave
        self.onCancel = onCancel
        _lower = State(initialValue: initial.lowerBound)
        _upper = State(initialValue: initial.upperBound)
    }

    private var range: ClosedRange<Double> { ExportFormat.normalizedArea(lower, upper) }
    private var label: String { "Reads \(Int((range.lowerBound * 100).rounded()))% to \(Int((range.upperBound * 100).rounded()))%" }

    var body: some View {
        NavigationStack {
            page {
                GeometryReader { geo in
                    let height = geo.size.height
                    let width = min(geo.size.width, height * 9 / 19.5)
                    canvas(width: width, height: height)
                        .frame(width: width, height: height)
                        .frame(maxWidth: .infinity)
                }
                // 2.2.2: at accessibility sizes the page scrolls and the picture keeps a usable height. The picture used
                // to shrink to a sliver and the example caption ran into the title.
                .frame(minHeight: 300)
                .frame(height: typeSize.isAccessibilitySize ? 380 : nil)
                Text(label)
                    .font(.headline.monospacedDigit())
                    .accessibilityHidden(true)
                Text("Counted from the bottom of the screen. Drag the band or its edges.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: KitSpace.tight) {
                        preset("Subtitles", 0, 0.35)
                        preset("Middle", 0.3, 0.7)
                        preset("Full screen", 0, 1)
                    }
                    VStack(spacing: KitSpace.tight) {
                        preset("Subtitles", 0, 0.35)
                        preset("Middle", 0.3, 0.7)
                        preset("Full screen", 0, 1)
                    }
                }
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label(photo == nil ? "Use my own screenshot" : "Choose another screenshot", systemImage: "photo")
                        .frame(minHeight: 44)
                }
                Text(photo == nil ? "Example picture, not your live screen." : "Your screenshot stays on this screen. It is not saved.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Reading area")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(range) }.bold() }
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
                photo = await image.byPreparingThumbnail(ofSize: CGSize(width: 900, height: 1900)) ?? image
            }
        }
    }

    /// The editor's content; scrolls at accessibility text sizes.
    @ViewBuilder private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let inner = VStack(spacing: KitSpace.row) { content() }
            .padding(.horizontal, KitSpace.margin)
            .padding(.bottom, KitSpace.tight)
        if typeSize.isAccessibilitySize { ScrollView { inner } } else { inner }
    }

    private func preset(_ title: String, _ lo: Double, _ hi: Double) -> some View {
        Button(title) { lower = lo; upper = hi }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

    @ViewBuilder private func canvas(width: CGFloat, height: CGFloat) -> some View {
        let top = height * (1 - range.upperBound)
        let bottom = height * (1 - range.lowerBound)
        ZStack(alignment: .top) {
            background(width: width, height: height)
            // Dim what is not read.
            Color.black.opacity(0.45).frame(height: max(0, top)).accessibilityHidden(true)
            Color.black.opacity(0.45).frame(height: max(0, height - bottom)).offset(y: bottom).accessibilityHidden(true)
            Rectangle()
                .fill(Color.accentColor.opacity(0.18))
                .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 2))
                .frame(height: max(24, bottom - top))
                .offset(y: top)
                .gesture(DragGesture()
                    .onChanged { v in
                        if base == nil { base = (range.lowerBound, range.upperBound) }
                        guard let b = base else { return }
                        let span = b.1 - b.0
                        let lo = clamp(b.0 - Double(v.translation.height / height), 0, 1 - span)
                        lower = lo; upper = lo + span
                    }
                    .onEnded { _ in base = nil })
                .accessibilityElement()
                .accessibilityLabel("Reading area")
                .accessibilityValue(label)
                .accessibilityHint("Swipe up or down to move it")
                .accessibilityAdjustableAction { direction in
                    let span = range.upperBound - range.lowerBound
                    let step = direction == .increment ? 0.05 : -0.05
                    let lo = clamp(range.lowerBound + step, 0, 1 - span)
                    lower = lo; upper = lo + span
                }
            edgeHandle.offset(y: top - 22)
                .gesture(DragGesture()
                    .onChanged { v in
                        if base == nil { base = (range.lowerBound, range.upperBound) }
                        guard let b = base else { return }
                        upper = clamp(b.1 - Double(v.translation.height / height), b.0 + 0.1, 1)
                    }
                    .onEnded { _ in base = nil })
            edgeHandle.offset(y: bottom - 22)
                .gesture(DragGesture()
                    .onChanged { v in
                        if base == nil { base = (range.lowerBound, range.upperBound) }
                        guard let b = base else { return }
                        lower = clamp(b.0 - Double(v.translation.height / height), 0, b.1 - 0.1)
                    }
                    .onEnded { _ in base = nil })
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// 44 pt touch target around a slim visible capsule.
    private var edgeHandle: some View {
        Capsule().fill(Color.accentColor).frame(width: 56, height: 6)
            .frame(width: 88, height: 44)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }

    @ViewBuilder private func background(width: CGFloat, height: CGFloat) -> some View {
        if let photo {
            Image(uiImage: photo).resizable().scaledToFill()
                .frame(width: width, height: height).clipped()
                .accessibilityHidden(true)
        } else {
            ZStack(alignment: .bottom) {
                Color(uiColor: .secondarySystemBackground)
                Text("Example subtitle line")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, KitSpace.tight).padding(.vertical, 3)
                    .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                    .padding(.bottom, height * 0.12)
            }
            .accessibilityHidden(true)
        }
    }
}
