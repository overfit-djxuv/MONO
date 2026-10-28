import Foundation
import SwiftData

enum Persistence {
    static var storeDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "MONO", directoryHint: .isDirectory)
    }

    static var storeURL: URL { storeDirectory.appending(path: "MONO.store") }

    /// Opens the on-device store. Data never leaves the device; the directory uses iOS file protection
    /// (available after first unlock, so the store stays readable for background launches).
    static func makeContainer() throws -> ModelContainer {
        let fm = FileManager.default
        try fm.createDirectory(at: storeDirectory, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])

        #if DEBUG
        // UI tests pass `-MONOReset <token>`; the store is wiped once per distinct token so a relaunch
        // with the same arguments keeps its data.
        if let i = CommandLine.arguments.firstIndex(of: "-MONOReset") {
            let token = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "default"
            if UserDefaults.standard.string(forKey: "lastResetToken") != token {
                for suffix in ["", "-shm", "-wal"] { try? fm.removeItem(atPath: storeURL.path + suffix) }
                UserDefaults.standard.removeObject(forKey: DefaultCategories.seededKey)
                UserDefaults.standard.removeObject(forKey: "openingBalanceCents")
                UserDefaults.standard.set(token, forKey: "lastResetToken")
            }
        }
        #endif

        let schema = Schema(AppSchema.models)
        let config = ModelConfiguration(schema: schema, url: storeURL)
        return try ModelContainer(for: schema, configurations: [config])
    }

    static func inMemoryContainer() throws -> ModelContainer {
        let schema = Schema(AppSchema.models)
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }
}
