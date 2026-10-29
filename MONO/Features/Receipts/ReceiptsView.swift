import SwiftUI
import SwiftData

/// Every saved receipt, searchable by shop, note or any text read from the photo.
struct ReceiptsView: View {
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @Query(sort: \Receipt.date, order: .reverse) private var receipts: [Receipt]
    @State private var search = ""
    @State private var scanning = false
    @State private var pendingDelete: Receipt?
    #if DEBUG
    @State private var openFirst = CommandLine.arguments.contains("-MONOOpenReceipt")
    #endif

    private var shown: [Receipt] {
        let q = ReceiptParser.fold(search).lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return receipts }
        return receipts.filter { r in [r.merchant, r.notes, r.category, r.ocrText].contains { ReceiptParser.fold($0).lowercased().contains(q) } }
    }

    var body: some View {
        List {
            Group {
                if receipts.isEmpty {
                    Section { VStack(spacing: 10) {
                        Image(systemName: "doc.text.viewfinder").font(.system(size: 32, weight: .light)).foregroundStyle(Theme.inkTertiary)
                        Text("No receipts yet").font(.headline)
                        Text("Scan a paper receipt or pick a photo. MONO reads it on this iPhone, you check it, then choose what to do with it.")
                            .font(.footnote).foregroundStyle(Theme.inkSecondary).multilineTextAlignment(.center)
                        Button { scanning = true } label: { Label("Scan a receipt", systemImage: "plus") }.buttonStyle(PrimaryButtonStyle()).padding(.top, 6)
                    }.frame(maxWidth: .infinity).padding(.vertical, 12) }
                } else {
                    Section {
                        ForEach(shown) { r in
                            NavigationLink { ReceiptEditorView(draft: nil, receipt: r, onFinish: {}).id(r.id) } label: { row(r) }
                                .swipeActions { Button("Delete", role: .destructive) { pendingDelete = r } }
                        }
                        if shown.isEmpty { Text("No receipts match “\(search)”.").font(.subheadline).foregroundStyle(Theme.inkSecondary) }
                    } footer: { Text("\(receipts.count) \(receipts.count == 1 ? "receipt" : "receipts") · photos are stored privately on this iPhone and included in backups.") }
                }
            }.listRowBackground(GlassRowBackground())
        }
        .scrollContentBackground(.hidden).monoScreen()
        .searchable(text: $search, prompt: "Shop, note or text on the receipt")
        .navigationTitle("Receipts").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button { scanning = true } label: { Image(systemName: "plus") }.accessibilityLabel("Scan a receipt") } }
        .sheet(isPresented: $scanning) { ReceiptScanFlow() }
        #if DEBUG
        .navigationDestination(isPresented: $openFirst) { if let r = receipts.first { ReceiptEditorView(draft: nil, receipt: r, onFinish: {}) } }
        #endif
        .confirmationDialog("Delete this receipt?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete receipt and photo", role: .destructive) {
                if let r = pendingDelete { ReceiptStore.delete(r.imageFile); context.delete(r); do { try context.save() } catch { errors.report(error, doing: "Couldn’t delete") } }
                pendingDelete = nil
            }
        } message: { Text("A linked transaction is kept.") }
    }

    private func row(_ r: Receipt) -> some View {
        HStack(spacing: 12) {
            Group {
                if let img = ReceiptStore.thumbnail(r.imageFile, maxPixel: 120) { Image(uiImage: img).resizable().scaledToFill() }
                else { Image(systemName: "doc.text").foregroundStyle(Theme.inkTertiary) }
            }.frame(width: 44, height: 56).background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(r.merchant.isEmpty ? "Untitled receipt" : r.merchant).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(1)
                HStack(spacing: 6) {
                    Text(r.date.formatted(date: .abbreviated, time: .omitted))
                    if r.transactionID != nil { Image(systemName: "link") }
                    if r.needsReview { Text("Check").foregroundStyle(Theme.warning) }
                }.font(.caption).foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            if r.totalCents > 0 { Text(Money.format(r.totalCents, currency: Currency.find(r.currencyCode.isEmpty ? Money.reporting.code : r.currencyCode))).font(.subheadline).foregroundStyle(Theme.ink) }
        }
    }
}
