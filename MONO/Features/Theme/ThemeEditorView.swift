import SwiftUI
import UIKit

/// System Theme: every appearance control in one place. A switch at the top moves between the app's colours and its home-screen icon.
/// Colour edits preview live across the whole app and only stick when saved.
struct ThemeEditorView: View {
    enum Tab: String, CaseIterable, Identifiable { case theme = "Theme", icon = "App icon"; var id: String { rawValue } }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemScheme
    @Environment(ErrorCenter.self) private var errors
    @AppStorage("appearance") private var appearance = 0
    @State private var tab: Tab
    @State private var editScheme: ColorScheme = .light
    @State private var draftName = ""
    @State private var showLeave = false
    @State private var pendingDelete: ThemePalette?
    @State private var confirmReset = false
    @State private var showAdvanced = false
    private let store = ThemeStore.shared

    init(initialTab: Tab = .theme) { _tab = State(initialValue: initialTab) }

    enum Field: CaseIterable, Identifiable {
        case primary, secondary, background, surface, accent, text, secondaryText, border
        var id: Self { self }
        var label: String {
            switch self {
            case .primary: "Primary"; case .secondary: "Secondary"; case .background: "Background"
            case .surface: "Surface"; case .accent: "Accent"; case .text: "Text"
            case .secondaryText: "Secondary text"; case .border: "Borders"
            }
        }
        var detail: String {
            switch self {
            case .primary: "Balance card, main buttons"; case .secondary: "Backdrop and chart tone"
            case .background: "Behind everything"; case .surface: "Cards and sheets"
            case .accent: "Links, progress, income"; case .text: "Titles and figures"
            case .secondaryText: "Captions and labels"; case .border: "Separators and card edges"
            }
        }
        /// Secondary text and borders follow your colours automatically until you pick one.
        var isOptional: Bool { self == .secondaryText || self == .border }
        func value(_ c: ThemeColors) -> UInt32 {
            switch self {
            case .primary: c.primary; case .secondary: c.secondary; case .background: c.background
            case .surface: c.surface; case .accent: c.accent; case .text: c.text
            case .secondaryText: c.textSecondary; case .border: c.cardLine
            }
        }
        func isOverridden(_ c: ThemeColors) -> Bool {
            switch self { case .secondaryText: c.secondaryText != nil; case .border: c.border != nil; default: false }
        }
        func set(_ c: inout ThemeColors, _ v: UInt32?) {
            switch self {
            case .primary: if let v { c.primary = v }; case .secondary: if let v { c.secondary = v }
            case .background: if let v { c.background = v }; case .surface: if let v { c.surface = v }
            case .accent: if let v { c.accent = v }; case .text: if let v { c.text = v }
            case .secondaryText: c.secondaryText = v; case .border: c.border = v
            }
        }
    }

    private var colors: ThemeColors { store.active.colors(for: editScheme) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("Section", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .padding(.top, 4)
                if tab == .theme {
                    ThemePreview(scheme: editScheme)
                    palettesCard
                    modeCard
                    coloursCard
                    contrastCard
                    glassCard
                } else {
                    AppIconCards()
                }
                actionsCard
            }
            .padding(.horizontal, Theme.gutter).padding(.vertical, 8).padding(.bottom, 28)
            .animation(Theme.easeOut(0.2), value: tab)
        }
        .monoScreen()
        .navigationTitle("System Theme")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(store.hasDraft)
        .toolbar {
            if store.hasDraft {
                ToolbarItem(placement: .cancellationAction) { Button("Back") { showLeave = true } }
            }
        }
        .confirmationDialog("Save your changes?", isPresented: $showLeave, titleVisibility: .visible) {
            Button("Save palette") { store.saveDraft(name: draftName); dismiss() }
            Button("Discard changes", role: .destructive) { store.discardDraft(); dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { p in
            Button("Delete palette", role: .destructive) { store.delete(p.id); Haptics.warning() }
        }
        .confirmationDialog("Reset System Theme?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset to default", role: .destructive) { resetAll() }
        } message: { Text("Colours return to Sage & Cream, your saved palettes are deleted, glass returns to its default, appearance follows the system and the app icon goes back to the original. Your financial data is not touched.") }
        .onAppear { editScheme = systemScheme; draftName = store.active.name }
        .onChange(of: store.active.id) { _, _ in draftName = store.active.name }
        .onDisappear { if store.hasDraft { store.discardDraft() } }   // an unsaved edit never outlives this screen
    }

    private func resetAll() {
        store.resetAll()
        appearance = 0
        if UIApplication.shared.alternateIconName != nil {
            Task { do { try await UIApplication.shared.setAlternateIconName(nil) } catch { errors.report(error, doing: "Couldn’t restore the icon") } }
        }
        Haptics.warning()
    }

