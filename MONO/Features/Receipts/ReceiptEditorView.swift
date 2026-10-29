import SwiftUI
import SwiftData

/// Review what was read from a receipt, correct it, and decide what it becomes: a new expense, a photo on an existing transaction, or just a saved receipt.
/// Also used to edit a receipt that is already saved.
struct ReceiptEditorView: View {
    let draft: ReceiptDraft?
    let receipt: Receipt?
    var onFinish: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @Query(sort: \MoneyCategory.sortOrder) private var categories: [MoneyCategory]
    @Query(sort: \Account.sortOrder) private var allAccounts: [Account]
    @Query(sort: \TransactionRecord.date, order: .reverse) private var txs: [TransactionRecord]
    @Query private var receipts: [Receipt]
    @AppStorage("lastAccountID") private var lastAccountID = ""

    @State private var merchant = ""
    @State private var date = Date()
    @State private var totalText = ""
    @State private var taxText = ""
    @State private var category = ""
    @State private var accountID: UUID?
    @State private var notes = ""
    @State private var uncertain: Set<ParsedReceipt.Field> = []
    @State private var loaded = false
    @State private var showPhoto = false
    @State private var showAttach = false
    @State private var confirmDuplicate = false
    @State private var confirmDelete = false
    @State private var showItems = false

    private var books: Books { Books(accounts: allAccounts, rates: [], transactions: [], entries: []) }
    private var account: Account? { books.account(accountID) ?? books.defaultAccount }
    private var currency: Currency { account?.currency ?? Money.reporting }
    private var total: Int? { Money.parse(totalText, currency: currency).flatMap { $0 > 0 ? $0 : nil } }
    private var tax: Int { Money.parse(taxText, currency: currency) ?? 0 }
    private var image: UIImage? { draft?.image ?? receipt.flatMap { ReceiptStore.image($0.imageFile) } }
    private var parsed: ParsedReceipt { draft?.parsed ?? ParsedReceipt() }
    private var items: [ReceiptItem] {
        if let d = draft { return d.parsed.items }
        return receipt.flatMap { $0.itemsJSON.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([ReceiptItem].self, from: $0) } ?? []
    }
    private var linked: TransactionRecord? { receipt?.transactionID.flatMap { id in txs.first { $0.id == id } } }
    private var expenseCategories: [MoneyCategory] { categories.filter { $0.kind == .expense } }

