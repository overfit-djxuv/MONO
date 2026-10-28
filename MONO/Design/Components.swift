import SwiftUI

struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.line).frame(height: 0.5) }
}

struct SectionHeader: View {
    let title: String
    var trailing: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.inkSecondary)
            Spacer()
            if let trailing, let action {
                Button(trailing, action: action)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(PressableStyle())
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

struct Metric: View {
    let label: String
    let value: String
    var tint: Color = Theme.ink
    var footnote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.footnote).foregroundStyle(Theme.inkSecondary)
            Text(value)
                .font(.figure(20, weight: .regular))
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            if let footnote {
                Text(footnote).font(.caption).foregroundStyle(Theme.inkTertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Thin progress track. Animates once on first appearance and retargets smoothly afterwards.
struct ProgressLine: View {
    var value: Double
    var tint: Color = Theme.accent
    var height: CGFloat = 4
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var shown: Double = 0

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule().fill(tint).frame(width: max(g.size.width * min(max(shown, 0), 1), shown > 0 ? height : 0))
            }
        }
        .frame(height: height)
        .onAppear {
            if reduce { shown = value } else { withAnimation(Theme.easeOut(0.5)) { shown = value } }
        }
        .onChange(of: value) { _, new in
            withAnimation(reduce ? nil : Theme.easeOut(0.25)) { shown = new }
        }
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((min(value, 1) * 100).rounded())) percent")
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.inkTertiary)
            Text(title).font(.headline).foregroundStyle(Theme.ink)
            Text(message)
                .font(.subheadline).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Theme.accentSoft, in: Capsule())
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(PressableStyle())
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28).padding(.horizontal, 24)
    }
}

/// Inline note used for warnings and honest "no data" statements.
struct Callout: View {
    enum Tone { case info, warning, danger }
    let text: String
    var tone: Tone = .info
    var symbol: String? = nil

    private var color: Color {
        switch tone { case .info: Theme.inkSecondary; case .warning: Theme.warning; case .danger: Theme.danger }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol ?? (tone == .info ? "info.circle" : "exclamationmark.triangle"))
                .font(.footnote)
            Text(text).font(.footnote).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
        .padding(.vertical, 10).padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.radius))
    }
}

struct CategoryGlyph: View {
    let symbol: String
    var tint: Color = Theme.accent
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}

struct StatusChip: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

// MARK: - Amount input

struct AmountField: View {
    @Binding var text: String
    var placeholder = "0.00"
    /// The currency being typed; nil means the reporting currency. Decides the symbol and how many decimals are allowed.
    var currency: Currency? = nil

    private var cur: Currency { currency ?? Money.reporting }

    var body: some View {
        HStack(spacing: 8) {
            Text(currency == nil ? Money.symbol : cur.symbol).foregroundStyle(Theme.inkSecondary)
            TextField(cur.digits == 0 ? "0" : placeholder, text: $text)
                .keyboardType(cur.digits == 0 ? .numberPad : .decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.figure(17))
        }
        .onChange(of: text) { _, v in
            let s = Self.sanitize(v, digits: cur.digits)
            if s != v { text = s }
        }
    }

    static func sanitize(_ input: String, digits: Int = 2) -> String {
        var out = ""
        var seenDot = false
        var frac = 0
        var whole = 0
        for ch in input.replacingOccurrences(of: ",", with: ".") {
            if ch.isASCII && ch.isNumber {
                if seenDot { if frac < digits { out.append(ch); frac += 1 } }
                else if whole < 11 { out.append(ch); whole += 1 }
            } else if ch == "." && !seenDot && digits > 0 { seenDot = true; out.append(ch) }
        }
        return out
    }
}

// MARK: - Category helpers

extension Array where Element == MoneyCategory {
    func symbol(for name: String) -> String {
        first(where: { $0.name == name })?.symbol ?? "tag"
    }
}

let iconChoices = ["tag", "fork.knife", "cart", "car", "book", "bag", "film", "gamecontroller", "airplane",
                   "house", "heart", "cross.case", "gift", "wrench.and.screwdriver", "pawprint", "music.note",
                   "laptopcomputer", "graduationcap", "bicycle", "leaf"]

// MARK: - Date helpers

extension Date {
    var dayTitle: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Today" }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        return formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }
    var short: String { formatted(.dateTime.day().month(.abbreviated).year()) }
}

// MARK: - Error reporting

@Observable final class ErrorCenter {
    var message: String?
    func report(_ error: Error, doing action: String) {
        message = "\(action): \(error.localizedDescription)"
    }
}
