import SwiftUI
import UIKit

/// Turns a review into files you can share. PDF is drawn directly as text, so it needs no screenshot and stays sharp.
enum ReviewExport {
    static func pdf(title: String, markdown: String) -> Data {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842), margin: CGFloat = 48
        let body = NSMutableAttributedString()
        let para = NSMutableParagraphStyle(); para.lineSpacing = 3; para.paragraphSpacing = 4
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            var font = UIFont.systemFont(ofSize: 11), color = UIColor.black
            if line.hasPrefix("# ") { line = String(line.dropFirst(2)); font = .systemFont(ofSize: 22, weight: .semibold) }
            else if line.hasPrefix("## ") { line = String(line.dropFirst(3)); font = .systemFont(ofSize: 14, weight: .semibold) }
            else if line.hasPrefix("- ") { line = "•  " + line.dropFirst(2) }
            else if line.hasPrefix("_") && line.hasSuffix("_") { line = String(line.dropFirst().dropLast()); font = .italicSystemFont(ofSize: 9.5); color = .darkGray }
            body.append(NSAttributedString(string: line + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para]))
        }
        let setter = CTFramesetterCreateWithAttributedString(body)
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: { let f = UIGraphicsPDFRendererFormat(); f.documentInfo = [kCGPDFContextTitle as String: title]; return f }())
        return renderer.pdfData { ctx in
            var start = 0
            let area = page.insetBy(dx: margin, dy: margin)
            repeat {
                ctx.beginPage()
                let cg = ctx.cgContext
                cg.saveGState(); cg.translateBy(x: 0, y: page.height); cg.scaleBy(x: 1, y: -1)
                let path = CGPath(rect: CGRect(x: area.minX, y: margin, width: area.width, height: area.height), transform: nil)
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), path, nil)
                CTFrameDraw(frame, cg)
                cg.restoreGState()
                start += CTFrameGetVisibleStringRange(frame).length
            } while start < body.length
        }
    }

    /// Writes `data` to a temporary file with a readable name, ready for the share sheet.
    static func file(named name: String, data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}

/// The system share sheet (Files, AirDrop, Mail, Messages…).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct SharePayload: Identifiable { let id = UUID(); let items: [Any] }
