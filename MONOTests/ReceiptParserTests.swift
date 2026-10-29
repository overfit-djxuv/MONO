import XCTest
import SwiftData
@testable import MONO

final class ReceiptParserTests: XCTestCase {
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 12))!
    private func day(_ d: Date?) -> String { d.map { let c = Calendar.current.dateComponents([.year, .month, .day], from: $0); return "\(c.year!)-\(c.month!)-\(c.day!)" } ?? "nil" }

    func testAmountFormats() {
        XCTAssertEqual(ReceiptParser.parseAmount("12.50"), 1250)
        XCTAssertEqual(ReceiptParser.parseAmount("12,50"), 1250)
        XCTAssertEqual(ReceiptParser.parseAmount("1,234.50"), 123450)
        XCTAssertEqual(ReceiptParser.parseAmount("1.234,50"), 123450)
        XCTAssertEqual(ReceiptParser.parseAmount("25.000"), 2_500_000, "three digits after a separator is a thousands mark")
        XCTAssertEqual(ReceiptParser.parseAmount("7,5"), 750)
        XCTAssertEqual(ReceiptParser.parseAmount("1,234,567.89"), 123456789)
        XCTAssertEqual(ReceiptParser.parseAmount("1250", digits: 0), 1250)
    }
    func testAmountsIgnorePercentagesAndPhoneNumbers() {
        XCTAssertEqual(ReceiptParser.amounts(in: "SST 6.00% 1.20").map(\.cents), [120])
        XCTAssertTrue(ReceiptParser.amounts(in: "Tel 0312345678").isEmpty)
    }

    func testEnglishReceipt() {
        let p = ReceiptParser.parse(lines: ["Village Grocer", "Tel: 03-1234 5678", "Date: 12/10/2026 14:03",
            "Milk 1L            RM 7.90", "2 x Bread          RM 9.00", "Subtotal           RM 16.90", "SST 6%             RM 1.01",
            "TOTAL              RM 17.91", "Cash               RM 20.00", "Change             RM 2.09"], now: now)
        XCTAssertEqual(p.merchant, "Village Grocer")
        XCTAssertEqual(p.totalCents, 1791)
        XCTAssertEqual(p.taxCents, 101)
        XCTAssertEqual(p.currencyCode, "MYR")
        XCTAssertEqual(day(p.date), "2026-10-12")
        XCTAssertTrue(p.uncertain.contains(.date), "12/10 could be 12 Oct or Dec 10; flag it")
        XCTAssertEqual(p.items.map(\.name), ["Milk 1L", "Bread"])
    }
    func testSpanishReceipt() {
        let p = ReceiptParser.parse(lines: ["Supermercado Sol", "Fecha: 5 de marzo de 2026", "Pan   1,20", "Leche   0,95", "IVA 10%   0,22", "TOTAL A PAGAR   2,37 €"], now: now)
        XCTAssertEqual(p.merchant, "Supermercado Sol")
        XCTAssertEqual(day(p.date), "2026-3-5")
        XCTAssertFalse(p.uncertain.contains(.date))
        XCTAssertEqual(p.totalCents, 237)
        XCTAssertEqual(p.taxCents, 22)
        XCTAssertEqual(p.currencyCode, "EUR")
    }
    func testMalayReceipt() {
        let p = ReceiptParser.parse(lines: ["KEDAI RUNCIT AMAN", "Tarikh: 03 Mei 2026", "Nasi Lemak   RM 5.50", "Teh Tarik   RM 2.00", "Jumlah Kecil   RM 7.50", "Cukai SST   RM 0.45", "Jumlah Besar   RM 7.95"], now: now)
        XCTAssertEqual(p.merchant, "KEDAI RUNCIT AMAN")
        XCTAssertEqual(day(p.date), "2026-5-3")
        XCTAssertEqual(p.totalCents, 795)
        XCTAssertEqual(p.taxCents, 45)
    }
    func testTotalOnTheNextLineAndDecimalComma() {
        let p = ReceiptParser.parse(lines: ["Cafe Luna", "2026-02-14", "Total", "1.234,50"], now: now)
        XCTAssertEqual(p.totalCents, 123450)
    }
    func testNoTotalLineFallsBackToLargestAmountAndSaysSo() {
        let p = ReceiptParser.parse(lines: ["Corner Shop", "Item A 3.00", "Item B 4.50"], now: now)
        XCTAssertEqual(p.totalCents, 450)
        XCTAssertTrue(p.uncertain.contains(.total))
    }
    func testGarbageProducesNothingConfidentNotACrash() {
        let p = ReceiptParser.parse(lines: ["", "@@##", "12"], now: now)
        XCTAssertNil(p.totalCents); XCTAssertNil(p.date); XCTAssertTrue(p.uncertain.isSuperset(of: [.date, .total, .merchant]))
    }
    func testFutureAndImpossibleDatesAreRejected() {
        XCTAssertNil(ReceiptParser.findDate(in: ["31/02/2026"], now: now))
        XCTAssertNil(ReceiptParser.findDate(in: ["01/01/2030"], now: now))
        XCTAssertEqual(day(ReceiptParser.findDate(in: ["10/25/2026"], now: now)?.date), "2026-10-25", "second number above 12 can only be the day")
    }
    func testBareDollarSignIsNeverGuessed() {
        XCTAssertNil(ReceiptParser.findCurrency(in: "Total $12.00"))
        XCTAssertEqual(ReceiptParser.findCurrency(in: "Total RM12.00"), "MYR")
    }

    func testDuplicateDetection() {
        let d = now
        let e = ReceiptMatcher.Existing(id: UUID(), merchant: "Village Grocer", date: d, totalCents: 1791, hash: "abc")
        XCTAssertNotNil(ReceiptMatcher.duplicate(of: ("village grocer", d, 1791, ""), in: [e]))
        XCTAssertNotNil(ReceiptMatcher.duplicate(of: ("", d, 0, "abc"), in: [e]), "same photo")
        XCTAssertNil(ReceiptMatcher.duplicate(of: ("Other", d, 1791, ""), in: [e]))
        XCTAssertNil(ReceiptMatcher.duplicate(of: ("Village Grocer", d, 1792, ""), in: [e]))
    }
}

