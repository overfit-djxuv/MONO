import Foundation
import LocalAuthentication
import Observation

/// Optional Face ID / passcode lock. Uses the device owner policy, so it falls back to the iPhone passcode.
/// That policy needs a passcode to exist: without one the lock cannot be turned on.
@MainActor @Observable
final class AppLock {
    static let enabledKey = "appLockEnabled"

    private(set) var isLocked: Bool
    private var inFlight = false

    init(enabled: Bool = UserDefaults.standard.bool(forKey: AppLock.enabledKey)) {
        isLocked = enabled
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// nil if the lock can be used, otherwise why not.
    static func unavailableReason() -> String? {
        var error: NSError?
        if LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) { return nil }
        if error?.code == LAError.passcodeNotSet.rawValue {
            return "Set a passcode on your iPhone first (Settings ▸ Face ID & Passcode), then turn this on."
        }
        return "This iPhone can’t verify you right now: \(error?.localizedDescription ?? "unknown reason")."
    }

    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    func lockIfEnabled() {
        if isEnabled { isLocked = true }
    }

    func unlock() async {
        guard isLocked, !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        if await Self.authenticate(reason: "Unlock MONO") { isLocked = false }
    }

    /// Called when the setting is switched off, so a stale locked state can't linger.
    func clear() { isLocked = false }
}
