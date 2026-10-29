import Foundation
import Observation

/// "Hide amounts", like the eye icon in a payment app. While on, every money figure is drawn as dots and charts are blurred.
/// It only changes what is drawn: no record, balance or calculation is affected.
@Observable
final class PrivacyStore {
    static let shared = PrivacyStore()
    static let mask = "••••"

    private static let hiddenKey = "hideAmounts"
    private static let onLaunchKey = "hideAmountsOnLaunch"
    private let defaults: UserDefaults

    private(set) var hidden: Bool
    private(set) var hideOnLaunch: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let onLaunch = defaults.bool(forKey: Self.onLaunchKey)
        hideOnLaunch = onLaunch
        // Opening the app hidden is a choice; otherwise it remembers how you left it.
        var start = onLaunch ? true : defaults.bool(forKey: Self.hiddenKey)
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "-MONOHidden"), i + 1 < CommandLine.arguments.count { start = CommandLine.arguments[i + 1] == "1" }
        #endif
        hidden = start
    }

    func setHidden(_ value: Bool) {
        hidden = value
        defaults.set(value, forKey: Self.hiddenKey)
    }

    func toggle() { setHidden(!hidden) }

    func setHideOnLaunch(_ value: Bool) {
        hideOnLaunch = value
        defaults.set(value, forKey: Self.onLaunchKey)
    }
}