final class ReceiptOCRTests: XCTestCase {
    func testRowsJoinNameAndPriceOnTheSamePrintedRow() {
        let boxes = [OCRBox(text: "RM 7.90", minX: 0.7, midY: 0.50, height: 0.02), OCRBox(text: "Milk 1L", minX: 0.1, midY: 0.505, height: 0.02),
                     OCRBox(text: "TOTAL", minX: 0.1, midY: 0.30, height: 0.02), OCRBox(text: "Shop", minX: 0.3, midY: 0.9, height: 0.03)]
        XCTAssertEqual(ReceiptOCR.rows(boxes), ["Shop", "Milk 1L  RM 7.90", "TOTAL"])
    }
    func testBurmeseIsPhotoOnlyAndThrowsClearly() async {
        XCTAssertFalse(ScanLanguage.my.canRead)
        do { _ = try await ReceiptOCR.recognize(UIImage(), language: .my); XCTFail() } catch { XCTAssertEqual(error as? ReceiptOCR.OCRError, .unsupported) }
    }
    func testRecognisesAnEnglishReceiptRenderedAsAnImage() async throws {
        let lines = ["VILLAGE GROCER", "Date: 2026-10-12", "Milk 1L          RM 7.90", "Bread            RM 9.00", "TOTAL            RM 16.90"]
        let size = CGSize(width: 900, height: 700)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            for (i, l) in lines.enumerated() {
                (l as NSString).draw(at: CGPoint(x: 40, y: 40 + CGFloat(i) * 110), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 56, weight: .regular), .foregroundColor: UIColor.black])
            }
        }
        let result = try await ReceiptOCR.recognize(img, language: .en)
        let parsed = ReceiptParser.parse(lines: result.lines)
        XCTAssertEqual(parsed.totalCents, 1690, "OCR text was: \(result.text)")
        XCTAssertEqual(parsed.currencyCode, "MYR")
    }
}

final class ReceiptBackupTests: XCTestCase {
    @MainActor func testReceiptsAndTheirPhotosSurviveBackupWipeAndRestore() throws {
        let container = try Persistence.inMemoryContainer(); let ctx = ModelContext(container)
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 120)).image { UIColor.red.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 80, height: 120)) }
        let bytes = try XCTUnwrap(ReceiptStore.prepared(photo))
        let file = try ReceiptStore.store(bytes)
        defer { ReceiptStore.delete(file) }
        let r = Receipt(); r.merchant = "Shop"; r.totalCents = 1234; r.currencyCode = "MYR"; r.imageFile = file; r.imageHash = ReceiptStore.hash(bytes); r.ocrText = "TOTAL 12.34"
        ctx.insert(r); try ctx.save()

        let items = ReceiptStore.backupItems(context: ctx, includePhotos: true)
        XCTAssertEqual(items.first?.imageData, bytes)
        XCTAssertNil(ReceiptStore.backupItems(context: ctx, includePhotos: false).first?.imageData, "photos can be left out")

        var backup = try BackupService.snapshot(context: ctx, openingBalanceCents: 0, currencySymbol: "RM")
        backup.receipts = items
        XCTAssertTrue(BackupVault.testRestore(backup).ok)

        // Wipe the photo and the records, then restore from the file.
        ReceiptStore.delete(file); try ctx.delete(model: Receipt.self); try ctx.save()
        XCTAssertFalse(ReceiptStore.exists(file))
        try BackupService.replaceAll(with: backup, in: ctx)
        let back = try ctx.fetch(FetchDescriptor<Receipt>())
        XCTAssertEqual(back.map(\.merchant), ["Shop"]); XCTAssertEqual(back.first?.totalCents, 1234)
        XCTAssertEqual(ReceiptStore.data(file), bytes, "the photo is back, byte for byte")
    }
    @MainActor func testTestRestoreNeverTouchesRealPhotoFiles() throws {
        let file = try ReceiptStore.store(Data("keep".utf8)); defer { ReceiptStore.delete(file) }
        var backup = BackupFile()
        var d = BackupFile.ReceiptDTO(id: UUID(), createdAt: .now, merchant: "x", date: .now, totalCents: 1, taxCents: 0, currencyCode: "MYR", language: "en", category: "", notes: "", ocrText: "", itemsJSON: "", transactionID: nil, needsReview: false, imageFile: "other-\(UUID()).jpg", imageHash: "")
        d.imageData = Data("new".utf8); backup.receipts = [d]
        XCTAssertTrue(BackupVault.testRestore(backup).ok)
        XCTAssertFalse(ReceiptStore.exists(d.imageFile), "a dry run must not write photos")
        XCTAssertEqual(ReceiptStore.data(file), Data("keep".utf8), "and must not delete anything")
    }
}
