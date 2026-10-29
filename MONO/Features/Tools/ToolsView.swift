import SwiftUI

/// Advanced tools live here, one tap from Overview, so the dashboard itself stays calm.
struct ToolsView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                NavigationLink { SubscriptionsView() } label: {
                    ToolRow(symbol: "arrow.triangle.2.circlepath", title: "Subscriptions & bills",
                            detail: "Everything that repeats, what it costs, and what’s due. Nothing is deducted until you confirm.")
                }
                .buttonStyle(PressableStyle())
                NavigationLink { SafeToSpendView() } label: {
                    ToolRow(symbol: "shield.lefthalf.filled", title: "Safe to spend",
                            detail: "What you can spend without touching bills, savings or essentials.")
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.horizontal, Theme.gutter).padding(.vertical, 8).padding(.bottom, 28)
        }
        .monoScreen()
        .navigationTitle("Tools")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ToolRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            CategoryGlyph(symbol: symbol, tint: Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(Theme.ink)
                Text(detail).font(.footnote).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Theme.inkTertiary)
        }
        .glass(padding: 16, radius: 20)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