    // MARK: Mode

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Appearance mode")
            Picker("Appearance", selection: $appearance) {
                Text("System").tag(0); Text("Light").tag(1); Text("Dark").tag(2)
            }
            .pickerStyle(.segmented)
            .onChange(of: appearance) { _, v in editScheme = v == 2 ? .dark : v == 1 ? .light : systemScheme }
            Text("System follows your iPhone. Every palette has a light and a dark version.").font(.footnote).foregroundStyle(Theme.inkSecondary)
        }
        .glass(padding: 18)
    }

    // MARK: Palettes

    private var palettesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Colour themes")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(store.palettes) { p in
                        Button { store.select(p.id); Haptics.tap() } label: {
                            PaletteChip(palette: p, scheme: editScheme, selected: store.active.id == p.id)
                        }
                        .buttonStyle(PressableStyle())
                        .contextMenu {
                            Button { store.duplicate(p.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                            if !store.isPreset(p.id) {
                                Button(role: .destructive) { pendingDelete = p } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                        .accessibilityLabel(p.name).accessibilityAddTraits(store.active.id == p.id ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4).padding(.horizontal, 2)
            }
            if store.hasDraft {
                Label("Editing \(store.active.name) (not saved yet)", systemImage: "pencil")
                    .font(.footnote.weight(.medium)).foregroundStyle(Theme.warning)
            } else {
                Text(store.isPreset(store.active.id) ? "Change any colour to make your own copy." : "Touch and hold a palette to duplicate or delete it.")
                    .font(.footnote).foregroundStyle(Theme.inkSecondary)
            }
        }
        .glass(padding: 18)
    }

    // MARK: Colours

    private var coloursCard: some View {
        let fields = showAdvanced ? Field.allCases : Field.allCases.filter { !$0.isOptional }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionHeader(title: "Custom colours")
                Spacer()
                Picker("Editing", selection: $editScheme) { Text("Light").tag(ColorScheme.light); Text("Dark").tag(ColorScheme.dark) }
                    .pickerStyle(.segmented).frame(width: 140)
            }
            .padding(.bottom, 8)
            ForEach(Array(fields.enumerated()), id: \.element) { i, f in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.label).font(.body).foregroundStyle(Theme.ink)
                        Text(f.isOptional && !f.isOverridden(colors) ? "Automatic" : f.detail).font(.caption).foregroundStyle(Theme.inkSecondary)
                    }
                    Spacer()
                    if f.isOverridden(colors) {
                        Button("Auto") { store.edit { p in updateColors(&p) { f.set(&$0, nil) } } }
                            .font(.caption.weight(.medium)).foregroundStyle(Theme.accent).buttonStyle(PressableStyle())
                    }
                    ColorPicker(f.label, selection: binding(f), supportsOpacity: false).labelsHidden()
                }
                .padding(.vertical, 8)
                if i < fields.count - 1 { Hairline() }
            }
            Button { withAnimation(Theme.easeOut(0.2)) { showAdvanced.toggle() } } label: {
                Label(showAdvanced ? "Fewer colours" : "Text and border colours", systemImage: showAdvanced ? "chevron.up" : "chevron.down")
                    .font(.footnote.weight(.medium)).foregroundStyle(Theme.accent)
            }
            .buttonStyle(PressableStyle()).padding(.top, 8)
        }
        .glass(padding: 18)
    }

    private func updateColors(_ p: inout ThemePalette, _ change: (inout ThemeColors) -> Void) {
        if editScheme == .dark { change(&p.dark) } else { change(&p.light) }
    }

    private func binding(_ f: Field) -> Binding<Color> {
        Binding(
            get: { Color(hex: f.value(colors)) },
            set: { new in
                let hex = ColorMath.hex(from: new)
                store.edit { p in updateColors(&p) { f.set(&$0, hex) } }
            })
    }

    // MARK: Contrast

    private struct Check: Identifiable { let id: String; let ratio: Double; let needed: Double }

    private var checks: [Check] {
        let c = colors
        return [Check(id: "Text on background", ratio: ColorMath.contrast(c.text, c.background), needed: 4.5),
                Check(id: "Text on cards", ratio: ColorMath.contrast(c.text, c.surface), needed: 4.5),
                Check(id: "Secondary text", ratio: ColorMath.contrast(c.textSecondary, c.surface), needed: 4.5),
                Check(id: "Accent on cards", ratio: ColorMath.contrast(c.accent, c.surface), needed: 3),
                Check(id: "Text on primary", ratio: ColorMath.contrast(c.onPrimary, c.primary), needed: 4.5)]
    }

    private var contrastCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Readability")
            ForEach(checks) { c in
                HStack {
                    Image(systemName: c.ratio >= c.needed ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(c.ratio >= c.needed ? Theme.accent : Theme.warning)
                    Text(c.id).font(.subheadline).foregroundStyle(Theme.ink)
                    Spacer()
                    Text(String(format: "%.1f : 1", c.ratio)).font(.figure(14)).foregroundStyle(Theme.inkSecondary)
                }
                .accessibilityElement(children: .combine)
            }
            if checks.contains(where: { $0.ratio < $0.needed }) {
                Callout(text: "Some combinations are below the recommended contrast (4.5 : 1 for text, 3 : 1 for accents) and may be hard to read. You can still save them.", tone: .warning)
            } else {
                Text("All combinations meet WCAG AA contrast.").font(.footnote).foregroundStyle(Theme.inkSecondary)
            }
        }
        .glass(padding: 18)
    }

    // MARK: Glass

    private var glassCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "Liquid Glass")
                Spacer()
                Text("\(Int((store.glass * 100).rounded()))%").font(.figure(14)).foregroundStyle(Theme.inkSecondary)
            }
            Slider(value: Binding(get: { store.glass }, set: { store.setGlass($0) }), in: 0...1)
                .tint(Theme.accent)
                .accessibilityLabel("Liquid Glass intensity")
                .accessibilityValue("\(Int((store.glass * 100).rounded())) percent")
            HStack {
                Text("Subtle").font(.caption).foregroundStyle(Theme.inkSecondary)
                Spacer()
                Text("Strong").font(.caption).foregroundStyle(Theme.inkSecondary)
            }
            Text("Adjusts transparency, blur, reflections and the colour glowing through the glass. At the low end cards are almost solid.")
                .font(.footnote).foregroundStyle(Theme.inkSecondary)
        }
        .glass(padding: 18)
    }

    // MARK: Actions

    private var actionsCard: some View {
        VStack(spacing: 12) {
            if tab == .theme, store.hasDraft {
                TextField("Palette name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                Button("Save palette") { store.saveDraft(name: draftName); Haptics.success() }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Discard changes", role: .destructive) { store.discardDraft(); draftName = store.active.name }
                    .font(.subheadline)
            } else if tab == .theme, !store.isPreset(store.active.id) {
                Button(role: .destructive) { pendingDelete = store.active } label: { Label("Delete this palette", systemImage: "trash") }
                    .font(.subheadline)
            }
            Button("Reset to default…", role: .destructive) { confirmReset = true }
                .font(.footnote).foregroundStyle(Theme.inkSecondary)
        }
        .frame(maxWidth: .infinity)
        .glass(padding: 18)
    }
}

