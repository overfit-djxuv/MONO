import Foundation

/// A settings value that can be written to a backup and read back with its type intact.
enum PrefValue: Codable, Equatable {
    case bool(Bool), int(Int), double(Double), string(String), data(Data)

    private enum Keys: String, CodingKey { case type, value }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "bool": self = .bool(try c.decode(Bool.self, forKey: .value))
        case "int": self = .int(try c.decode(Int.self, forKey: .value))
        case "double": self = .double(try c.decode(Double.self, forKey: .value))
        case "string": self = .string(try c.decode(String.self, forKey: .value))
        case "data": self = .data(try c.decode(Data.self, forKey: .value))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown setting type")
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .bool(let v): try c.encode("bool", forKey: .type); try c.encode(v, forKey: .value)
        case .int(let v): try c.encode("int", forKey: .type); try c.encode(v, forKey: .value)
        case .double(let v): try c.encode("double", forKey: .type); try c.encode(v, forKey: .value)
        case .string(let v): try c.encode("string", forKey: .type); try c.encode(v, forKey: .value)
        case .data(let v): try c.encode("data", forKey: .type); try c.encode(v, forKey: .value)
        }
    }
}

/// Which settings travel with a backup. A deliberate allow-list: nothing security-related (the Face ID lock, hide-amounts state,
/// notification permissions) and nothing about the backups themselves is ever written to or restored from a file.
enum PreferenceBackup {
    enum Kind { case bool, int, double, string, data }
    static let allowed: [String: Kind] = [
        "appearance": .int,
        "reportingCurrency": .string, "currencySymbol": .string, "openingBalanceCents": .int,
        "remindersEnabled": .bool, "reminderHour": .int, "hideAmountsOnLaunch": .bool,
        "hourlyIncomeCents": .int,
        "themeState.v1": .data, "safeToSpendConfig.v1": .data, "whatIfScenarios.v1": .data, "quickActions.v1": .data,
    ]

    static func capture(_ defaults: UserDefaults = .standard) -> [String: PrefValue] {
        var out: [String: PrefValue] = [:]
        for (key, kind) in allowed {
            guard let raw = defaults.object(forKey: key) else { continue }
            switch kind {
            case .bool: if let v = raw as? Bool { out[key] = .bool(v) }
            case .int: if let v = raw as? Int { out[key] = .int(v) }
            case .double: if let v = raw as? Double { out[key] = .double(v) }
            case .string: if let v = raw as? String { out[key] = .string(v) }
            case .data: if let v = raw as? Data { out[key] = .data(v) }
            }
        }
        return out
    }

    /// Writes only allow-listed keys whose type matches; anything else in a file is ignored. Then refreshes the in-memory stores.
    static func restore(_ prefs: [String: PrefValue], defaults: UserDefaults = .standard, refresh: Bool = true) {
        for (key, value) in prefs {
            guard let kind = allowed[key] else { continue }
            switch (kind, value) {
            case (.bool, .bool(let v)): defaults.set(v, forKey: key)
            case (.int, .int(let v)): defaults.set(v, forKey: key)
            case (.double, .double(let v)): defaults.set(v, forKey: key)
            case (.string, .string(let v)): defaults.set(v, forKey: key)
            case (.data, .data(let v)): defaults.set(v, forKey: key)
            default: continue
            }
        }
        if refresh { ThemeStore.shared.reload(); WhatIfStore.shared.reload() }
    }
}