    private var duplicateReceipt: Receipt? {
        guard let total, draft != nil else { return nil }
        let existing = receipts.map { ReceiptMatcher.Existing(id: $0.id, merchant: $0.merchant, date: $0.date, totalCents: $0.totalCents, hash: $0.imageHash) }
        let hash = draft.flatMap { ReceiptStore.prepared($0.image) }.map(ReceiptStore.hash) ?? ""
        return ReceiptMatcher.duplicate(of: (merchant, date, total, hash), in: existing).flatMap { m in receipts.first { $0.id == m.id } }
    }
    private var duplicateTransaction: TransactionRecord? {
        guard let total, receipt?.transactionID == nil else { return nil }
        return Ledger.possibleDuplicate(kind: .expense, cents: total, date: date, title: merchant, merchant: merchant, accountID: account?.id,
                                        defaultAccountID: books.defaultAccount?.id, in: txs)
    }
    private var currencyMismatch: String? {
        guard let code = parsed.currencyCode, code != currency.code else { return nil }
        return "This receipt looks like \(code), but the account is in \(currency.code). Choose an account in \(code), or enter the amount in \(currency.code) yourself."
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let n = draft?.notice { Callout(text: n, tone: .warning, symbol: "text.viewfinder") }
                if let image { photo(image) }
                if let m = currencyMismatch { Callout(text: m, tone: .warning, symbol: "coloncurrencysign.circle") }
                if let dup = duplicateReceipt {
                    Callout(text: "You already saved a receipt that looks the same (\(dup.merchant.isEmpty ? "no name" : dup.merchant), \(dup.date.formatted(date: .abbreviated, time: .omitted))).", tone: .warning, symbol: "doc.on.doc")
                }
                fields
                if !items.isEmpty { itemsCard }
                actions
            }
            .padding(.horizontal, Theme.gutter).padding(.vertical, 8).padding(.bottom, 110)
        }
        .monoScreen()
        .navigationTitle(receipt == nil ? "Review receipt" : "Receipt")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .sheet(isPresented: $showPhoto) { if let image { ReceiptPhotoViewer(image: image) } }
        .sheet(isPresented: $showAttach) {
            AttachSheet(candidates: ReceiptMatcher.candidates(totalCents: total ?? 0, date: date, transactions: txs), currency: currency) { attach(to: $0) }
        }
        .confirmationDialog("Looks like a duplicate", isPresented: $confirmDuplicate, titleVisibility: .visible) {
            Button("Save anyway") { saveAsExpense(confirmed: true) }
        } message: {
            if let d = duplicateTransaction { Text("An expense for \(Money.format(d.amountCents, currency: currency)) on this day already exists (\(d.merchant.isEmpty ? d.title : d.merchant)). Attach the receipt to it instead, or save a second expense.") }
        }
        .confirmationDialog("Delete this receipt?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete receipt and photo", role: .destructive) { deleteReceipt() }
        } message: { Text("The linked transaction, if any, is kept.") }
    }

    // MARK: Pieces

    private func photo(_ image: UIImage) -> some View {
        Button { showPhoto = true } label: {
            Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 190).background(Color.white.opacity(0.06))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption).padding(8).background(.ultraThinMaterial, in: Circle()).padding(8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }.buttonStyle(PressableStyle()).accessibilityLabel("Receipt photo, tap to enlarge")
    }

    private func flag(_ f: ParsedReceipt.Field) -> some View {
        Group { if uncertain.contains(f) { Label("Check", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(Theme.warning) } }
    }

    private var fields: some View {
        VStack(spacing: 0) {
            HStack { TextField("Shop or merchant", text: $merchant).onChange(of: merchant) { _, _ in uncertain.remove(.merchant) }; flag(.merchant) }.padding(.vertical, 12)
            Hairline()
            HStack { DatePicker("Date", selection: $date, in: ...Date.now.addingTimeInterval(86_400), displayedComponents: .date).onChange(of: date) { _, _ in uncertain.remove(.date) }; flag(.date) }.padding(.vertical, 8)
            Hairline()
            HStack { Text("Total").foregroundStyle(Theme.inkSecondary); AmountField(text: $totalText, currency: currency).onChange(of: totalText) { _, _ in uncertain.remove(.total) }; flag(.total) }.padding(.vertical, 8)
            Hairline()
            HStack { Text("Tax").foregroundStyle(Theme.inkSecondary); AmountField(text: $taxText, placeholder: "optional", currency: currency) }.padding(.vertical, 8)
            Hairline()
            HStack { Text("Account").foregroundStyle(Theme.inkSecondary); Spacer(); Picker("Account", selection: $accountID) { ForEach(books.active) { Text($0.name).tag(Optional($0.id)) } }.labelsHidden().tint(Theme.accent) }.padding(.vertical, 4)
            Hairline()
            HStack { Text("Category").foregroundStyle(Theme.inkSecondary); Spacer(); Picker("Category", selection: $category) {
                Text("Choose…").tag("")
                ForEach(expenseCategories) { Text($0.name).tag($0.name) }
            }.labelsHidden().tint(Theme.accent) }.padding(.vertical, 4)
            Hairline()
            TextField("Notes (optional)", text: $notes, axis: .vertical).padding(.vertical, 12)
        }
        .glass(padding: 16)
    }

    private var itemsCard: some View {
        DisclosureGroup(isExpanded: $showItems) {
            VStack(spacing: 6) {
                ForEach(items) { i in HStack { Text(i.name).lineLimit(1); Spacer(); Text(Money.format(i.cents, currency: currency)) }.font(.footnote) }
                Text("Possible items found by the scan. They’re for reference and aren’t saved as separate transactions.").font(.caption).foregroundStyle(Theme.inkTertiary).padding(.top, 4)
            }.padding(.top, 8)
        } label: { Text("\(items.count) possible items").font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink) }
        .tint(Theme.inkSecondary).glass(padding: 16)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if let l = linked {
                Callout(text: "Linked to \(l.merchant.isEmpty ? l.title : l.merchant) · \(Money.format(l.amountCents, currency: currency)) on \(l.date.formatted(date: .abbreviated, time: .omitted)).", tone: .info, symbol: "link")
                Button { saveReceipt(link: .keep) } label: { Text("Save changes") }.buttonStyle(PrimaryButtonStyle()).disabled(total == nil && !(draft == nil))
                Button("Unlink from transaction") { saveReceipt(link: .unlink) }.font(.subheadline.weight(.medium)).foregroundStyle(Theme.accent).buttonStyle(PressableStyle())
            } else {
                Button { saveAsExpense(confirmed: false) } label: { Label("Save as new expense", systemImage: "plus.circle") }
                    .buttonStyle(PrimaryButtonStyle()).disabled(total == nil || category.isEmpty || account == nil).accessibilityIdentifier("saveReceiptExpense")
                Button { showAttach = true } label: { Label("Attach to an existing transaction…", systemImage: "link").font(.subheadline.weight(.medium)) }
                    .foregroundStyle(Theme.accent).buttonStyle(PressableStyle()).disabled(total == nil && txs.isEmpty)
                Button { saveReceipt(link: .keep) } label: { Text("Save receipt only").font(.subheadline.weight(.medium)) }
                    .foregroundStyle(Theme.accent).buttonStyle(PressableStyle())
            }
            if receipt != nil { Button("Delete receipt…", role: .destructive) { confirmDelete = true }.font(.subheadline).buttonStyle(PressableStyle()).padding(.top, 6) }
            if total == nil || category.isEmpty { Text(total == nil ? "Enter the total to save an expense." : "Choose a category to save an expense.").font(.footnote).foregroundStyle(Theme.inkTertiary) }
        }
    }

    // MARK: Load

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let r = receipt {
            merchant = r.merchant; date = r.date; category = r.category; notes = r.notes
            accountID = linked?.accountID ?? allAccounts.first { $0.currencyCode == r.currencyCode && !$0.isArchived }?.id ?? books.defaultAccount?.id
            totalText = r.totalCents > 0 ? Money.editable(r.totalCents, currency: currency) : ""
            taxText = r.taxCents > 0 ? Money.editable(r.taxCents, currency: currency) : ""
            uncertain = r.needsReview ? [.total] : []
        } else if let d = draft {
            accountID = UUID(uuidString: lastAccountID).flatMap { id in books.active.first { $0.id == id }?.id } ?? books.defaultAccount?.id
            merchant = d.parsed.merchant; date = d.parsed.date ?? .now; uncertain = d.parsed.uncertain
            if let t = d.parsed.totalCents { totalText = Money.editable(t, currency: currency) }
            if let t = d.parsed.taxCents { taxText = Money.editable(t, currency: currency) }
            // The most recently used category for this merchant, if there is one.
            let key = ReceiptParser.fold(d.parsed.merchant).lowercased()
            if !key.isEmpty, let past = txs.first(where: { ReceiptParser.fold($0.merchant).lowercased() == key && $0.kind == .expense }) { category = past.category }
        }
    }

    // MARK: Save

    private enum LinkChange { case keep, unlink }

    /// Writes or updates the receipt record (and stores the photo for a new one). Returns it.
    @discardableResult
    private func persist(linking id: UUID? = nil, change: LinkChange = .keep) -> Receipt? {
        let r: Receipt
        if let existing = receipt { r = existing }
        else {
            guard let d = draft, let data = ReceiptStore.prepared(d.image) else { errors.report(ReceiptOCR.OCRError.unreadable, doing: "Couldn’t save the receipt"); return nil }
            do { r = Receipt(); r.imageFile = try ReceiptStore.store(data); r.imageHash = ReceiptStore.hash(data) }
            catch { errors.report(error, doing: "Couldn’t save the photo"); return nil }
            r.ocrText = d.ocrText; r.languageRaw = d.language.rawValue
            r.itemsJSON = (try? JSONEncoder().encode(d.parsed.items)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            context.insert(r)
        }
        r.merchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines); r.date = date
        r.totalCents = total ?? 0; r.taxCents = tax; r.currencyCode = currency.code; r.category = category; r.notes = notes
        r.needsReview = total == nil || uncertain.contains(.total) || uncertain.contains(.date)
        if let id { r.transactionID = id } else if change == .unlink { r.transactionID = nil }
        return r
    }

    private func saveReceipt(link change: LinkChange) {
        guard persist(change: change) != nil else { return }
        finish()
    }

    private func saveAsExpense(confirmed: Bool) {
        guard let cents = total, !category.isEmpty, let acct = account else { return }
        let name = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        if !confirmed, duplicateTransaction != nil { confirmDuplicate = true; return }
        let tx = TransactionRecord(amountCents: cents, kind: .expense, category: category, date: date, title: name, notes: notes, accountID: acct.id, merchant: name, tags: "")
        context.insert(tx)
        guard persist(linking: tx.id) != nil else { context.delete(tx); return }
        lastAccountID = acct.id.uuidString
        finish()
    }

    private func attach(to t: TransactionRecord) {
        showAttach = false
        if merchant.trimmingCharacters(in: .whitespaces).isEmpty { merchant = t.merchant.isEmpty ? t.title : t.merchant }
        if category.isEmpty { category = t.category }
        guard let r = persist(linking: t.id) else { return }
        // The photo is evidence, so the transaction keeps its own amount; only an empty merchant is filled in.
        if t.merchant.isEmpty, !r.merchant.isEmpty { t.merchant = r.merchant }
        finish()
    }

    private func finish() {
        do { try context.save(); Haptics.success(); ToastCenter.shared.show("Receipt saved"); onFinish() } catch { errors.report(error, doing: "Couldn’t save the receipt") }
    }

    private func deleteReceipt() {
        guard let r = receipt else { return }
        ReceiptStore.delete(r.imageFile)
        context.delete(r)
        finish()
    }
}

private struct AttachSheet: View {
    let candidates: [TransactionRecord]
    let currency: Currency
    var onPick: (TransactionRecord) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if candidates.isEmpty { Text("No expenses with the same amount or from the last week were found.").font(.subheadline).foregroundStyle(Theme.inkSecondary) }
                    ForEach(candidates) { t in
                        Button { onPick(t) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.merchant.isEmpty ? (t.title.isEmpty ? t.category : t.title) : t.merchant).foregroundStyle(Theme.ink)
                                    Text(t.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(Theme.inkSecondary)
                                }
                                Spacer(); Text(Money.format(t.amountCents, currency: currency)).foregroundStyle(Theme.ink)
                            }
                        }
                    }
                } footer: { Text("Same amount first, then the closest dates. The transaction keeps its own amount; the receipt is added as proof.") }
            }
            .scrollContentBackground(.hidden).monoScreen()
            .navigationTitle("Attach to").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.presentationDetents([.large])
    }
}
