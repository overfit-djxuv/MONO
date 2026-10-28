import SwiftUI
import UIKit

struct AppIconView: View {
    @Environment(ErrorCenter.self) private var errors
    @State private var choice = AppIconChoice(alternateName: UIApplication.shared.alternateIconName)
    @State private var applying = false

    private var supported: Bool { UIApplication.shared.supportsAlternateIcons }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                preview
                section("Style") {
                    HStack(spacing: 12) {
                        ForEach(IconStyle.allCases) { style in
                            let option = AppIconChoice(style: style, color: choice.color)
                            Button { select(option) } label: {
                                VStack(spacing: 8) {
                                    IconArtwork(name: option.previewName, size: 76)
                                        .overlay(selectionRing(choice.style == style, size: 76))
                                    VStack(spacing: 1) {
                                        Text(style.label).font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink)
                                        Text(style.detail).font(.caption2).foregroundStyle(Theme.inkSecondary)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityLabel("\(style.label), \(style.detail)")
                            .accessibilityAddTraits(choice.style == style ? .isSelected : [])
                        }
                    }
                }
                section("Colour") {
                    HStack(spacing: 12) {
                        ForEach(IconColor.allCases) { color in
                            Button { select(AppIconChoice(style: choice.style, color: color)) } label: {
                                VStack(spacing: 8) {
                                    Circle().fill(LinearGradient(colors: [color.swatch.opacity(0.75), color.swatch],
                                                                 startPoint: .top, endPoint: .bottom))
                                        .frame(width: 44, height: 44)
                                        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.8))
                                        .padding(4)
                                        .overlay(Circle().strokeBorder(choice.color == color ? Theme.ink.opacity(0.85) : .clear, lineWidth: 2))
                                    Text(color.label).font(.caption).foregroundStyle(choice.color == color ? Theme.ink : Theme.inkSecondary)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityLabel(color.label)
                            .accessibilityAddTraits(choice.color == color ? .isSelected : [])
                        }
                    }
                }
                if !supported {
                    Callout(text: "This device can’t change the app icon.", tone: .warning)
                } else {
                    Text("iOS shows a short confirmation when the icon changes. Each style comes in light and dark versions that follow your iPhone’s appearance.")
                        .font(.footnote).foregroundStyle(Theme.inkSecondary).multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            }
            .padding(.horizontal, Theme.gutter).padding(.vertical, 8).padding(.bottom, 24)
        }
        .monoScreen()
        .navigationTitle("App icon")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(applying)
    }

    private var preview: some View {
        VStack(spacing: 12) {
            IconArtwork(name: choice.previewName, size: 132)
                .shadow(color: .black.opacity(0.28), radius: 22, y: 12)
                .animation(Theme.easeOut(0.25), value: choice)
            Text(choice.label).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity)
        .glass(padding: 22, radius: 28)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: title)
            content()
        }
        .glass(padding: 18)
    }

    private func selectionRing(_ on: Bool, size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
            .strokeBorder(on ? Theme.ink.opacity(0.85) : .clear, lineWidth: 2.5).padding(-4)
    }

    private func select(_ new: AppIconChoice) {
        guard new != choice, supported else { return }
        let old = choice
        choice = new
        Haptics.tap()
        applying = true
        Task {
            defer { applying = false }
            do { try await UIApplication.shared.setAlternateIconName(new.alternateName) }
            catch { choice = old; errors.report(error, doing: "Couldn’t change the icon") }
        }
    }
}

/// An app-icon image with the iOS corner shape.
struct IconArtwork: View {
    let name: String
    let size: CGFloat
    var body: some View {
        Image(name).resizable().scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.6))
    }
}
