import SwiftUI
import PhotosUI
import VisionKit

/// Apple's document scanner: finds the receipt's edges, flattens it and can take several pages for a long receipt.
struct DocumentScanner: UIViewControllerRepresentable {
    var onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController(); vc.delegate = context.coordinator; return vc
    }
    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onFinish) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: (UIImage?) -> Void
        init(_ f: @escaping (UIImage?) -> Void) { onFinish = f }
        func documentCameraViewController(_ c: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onFinish(ReceiptImages.stack((0..<scan.pageCount).map { scan.imageOfPage(at: $0) }))
        }
        func documentCameraViewControllerDidCancel(_ c: VNDocumentCameraViewController) { onFinish(nil) }
        func documentCameraViewController(_ c: VNDocumentCameraViewController, didFailWithError error: Error) { onFinish(nil) }
    }
}

enum ReceiptImages {
    /// Joins pages top to bottom at one width, so a long receipt scanned in pieces reads as one.
    static func stack(_ pages: [UIImage]) -> UIImage? {
        guard let first = pages.first else { return nil }
        guard pages.count > 1 else { return first }
        let width = first.size.width
        let heights = pages.map { $0.size.height * width / $0.size.width }
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: heights.reduce(0, +)), format: fmt).image { _ in
            var y: CGFloat = 0
            for (p, h) in zip(pages, heights) { p.draw(in: CGRect(x: 0, y: y, width: width, height: h)); y += h }
        }
    }
}

/// Full-screen, pinch-to-zoom view of a receipt photo.
struct ReceiptPhotoViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: UIScreen.main.bounds.width * max(1, zoom * pinch))
            }
            .gesture(MagnifyGesture().updating($pinch) { v, s, _ in s = v.magnification }.onEnded { zoom = min(max(1, zoom * $0.magnification), 5) })
            .background(Color.black.opacity(0.92).ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
