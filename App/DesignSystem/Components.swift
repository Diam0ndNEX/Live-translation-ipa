// ScreenLingo – App – Shared small components still used by settings and developer pages (2.1.0)
import SwiftUI

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
            .frame(minHeight: 36)
            .background(severity.color.opacity(0.16), in: Capsule())
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
        .overlay(alignment: .leading) { Capsule().fill(severity.color).frame(width: 4).padding(.vertical, Space.s) }
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
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!enabled)
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
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }
}

/// Round icon button; always at least 44 x 44 pt and always labelled.
// MARK: - Rows
struct ListRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: Space.m) {
            if let symbol {
                Image(systemName: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: Space.s)
            trailing()
        }.frame(minHeight: 52).contentShape(Rectangle())
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
        }.frame(minHeight: 52)
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
