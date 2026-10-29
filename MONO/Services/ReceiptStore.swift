import Foundation
import SwiftData
import UIKit
import CryptoKit
import ImageIO

/// Receipt photos live as files in MONO's private storage (protected until first unlock); the Receipt record keeps the file name.
enum ReceiptStore {
    static var directory: URL { Persistence.storeDirectory.appending(path: "Receipts", directoryHint: .isDirectory) }
    static let maxPixels: CGFloat = 2000

    private static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    }

    // MARK: Images

    /// Redraws upright, caps the size so the library stays small, and encodes as JPEG.
    static func prepared(_ image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxPixels ? maxPixels / longest : 1
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
        let redrawn = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return redrawn.jpegData(compressionQuality: 0.72)
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Stores already-prepared JPEG data under a new name.
    static func store(_ data: Data, name: String = UUID().uuidString + ".jpg") throws -> String {
        try ensureDirectory()
        try data.write(to: directory.appending(path: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return name
    }

    static func data(_ file: String) -> Data? { file.isEmpty ? nil : try? Data(contentsOf: directory.appending(path: file)) }
    static func image(_ file: String) -> UIImage? { data(file).flatMap(UIImage.init(data:)) }
    static func exists(_ file: String) -> Bool { !file.isEmpty && FileManager.default.fileExists(atPath: directory.appending(path: file).path) }
    static func delete(_ file: String) { if !file.isEmpty { try? FileManager.default.removeItem(at: directory.appending(path: file)) } }

    private static let thumbs = NSCache<NSString, UIImage>()
    static func thumbnail(_ file: String, maxPixel: Int = 240) -> UIImage? {
        let key = "\(file)|\(maxPixel)" as NSString
        if let hit = thumbs.object(forKey: key) { return hit }
        guard !file.isEmpty, let src = CGImageSourceCreateWithURL(directory.appending(path: file) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: maxPixel] as CFDictionary) else { return nil }
        let img = UIImage(cgImage: cg); thumbs.setObject(img, forKey: key); return img
    }

    /// Removes photo files no receipt refers to (after a restore or an erase).
    static func pruneOrphans(context: ModelContext) {
        let keep = Set(((try? context.fetch(FetchDescriptor<Receipt>())) ?? []).map(\.imageFile))
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where !keep.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Backup

    static func backupItems(context: ModelContext, includePhotos: Bool) -> [BackupFile.ReceiptDTO] {
        ((try? context.fetch(FetchDescriptor<Receipt>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []).map { r in
            .init(id: r.id, createdAt: r.createdAt, merchant: r.merchant, date: r.date, totalCents: r.totalCents, taxCents: r.taxCents,
                  currencyCode: r.currencyCode, language: r.languageRaw, category: r.category, notes: r.notes, ocrText: r.ocrText,
                  itemsJSON: r.itemsJSON, transactionID: r.transactionID, needsReview: r.needsReview, imageFile: r.imageFile,
                  imageHash: r.imageHash, imageData: includePhotos ? data(r.imageFile) : nil)
        }
    }

    /// Creates the records (inside the caller's rollback-protected block). Photo files are written afterwards by `writePhotos`.
    static func insertRecords(_ items: [BackupFile.ReceiptDTO], into context: ModelContext) {
        for d in items {
            let r = Receipt(id: d.id)
            r.createdAt = d.createdAt; r.merchant = d.merchant; r.date = d.date; r.totalCents = d.totalCents; r.taxCents = d.taxCents
            r.currencyCode = d.currencyCode; r.languageRaw = d.language; r.category = d.category; r.notes = d.notes; r.ocrText = d.ocrText
            r.itemsJSON = d.itemsJSON; r.transactionID = d.transactionID; r.needsReview = d.needsReview; r.imageFile = d.imageFile; r.imageHash = d.imageHash
            context.insert(r)
        }
    }

    static func writePhotos(_ items: [BackupFile.ReceiptDTO]) {
        for d in items { if let bytes = d.imageData, !d.imageFile.isEmpty { _ = try? store(bytes, name: d.imageFile) } }
    }

    /// Saves a scanned receipt as a record plus its photo, optionally linked to a transaction. The caller saves the context.
    @discardableResult
    static func saveDraft(_ d: ReceiptDraft, transactionID: UUID?, merchant: String, date: Date, totalCents: Int, taxCents: Int = 0,
                          currencyCode: String, category: String, notes: String = "", needsReview: Bool = false,
                          in context: ModelContext) throws -> Receipt {
        guard let data = prepared(d.image) else { throw ReceiptOCR.OCRError.unreadable }
        let r = Receipt()
        r.imageFile = try store(data); r.imageHash = hash(data)
        r.ocrText = d.ocrText; r.languageRaw = d.language.rawValue
        r.itemsJSON = (try? JSONEncoder().encode(d.parsed.items)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        r.merchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines); r.date = date
        r.totalCents = totalCents; r.taxCents = taxCents; r.currencyCode = currencyCode; r.category = category; r.notes = notes
        r.needsReview = needsReview; r.transactionID = transactionID
        context.insert(r)
        return r
    }
}
