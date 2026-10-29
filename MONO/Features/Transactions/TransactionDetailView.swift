import SwiftUI
import SwiftData

/// One transaction, read-first: what it is, where it sits, its receipt, and the safe ways to change it.
struct TransactionDetailView: View {
    let tx: TransactionRecord
    let directory: AccountDirectory
    let symbol: String
    var isDuplicate = false
    var receipt: Receipt?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(ErrorCenter.self) private var errors
    @Query private var items: [ShoppingItem]
    @Query private var planned: [PlannedExpense]
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var showReceipt = false
    @State private var scanning = false

    private var from: Account? { directory.account(tx.accountID) }
    private var to: Account? { tx.toAccountID.flatMap { directory.byID[$0] } }
    private var currency: Currency { directory.currency(of: tx) }

    private var heading: String {
        if tx.kind == .transfer { return tx.title.isEmpty ? "Transfer" : tx.title }
        if !tx.merchant.isEmpty { return tx.merchant }
        return tx.title.isEmpty ? tx.category : tx.title
    }
    private var amountText: String {
        switch tx.kind {
        case .income: Money.format(tx.amountCents, signed: true, currency: currency)
        case .expense: Money.format(-tx.amountCents, signed: true, currency: currency)
        case .transfer: Money.format(tx.amountCents, currency: currency)
        }
    }
    private var caption: String {
        switch tx.kind {
        case .expense: "Expense · \(tx.category)"
        case .income: "Income · \(tx.category)"
        case .transfer: "Transfer · not counted as income or spending"
        }
    }

    private struct Line: Identifiable { let id = UUID(); let key: String; let value: String }
    private var lines: [Line] {
        var l = [Line(key: "Date", value: tx.date.formatted(date: .abbreviated, time: .shortened))]
        if tx.kind == .transfer {
            l.append(Line(key: "From", value: from?.name ?? "—"))
            l.append(Line(key: "To", value: to?.name ?? "—"))
            if let to, to.currencyCode != from?.currencyCode { l.append(Line(key: "Received", value: Money.format(tx.toAmountCents, currency: to.currency))) }
        } else {
            if let from { l.append(Line(key: "Account", value: from.name)) }
            l.append(Line(key: "Category", value: tx.category))
            if !tx.merchant.isEmpty, !tx.title.isEmpty { l.append(Line(key: "Description", value: tx.title)) }
            let tags = Tags.list(from: tx.tags)
            if !tags.isEmpty { l.append(Line(key: "Tags", value: tags.map { "#\($0)" }.joined(separator: " "))) }
        }
        if !tx.notes.isEmpty { l.append(Line(key: "Notes", value: tx.notes)) }
        return l
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(caption).font(.footnote).foregroundStyle(Theme.inkSecondary)
                    Text(heading).font(.title2.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text(amountText).font(.figure(40, weight: .semibold))
                        .foregroundStyle(tx.kind == .income ? Theme.income : Theme.ink).lineLimit(1).minimumScaleFactor(0.6)
                        .padding(.top, 4)
                }
                if isDuplicate {
                    Callout(text: "Another \(tx.kind == .income ? "income" : "expense") with the same amount, name and day exists. If it was entered twice, delete one.", tone: .warning, symbol: "doc.on.doc")
                }
                VStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                        HStack(alignment: .firstTextBaseline) {
                            Text(line.key).foregroundStyle(Theme.inkSecondary)
                            Spacer(minLength: 16)
                            Text(line.value).foregroundStyle(Theme.ink).multilineTextAlignment(.trailing)
                        }
                        .font(.subheadline).padding(.vertical, 13)
                        if i < lines.count - 1 { Hairline() }
                    }
                }
                .surface()
                if let receipt { receiptCard(receipt) } else if tx.kind != .transfer {
                    Button { scanning = true } label: { Label("Attach a receipt", systemImage: "doc.viewfinder").font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(PressableStyle()).foregroundStyle(Theme.accent).surface(padding: 4).accessibilityIdentifier("attachReceiptDetail")
                }
                VStack(spacing: 6) {
                    Button("Repeat for today") {
                        do { try Ledger.repeatTransaction(tx, in: context); Haptics.success() } catch { errors.report(error, doing: "Couldn’t repeat") }
                    }.font(.body.weight(.medium)).foregroundStyle(Theme.accent).frame(minHeight: 44)
                    Button("Delete transaction", role: .destructive) { confirmDelete = true }.font(.body).frame(minHeight: 44)
                    Text("You’ll be asked to confirm. A receipt stays in your library.").font(.caption).foregroundStyle(Theme.inkTertiary)
                }
                .frame(maxWidth: .infinity).buttonStyle(PressableStyle())
            }
            .padding(.horizontal, Theme.gutter).padding(.top, 4).padding(.bottom, 40)
        }
        .monoScreen()
        .navigationTitle("Details").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editing = true }.accessibilityIdentifier("editTransaction") } }
        .sheet(isPresented: $editing) { TransactionForm(editing: tx) }
        .sheet(isPresented: $scanning) {
            ReceiptScanFlow { d in
                do {
                    try ReceiptStore.saveDraft(d, transactionID: tx.id, merchant: tx.merchant.isEmpty ? d.parsed.merchant : tx.merchant, date: tx.date,
                                               totalCents: d.parsed.totalCents ?? tx.amountCents, taxCents: d.parsed.taxCents ?? 0,
                                               currencyCode: currency.code, category: tx.category, in: context)
                    try context.save(); Haptics.success()
                } catch { errors.report(error, doing: "Couldn’t attach the receipt") }
            }
        }
        .sheet(isPresented: $showReceipt) { if let receipt { NavigationStack { ReceiptEditorView(draft: nil, receipt: receipt, onFinish: { showReceipt = false }) } } }
        .confirmationDialog("Delete this transaction?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                do { try Ledger.delete(tx, items: items, planned: planned, in: context); Haptics.tap(); dismiss() }
                catch { errors.report(error, doing: "Couldn’t delete") }
            }
        } message: { Text("\(heading) · \(amountText). Balances update immediately.") }
    }

    private func receiptCard(_ r: Receipt) -> some View {
        Button { showReceipt = true } label: {
            HStack(spacing: 14) {
                Group {
                    if let img = ReceiptStore.thumbnail(r.imageFile, maxPixel: 160) { Image(uiImage: img).resizable().scaledToFill() }
                    else { Image(systemName: "doc.text").foregroundStyle(Theme.inkTertiary) }
                }
                .frame(width: 52, height: 68).background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Receipt attached").font(.body.weight(.medium)).foregroundStyle(Theme.ink)
                    Text(r.totalCents == tx.amountCents ? "Total matches this transaction" : "Receipt total \(Money.format(r.totalCents, currency: Currency.find(r.currencyCode.isEmpty ? Money.reporting.code : r.currencyCode)))")
                        .font(.footnote).foregroundStyle(r.totalCents == tx.amountCents ? Theme.inkSecondary : Theme.warning)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Theme.inkTertiary)
            }
            .surface(padding: 12)
        }
        .buttonStyle(PressableStyle())
    }
}
