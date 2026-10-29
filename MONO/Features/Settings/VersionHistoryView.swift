import SwiftUI

/// Software release notes, bundled with the app so they work offline. (Backups of your data live in Backup & recovery.)
struct VersionHistoryView: View {
    @State private var expanded: Set<String> = [VersionHistory.current]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                currentCard
                SectionHeader(title: "Timeline").padding(.top, 4)
                ForEach(Array(VersionHistory.releases.enumerated()), id: \.element.id) { i, r in
                    releaseCard(r, isLast: i == VersionHistory.releases.count - 1).entrance(i)
                }
            }
            .padding(.horizontal, Theme.gutter).padding(.vertical, 8).padding(.bottom, 24)
        }
        .monoScreen()
        .navigationTitle("Version history")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var currentCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("You have").font(.footnote).foregroundStyle(Theme.inkSecondary)
            Text("Version \(VersionHistory.current)").font(.title2.weight(.semibold)).foregroundStyle(Theme.ink)
            Text("Build \(VersionHistory.build)\(VersionHistory.releases.first?.version == VersionHistory.current ? " · \(VersionHistory.releases[0].title)" : "")")
                .font(.subheadline).foregroundStyle(Theme.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).glass(padding: 18)
    }

    private func releaseCard(_ r: Release, isLast: Bool) -> some View {
        let isCurrent = r.version == VersionHistory.current
        let open = expanded.contains(r.id)
        return HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle().fill(isCurrent ? Theme.accent : Theme.inkTertiary.opacity(0.6)).frame(width: 10, height: 10).padding(.top, 20)
                if !isLast { Rectangle().fill(Theme.cardLine).frame(width: 1).frame(maxHeight: .infinity) }
            }.frame(width: 10)
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { if open { expanded.remove(r.id) } else { expanded.insert(r.id) } }
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text("Version \(r.version)").font(.headline).foregroundStyle(Theme.ink)
                                if isCurrent {
                                    Text("Current").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                                        .padding(.vertical, 3).padding(.horizontal, 8).background(Theme.accentSoft, in: Capsule())
                                }
                            }
                            Text(r.title).font(.subheadline).foregroundStyle(Theme.inkSecondary)
                            Text((r.approximateDate ? "About " : "") + r.date + " · \(r.changeCount) changes")
                                .font(.caption).foregroundStyle(Theme.inkTertiary)
                        }
                        Spacer()
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(Theme.inkTertiary)
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }.buttonStyle(PressableStyle())
                if open {
                    group("New", "sparkles", r.notes)
                    group("Improvements", "wand.and.stars", r.improvements)
                    group("Fixes", "wrench.and.screwdriver", r.fixes)
                    group("Security", "lock.shield", r.security)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).glass(padding: 18)
        }
    }

    @ViewBuilder private func group(_ title: String, _ symbol: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                ForEach(items, id: \.self) { note in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(Theme.accent.opacity(0.7)).frame(width: 5, height: 5).offset(y: -2)
                        Text(note).font(.subheadline).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