// MARK: - Pieces

private struct PaletteChip: View {
    let palette: ThemePalette
    let scheme: ColorScheme
    let selected: Bool

    var body: some View {
        let c = palette.colors(for: scheme)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: -6) {
                ForEach([c.background, c.surface, c.secondary, c.primary, c.accent], id: \.self) { hex in
                    Circle().fill(Color(hex: hex)).frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.black.opacity(0.14), lineWidth: 0.5))
                }
            }
            HStack(spacing: 4) {
                Text(palette.name).font(.footnote.weight(.medium)).foregroundStyle(Color(hex: c.text)).lineLimit(1)
                if selected { Image(systemName: "checkmark.circle.fill").font(.footnote).foregroundStyle(Theme.accent) }
            }
        }
        .padding(12)
        .frame(width: 142, alignment: .leading)
        .background(Color(hex: c.background), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(selected ? Theme.accent : Theme.cardLine, lineWidth: selected ? 2 : 0.75))
    }
}

/// A miniature of the real interface, drawn with the real tokens and glass, forced to light or dark.
private struct ThemePreview: View {
    let scheme: ColorScheme

    var body: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Available cash").font(.caption.weight(.medium)).foregroundStyle(Theme.onPrimary.opacity(0.74))
                Text("RM 12,480.00").font(.figure(30, weight: .light)).foregroundStyle(Theme.onPrimary)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(HeroBackground())

            HStack(spacing: 10) {
                StatTile(title: "Income", value: "RM 5,200", symbol: "arrow.down.left", tint: Theme.income)
                StatTile(title: "Expenses", value: "RM 653", symbol: "arrow.up.right")
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                RingGauge(value: 0.62, tint: Theme.accent, lineWidth: 6) {
                    Text("62%").font(.figure(11)).foregroundStyle(Theme.ink)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Groceries").font(.footnote.weight(.medium)).foregroundStyle(Theme.ink)
                    ProgressLine(value: 0.62, tint: Theme.accent, height: 4)
                }
                Text("Add").font(.footnote.weight(.semibold)).foregroundStyle(Theme.onPrimary)
                    .padding(.vertical, 8).padding(.horizontal, 16)
                    .background(Theme.primary, in: Capsule())
            }
            .glass(padding: 12, radius: 20)
        }
        .padding(14)
        .background(AmbientBackground())
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Theme.cardLine, lineWidth: 0.75))
        .environment(\.colorScheme, scheme)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live preview of the theme")
    }
}
