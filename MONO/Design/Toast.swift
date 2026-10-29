import SwiftUI

/// A short, quiet confirmation ("Expense saved") shown at the bottom of the screen after a successful action.
@MainActor @Observable
final class ToastCenter {
    static let shared = ToastCenter()
    private(set) var message: String?
    private var token = 0

    func show(_ text: String, seconds: Double = 1.8) {
        token += 1
        let mine = token
        message = text
        Task { try? await Task.sleep(for: .seconds(seconds)); if mine == token { message = nil } }
    }
}

struct ToastHost: ViewModifier {
    @State private var center = ToastCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let text = center.message {
                Label(text, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 16).frame(minHeight: 44)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Theme.line, lineWidth: 0.5))
                    .padding(.bottom, 96)
                    .transition(reduce ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
                    .allowsHitTesting(false)
            }
        }
        .animation(reduce ? .easeOut(duration: 0.15) : Theme.easeOut(0.28), value: center.message)
    }
}

extension View { func toastHost() -> some View { modifier(ToastHost()) } }
