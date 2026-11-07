// ScreenLingo – App – Design system components (2.0.0 build 88)
import SwiftUI

// MARK: - Surfaces
struct InfoCardModifier: ViewModifier {
    var raised = false
    func body(content: Content) -> some View {
        content
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(raised ? Palette.surfaceRaised : Palette.surface, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Palette.separator, lineWidth: 1))
    }
}
extension View {
    /// The one card surface (replaces the old flat card style).
    func infoCard(raised: Bool = false) -> some View { modifier(InfoCardModifier(raised: raised)) }
}

/// Page background plus consistent scrolling content padding.
struct ScreenScaffold<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) { content() }
                .padding(.horizontal, Space.l).padding(.vertical, Space.m)
        }
        .background(Palette.background.ignoresSafeArea())
    }
}

struct SectionHeader: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
        }.accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Status
enum Severity { case info, success, warning, error
    var color: Color {
        switch self { case .info: .accentColor; case .success: Palette.success; case .warning: Palette.warning; case .error: Palette.danger }
    }
    var symbol: String {
        switch self { case .info: "info.circle.fill"; case .success: "checkmark.circle.fill"; case .warning: "exclamationmark.triangle.fill"; case .error: "xmark.octagon.fill" }
    }
    var label: String {
        switch self { case .info: "Info"; case .success: "Success"; case .warning: "Warning"; case .error: "Error" }
    }
}

/// Status is always text plus an icon, never colour alone.
struct StatusPill: View {
    let text: String
    var symbol: String? = nil
    var severity: Severity = .info
    var body: some View {
        Label { Text(text).font(.footnote.weight(.semibold)) } icon: { Image(systemName: symbol ?? severity.symbol) }
            .foregroundStyle(severity.color)
            .padding(.horizontal, Space.m).padding(.vertical, Space.s)
            .frame(minHeight: 32)
            .background(severity.color.opacity(0.14), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

struct Banner: View {
    let text: String
    var severity: Severity = .info
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: severity.symbol).foregroundStyle(severity.color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s) {
                Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(actionTitle, action: action).font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.m)
        .background(severity.color.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

struct EmptyState: View {
    let title: String
    let symbol: String
    let message: String
    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
    }
}

struct ProgressRow: View {
    let title: String
    var value: Double? = nil
    var body: some View {
        HStack(spacing: Space.m) {
            if let value { ProgressView(value: value).frame(maxWidth: 80) } else { ProgressView() }
            Text(title).font(.subheadline)
        }.accessibilityElement(children: .combine)
    }
}

// MARK: - Buttons
struct PrimaryButton: View {
    let title: String
    var symbol: String? = nil
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                if let symbol { Image(systemName: symbol) }
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(.white)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }
}

struct SecondaryButton: View {
    let title: String
    var symbol: String? = nil
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                if let symbol { Image(systemName: symbol) }
                Text(title).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }
}

/// Round icon button; always at least 44 x 44 pt and always labelled.
struct IconButton: View {
    let symbol: String
    let label: String
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .background(Palette.surfaceRaised, in: Circle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }
}

// MARK: - Rows
struct ListRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: Space.m) {
            if let symbol { Image(systemName: symbol).frame(width: 28).foregroundStyle(Color.accentColor).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: Space.s)
            trailing()
        }.frame(minHeight: 44).contentShape(Rectangle())
    }
}

struct LabeledToggleRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
        }.frame(minHeight: 44)
    }
}

// MARK: - Language picker (the only implementation)
struct LanguagePicker: View {
    @Binding var code: String
    let items: [LangItem]
    var allowAuto = false
    var label: String { code == "auto" ? "Auto-detect" : (items.first { $0.code == code }?.name ?? code) }
    var body: some View {
        Menu {
            if allowAuto { Button("Auto-detect") { code = "auto" } }
            ForEach(items) { i in Button(i.name) { code = i.code } }
        } label: {
            HStack(spacing: Space.xs) {
                Text(label).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold)).opacity(0.6)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        }
        .accessibilityLabel(label)
    }
}

/// Source ⇄ target with swap. Reads and writes through the bindings only.
struct LanguagePairBar: View {
    @Binding var source: String
    @Binding var target: String
    let items: [LangItem]
    var swapDisabled = false
    let onSwap: () -> Void
    var body: some View {
        HStack(spacing: Space.s) {
            LanguagePicker(code: $source, items: items, allowAuto: true)
            IconButton(symbol: "arrow.left.arrow.right", label: "Swap source and target languages", enabled: !swapDisabled, action: onSwap)
            LanguagePicker(code: $target, items: items)
        }
    }
}

// MARK: - Sheets and confirmation
struct SheetScaffold<Content: View>: View {
    let title: String
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder var content: () -> Content
    var body: some View {
        NavigationStack {
            content()
                .background(Palette.background.ignoresSafeArea())
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

extension View {
    /// Destructive confirmation attached to the view that owns the action (never to a Section).
    func confirmDestructive(_ title: String, message: String? = nil, isPresented: Binding<Bool>, button: String = "Delete", perform: @escaping () -> Void) -> some View {
        confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
            Button(button, role: .destructive, action: perform)
            Button("Cancel", role: .cancel) {}
        } message: { if let message { Text(message) } }
    }
}

// MARK: - Branding
/// The same screen-and-arrow motif used by the application icon.
struct BrandMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13).fill(LinearGradient(colors: [Color(red: 0.21, green: 0.13, blue: 0.40), Color(red: 0.035, green: 0.043, blue: 0.075)], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 9).stroke(Color.mint, lineWidth: 2).padding(8)
            VStack(spacing: 0) {
                Image(systemName: "arrow.right").foregroundStyle(.white)
                Image(systemName: "arrow.left").foregroundStyle(.mint)
            }.font(.footnote.weight(.bold))
        }.accessibilityHidden(true)
    }
}
