import Foundation
import UIKit
import Vision

/// The language you tell MONO to expect on a receipt.
enum ScanLanguage: String, CaseIterable, Identifiable {
    case auto, en, es, ms, my
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Automatic"
        case .en: "English"
        case .es: "Español"
        case .ms: "Bahasa Melayu"
        case .my: "Burmese (photo only)"
        }
    }
    /// Burmese isn't supported by Apple's text recognition, so for it the photo is kept and you type the details.
    var canRead: Bool { self != .my }
    var visionLanguages: [String] {
        switch self {
        case .auto: ["en-US", "es-ES", "ms-MY"]
        case .en: ["en-US"]
        case .es: ["es-ES"]
        case .ms: ["ms-MY"]
        case .my: []
        }
    }
}

struct OCRBox: Equatable { var text: String; var minX: CGFloat; var midY: CGFloat; var height: CGFloat }

enum ReceiptOCR {
    enum OCRError: LocalizedError {
        case unreadable, unsupported
        var errorDescription: String? {
            switch self {
            case .unreadable: "The photo couldn’t be read."
            case .unsupported: "This language can’t be read automatically. The photo is kept and you can type the details."
            }
        }
    }

    /// Joins text fragments that sit on the same printed row (an item name on the left, its price on the right) into one line, top to bottom.
    static func rows(_ boxes: [OCRBox]) -> [String] {
        var rows: [[OCRBox]] = []
        for b in boxes.sorted(by: { $0.midY > $1.midY }) {
            if let i = rows.indices.last(where: { abs(rows[$0][0].midY - b.midY) < max(b.height, rows[$0][0].height) * 0.6 }) { rows[i].append(b) } else { rows.append([b]) }
        }
        return rows.map { $0.sorted { $0.minX < $1.minX }.map(\.text).joined(separator: "  ") }
    }

    /// Languages Apple's recogniser supports on this device, intersected with what was asked for.
    static func languages(for lang: ScanLanguage) -> [String] {
        let supported = Set((try? VNRecognizeTextRequest(completionHandler: nil).supportedRecognitionLanguages()) ?? [])
        let wanted = lang.visionLanguages.filter { supported.contains($0) }
        return wanted.isEmpty ? ["en-US"] : wanted
    }

    /// Reads the text on-device. Nothing is sent anywhere.
    static func recognize(_ image: UIImage, language: ScanLanguage) async throws -> (lines: [String], text: String) {
        guard language.canRead else { throw OCRError.unsupported }
        guard let cg = image.cgImage else { throw OCRError.unreadable }
        let langs = languages(for: language)
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false   // correction "fixes" prices and abbreviations into words
                request.recognitionLanguages = langs
                let handler = VNImageRequestHandler(cgImage: cg, orientation: CGImagePropertyOrientation(image.imageOrientation), options: [:])
                do {
                    try handler.perform([request])
                    let boxes = (request.results ?? []).compactMap { o -> OCRBox? in
                        guard let t = o.topCandidates(1).first?.string else { return nil }
                        return OCRBox(text: t, minX: o.boundingBox.minX, midY: o.boundingBox.midY, height: o.boundingBox.height)
                    }
                    let lines = rows(boxes)
                    cont.resume(returning: (lines, lines.joined(separator: "\n")))
                } catch { cont.resume(throwing: error) }
            }
        }
    }
}

extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
