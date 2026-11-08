// ScreenLingo – App – UI kit: LensRow (2.1.0, spec §13.4.3)
import SwiftUI

/// A list row: icon, title, one-line live value. Used as a NavigationLink label in Diagnostics lenses and Settings groups;
/// the system list draws the chevron. 44 pt tall (one line), grows only with Dynamic Type.
struct LensRow: View {
    let title: String
    var value: String = ""
    var symbol: String? = nil
    var valueTone: PhaseTone = .neutral
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            // At the largest sizes the value moves under the title instead of truncating.
            HStack(alignment: .firstTextBaseline, spacing: KitSpace.row) {
                if let symbol {
                    Image(systemName: symbol).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body)
                    if !value.isEmpty {
                        Text(value).font(.subheadline)
                            .foregroundStyle(valueTone == .neutral ? Color.secondary : valueTone.color)
                    }
                }
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: KitSpace.row) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.body)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: KitSpace.tight)
            if !value.isEmpty {
                Text(value)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(valueTone == .neutral ? Color.secondary : valueTone.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}
