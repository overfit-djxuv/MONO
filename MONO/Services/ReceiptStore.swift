import Foundation
import SwiftData

/// Receipts and their photos. (Filled in with the scanner; the backup system calls this to include receipts.)
enum ReceiptStore {
    @MainActor
    static func backupItems(context: ModelContext, includePhotos: Bool) -> [BackupFile.ReceiptDTO] { [] }
}
