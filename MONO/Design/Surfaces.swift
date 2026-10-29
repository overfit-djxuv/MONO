import SwiftUI

// The 2.0 building blocks. Screens compose these instead of styling their own cards, so every list,
// figure strip, progress line and chip looks and behaves the same. All colours come from `Theme`,
// so custom themes, dark mode and the Liquid Glass slider apply automatically.

extension View {
    /// The one surface style for grouped content: a calm glass panel with a tighter corner than the old cards.
    func surface(padding: CGFloat = 16) -> some View { glass(padding: padding, radius: 18) }
}

/// A sentence-case section heading with an optional trailing action ("See all").
struct SectionTitle: View {
    let title: String
    var trailing: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
            Spacer()
            if let trailing, let action {
                Button(trailing, action: action).font(.subheadline.weight(.medium)).foregroundStyle(Theme.accent).buttonStyle(PressableStyle())
            }
        }
    }
}

/// Three (or two) figures side by side with hairline separators: the compact summary used by Dashboard and Transactions.
struct StatStrip: View {
    struct Item: Identifiable { let id = UUID(); let label: String; let value: String; var tint: Color = Theme.ink }
    let items: [Item]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label).font(.caption).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                    Text(item.value).font(.figure(17, weight: .semibold)).foregroundStyle(item.tint)
                        .lineLimit(1).minimumScaleFactor(0.65).contentTransition(.numericText())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, i == 0 ? 0 : 14)
                .overlay(alignment: .leading) { if i > 0 { Rectangle().fill(Theme.line).frame(width: 0.5) } }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A pill-shaped quick action with an icon. At least 44 points tall.
struct QuickChip: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: { Haptics.tap(); action() }) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium)).foregroundStyle(Theme.accent)
                .padding(.horizontal, 14).frame(minHeight: 44)
                .background(Theme.accentSoft, in: Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

/// Progress colour rule used everywhere: calm under 80%, bronze from 80%, clay when over.
enum ProgressTone {
    static func tint(_ fraction: Double) -> Color { fraction > 1 ? Theme.danger : fraction >= 0.8 ? Theme.warning : Theme.accent }
}

/// Name, supporting line, optional trailing figure, and a progress line: the shape of a goal or a category budget.
struct ProgressRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    var trailing: String? = nil
    var trailingTint: Color = Theme.ink
    let value: Double
    var tint: Color = Theme.accent
    var note: String? = nil
    var noteTint: Color = Theme.inkSecondary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                CategoryGlyph(symbol: symbol, tint: Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(subtitle).font(.footnote).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let trailing { Text(trailing).font(.figure(15, weight: .semibold)).foregroundStyle(trailingTint).lineLimit(1) }
            }
            ProgressLine(value: value, tint: tint, height: 5)
            if let note { Text(note).font(.footnote).foregroundStyle(noteTint).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}
