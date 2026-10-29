import SwiftUI
import PhotosUI
import VisionKit

struct ReceiptDraft {
    var image: UIImage
    var parsed = ParsedReceipt()
    var ocrText = ""
    var language: ScanLanguage = .auto
    var notice: String?
}

/// Choose how to capture a receipt, read it on this iPhone, then review before anything is saved.
struct ReceiptScanFlow: View {
    var autoCamera = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage("receiptLanguage") private var languageRaw = ScanLanguage.auto.rawValue
    @State private var picked: PhotosPickerItem?
    @State private var showCamera = false
    @State private var working = false
    @State private var draft: ReceiptDraft?
    @State private var error: String?

    private var language: ScanLanguage { ScanLanguage(rawValue: languageRaw) ?? .auto }

    var body: some View {
        NavigationStack {
            Group {
                if let draft {
                    ReceiptEditorView(draft: draft, receipt: nil, onFinish: { dismiss() })
                } else { chooser }
            }
            .navigationTitle(draft == nil ? "Scan a receipt" : "Review receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { if draft == nil { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } } }
        }
        .fullScreenCover(isPresented: $showCamera) { DocumentScanner { img in showCamera = false; if let img { process(img) } }.ignoresSafeArea() }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { process(img) }
                else { error = "That photo couldn’t be opened." }
                picked = nil
            }
        }
        .onAppear { if autoCamera && VNDocumentCameraViewController.isSupported && draft == nil { showCamera = true } }
        .interactiveDismissDisabled(working)
    }

    private var chooser: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Receipt language")
                    Picker("Language", selection: $languageRaw) { ForEach(ScanLanguage.allCases) { Text($0.label).tag($0.rawValue) } }
                        .pickerStyle(.menu).tint(Theme.accent)
                    Text(language.canRead
                         ? "Automatic reads English, Spanish and Malay. Picking the exact language is more accurate."
                         : "Apple’s text recognition can’t read Burmese. MONO keeps the photo and you type the shop, date and total yourself.")
                        .font(.footnote).foregroundStyle(Theme.inkSecondary)
                }.glass(padding: 18)

                if let error { Callout(text: error, tone: .danger, symbol: "exclamationmark.triangle") }

                VStack(spacing: 12) {
                    if VNDocumentCameraViewController.isSupported {
                        Button { showCamera = true } label: { Label("Scan with camera", systemImage: "doc.viewfinder") }
                            .buttonStyle(PrimaryButtonStyle()).disabled(working)
                    } else {
                        Callout(text: "The camera scanner isn’t available on this device. You can still choose a photo.", tone: .info, symbol: "camera.slash")
                    }
                    PhotosPicker(selection: $picked, matching: .images) { Label("Choose from Photos", systemImage: "photo") }
                        .font(.subheadline.weight(.medium)).foregroundStyle(Theme.accent).disabled(working)
                }
                if working { ProgressView("Reading the receipt on this iPhone…").font(.footnote).padding(.top, 8) }

                Text("Photos and text stay on this iPhone. Nothing is uploaded, and reading works offline.")
                    .font(.footnote).foregroundStyle(Theme.inkSecondary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.gutter).padding(.vertical, 8)
        }.monoScreen()
    }

    private func process(_ image: UIImage) {
        error = nil; working = true
        let lang = language
        Task {
            var d = ReceiptDraft(image: image, language: lang)
            if lang.canRead {
                do {
                    let r = try await ReceiptOCR.recognize(image, language: lang)
                    d.ocrText = r.text
                    d.parsed = ReceiptParser.parse(lines: r.lines)
                    if r.lines.isEmpty { d.notice = "No text was found in this photo. You can type the details yourself." }
                } catch { d.notice = "Reading the photo failed. You can type the details yourself." }
            } else { d.notice = "Burmese receipts aren’t read automatically. Enter the details below; the photo is kept." }
            working = false
            draft = d
        }
    }
}
