import SwiftUI

struct VersionHistoryView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(VersionHistory.releases.enumerated()), id: \.element.id) { i, r in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Version \(r.version)").font(.headline).foregroundStyle(Theme.ink)
                            if r.version == VersionHistory.current {
                                Text("Installed").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                                    .padding(.vertical, 3).padding(.horizontal, 8)
                                    .background(Theme.accentSoft, in: Capsule())
                            }
                            Spacer()
                            Text(r.date).font(.footnote).foregroundStyle(Theme.inkSecondary)
                        }
                        Text(r.title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.inkSecondary)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(r.notes, id: \.self) { note in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Circle().fill(Theme.accent.opacity(0.7)).frame(width: 5, height: 5).offset(y: -2)
                                    Text(note).font(.subheadline).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .glass(padding: 18)
                    .entrance(i)
                }
            }
            .padding(.horizontal, Theme.gutter).padding(.vertical, 8).padding(.bottom, 24)
        }
        .monoScreen()
        .navigationTitle("Version history")
        .navigationBarTitleDisplayMode(.inline)
    }
}
