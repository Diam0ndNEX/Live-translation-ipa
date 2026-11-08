// ScreenLingo – App – UI kit: settings rows, groups, press feedback and the soft top glow (2.1.2)
import SwiftUI

/// Press feedback for every custom tappable row: a small spring scale, never a flat highlight.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A rounded colour tile with a white symbol, the way the system Settings app marks its rows.
struct IconTile: View {
    let symbol: String
    var tint: Color = .blue
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 30
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: side * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(
                LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// One settings row: tile, title, live value, chevron. 48 pt, no big button around it.
struct SettingsRow: View {
    let title: String
    var value: String = ""
    let symbol: String
    var tint: Color = .blue
    var chevron = true
    var body: some View {
        HStack(spacing: KitSpace.row) {
            IconTile(symbol: symbol, tint: tint)
            Text(title).font(.body).lineLimit(2).layoutPriority(1)
            Spacer(minLength: KitSpace.tight)
            if !value.isEmpty {
                Text(value).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            if chevron {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, KitSpace.row)
        .padding(.vertical, 9)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A titled group of rows in one rounded container with inset dividers. Rows can be conditional.
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .textCase(.uppercase).padding(.leading, KitSpace.row)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(subviews.indices, id: \.self) { index in
                        subviews[index]
                        if index < subviews.count - 1 {
                            Divider().padding(.leading, KitSpace.row + 30 + KitSpace.row)
                        }
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            if let footer {
                Text(footer).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, KitSpace.row)
            }
        }
    }
}

/// A soft accent glow fading from the top edge: depth without a card. Off with Reduce Transparency.
struct AmbientGlow: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content.background(alignment: .top) {
            if !reduceTransparency {
                LinearGradient(colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 300)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func ambientGlow() -> some View { modifier(AmbientGlow()) }
}

extension View {
    /// One rounded surface for a single group of content (a chart, a counter list, a control block).
    func kitSurface(padding: CGFloat = KitSpace.row + 4) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Page treatment for a List or Form: grouped background with the soft accent glow behind it.
    func kitPage() -> some View {
        self.scrollContentBackground(.hidden)
            .ambientGlow()
            .background(Color(.systemGroupedBackground))
    }
}
