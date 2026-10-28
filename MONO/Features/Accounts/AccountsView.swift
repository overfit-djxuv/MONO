import SwiftUI
import SwiftData

/// Accounts, the reporting currency, and the exchange rates used to combine them. Nothing is converted without a rate you entered.
struct AccountsView: View {
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var rates: [ExchangeRate]
    @Query private var txs: [TransactionRecord]
    @Query private var entries: [GoalEntry]
    @AppStorage("openingBalanceCents") private var legacyOpening = 0
    @AppStorage(Money.reportingKey) private var reportingCode = Currency.default.code
    @AppStorage("currencySymbol") private var symbolOverride = ""

    @State private var editing: AccountTarget?
    @State private var pendingReporting: String?

    private var books: Books { Books(accounts: accounts, rates: rates, transactions: txs, entries: entries, legacyOpening: legacyOpening) }
    private var reporting: Currency { Currency.find(reportingCode) }
    /// Currencies that need a rate: every account currency other than the reporting one.
    private var foreignCodes: [String] { Array(Set(accounts.map(\.currencyCode)).subtracting([reportingCode])).sorted() }

    var body: some View {
        let books = self.books
        Form {
            Group {
            Section {
                Picker("Reporting currency", selection: Binding(get: { reportingCode }, set: { new in
                    if new != reportingCode { pendingReporting = new }
                })) {
                    ForEach(Currency.all) { Text("\($0.code) · \($0.name)").tag($0.code) }
                }
                HStack {
                    Text("Symbol")
                    Spacer()
                    TextField(reporting.symbol, text: $symbolOverride).multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().frame(maxWidth: 120)
                        .onChange(of: symbolOverride) { _, v in if v.count > 4 { symbolOverride = String(v.prefix(4)) } }
                }
            } header: { Text("Reporting currency") } footer: {
                Text("Totals, budgets and charts are shown in this currency. Money in other currencies is converted only with the rates you enter below.")
            }

            Section {
                ForEach(books.active) { a in
                    Button { editing = AccountTarget(account: a) } label: { row(a, books) }
                        .buttonStyle(PressableStyle())
                }
                ForEach(accounts.filter(\.isArchived)) { a in
                    Button { editing = AccountTarget(account: a) } label: { row(a, books).opacity(0.55) }
                        .buttonStyle(PressableStyle())
                }
                Button { editing = AccountTarget(account: nil) } label: { Label("Add account", systemImage: "plus") }
            } header: { Text("Accounts") } footer: {
                Text("Cash, bank accounts and e-wallets. Moving money between them is recorded as a transfer, never as income or spending. Archived accounts still count toward your total.")
            }

            if !foreignCodes.isEmpty {
                Section {
                    ForEach(foreignCodes, id: \.self) { code in
                        RateRow(code: code, reporting: reporting, rate: rates.first { $0.fromCode == code && $0.toCode == reportingCode }) { micros in
                            saveRate(code, micros)
                        }
                    }
                } header: { Text("Exchange rates") } footer: {
                    Text("Enter how much of \(reporting.code) one unit of each currency is worth. Rates are only ever typed by you; MONO never downloads them. Without a rate, that account is left out of totals and reports, and flagged.")
                }
            }
            }.listRowBackground(GlassRowBackground())
        }
        .scrollContentBackground(.hidden).monoScreen()
        .navigationTitle("Accounts")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { AccountForm(editing: $0.account) }
        .confirmationDialog("Change reporting currency to \(pendingReporting ?? "")?", isPresented: Binding(get: { pendingReporting != nil }, set: { if !$0 { pendingReporting = nil } }),
                            titleVisibility: .visible) {
            Button("Change to \(pendingReporting ?? "")") {
                if let c = pendingReporting { reportingCode = c; symbolOverride = "" }
                pendingReporting = nil
            }
            Button("Cancel", role: .cancel) { pendingReporting = nil }
        } message: {
            Text("Your records and account balances are not changed. Accounts in the old currency will need an exchange rate to be included in totals.")
        }
    }

    private func row(_ a: Account, _ books: Books) -> some View {
        HStack(spacing: 12) {
            CategoryGlyph(symbol: a.kind.symbol, tint: Theme.inkSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.name).font(.body).foregroundStyle(Theme.ink).lineLimit(1)
                Text("\(a.kind.label) · \(a.currencyCode)\(a.isArchived ? " · archived" : (a.id == books.defaultAccount?.id ? " · default" : ""))")
                    .font(.caption).foregroundStyle(Theme.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Money.format(books.balance(of: a), currency: a.currency)).font(.figure(16)).foregroundStyle(Theme.ink)
                if a.currencyCode != reportingCode {
                    Text(books.reportingBalance(of: a).map { "≈ \(Money.format($0))" } ?? "needs a rate")
                        .font(.caption).foregroundStyle(books.needsRate(a) ? Theme.warning : Theme.inkSecondary)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func saveRate(_ code: String, _ micros: Int?) {
        let existing = rates.filter { $0.fromCode == code && $0.toCode == reportingCode }
        if let micros {
            if let r = existing.first { r.rateMicros = micros; r.updatedAt = .now } else {
                context.insert(ExchangeRate(fromCode: code, toCode: reportingCode, rateMicros: micros))
            }
        } else { existing.forEach(context.delete) }
        do { try context.save() } catch { errors.report(error, doing: "Couldn’t save the rate") }
    }
}

struct AccountTarget: Identifiable { let id = UUID(); let account: Account? }

private struct RateRow: View {
    let code: String
    let reporting: Currency
    let rate: ExchangeRate?
    var onSave: (Int?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var micros: Int? { CurrencyConverter.parseRate(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("1 \(code) =")
                Spacer()
                TextField("rate", text: $text).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 110)
                    .focused($focused)
                Text(reporting.code).foregroundStyle(Theme.inkSecondary)
            }
            if let rate {
                Text("Updated \(rate.updatedAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(Theme.inkSecondary)
            } else {
                Label("No rate yet: this currency is left out of totals", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
            if !text.isEmpty && micros == nil {
                Text("Enter a rate greater than zero, such as 4.47.").font(.caption).foregroundStyle(Theme.danger)
            }
        }
        .onAppear { text = rate.map { CurrencyConverter.formatRate($0.rateMicros) } ?? "" }
        .onChange(of: focused) { _, now in
            guard !now else { return }
            if text.isEmpty { if rate != nil { onSave(nil) } } else if let micros, micros != rate?.rateMicros { onSave(micros) }
        }
        .onDisappear { if let micros, micros != rate?.rateMicros { onSave(micros) } }
    }
}

struct AccountForm: View {
    let editing: Account?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var txs: [TransactionRecord]
    @Query private var entries: [GoalEntry]

    @State private var name = ""
    @State private var kind: AccountKind = .bank
    @State private var currencyCode = Money.reporting.code
    @State private var openingText = ""
    @State private var archived = false
    @State private var confirmDelete = false

    private var currency: Currency { Currency.find(currencyCode) }
    private var opening: Int { openingText.isEmpty ? 0 : (Money.parse(openingText, currency: currency) ?? -1) }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameTaken: Bool { accounts.contains { $0.id != editing?.id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame } }
    /// An account with records keeps its currency: changing it would silently re-label every amount.
    private var usedCount: Int {
        guard let e = editing else { return 0 }
        let def = AccountEngine.defaultAccount(accounts)?.id
        return txs.filter { ($0.accountID ?? def) == e.id || $0.toAccountID == e.id }.count + entries.filter { ($0.accountID ?? def) == e.id }.count
    }
    private var canSave: Bool { !trimmed.isEmpty && trimmed.count <= 32 && !nameTaken && opening >= 0 }
    private var isOnlyActive: Bool { accounts.filter { !$0.isArchived }.count <= 1 && editing?.isArchived == false }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section {
                    TextField("Name", text: $name)
                    if nameTaken { Text("You already have an account with this name.").font(.footnote).foregroundStyle(Theme.danger) }
                    Picker("Type", selection: $kind) { ForEach(AccountKind.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) } }
                    Picker("Currency", selection: $currencyCode) {
                        ForEach(Currency.all) { Text("\($0.code) · \($0.name)").tag($0.code) }
                    }
                    .disabled(usedCount > 0)
                    HStack {
                        Text("Starting balance")
                        AmountField(text: $openingText, currency: currency)
                    }
                } footer: {
                    Text(usedCount > 0 ? "The currency is fixed because \(usedCount) \(usedCount == 1 ? "record uses" : "records use") this account. The starting balance is what the account held before your first record in MONO."
                                       : "The starting balance is what the account holds today, before you record anything in MONO.")
                }
                if let editing {
                    Section {
                        if editing.id != AccountEngine.defaultAccount(accounts)?.id, !editing.isArchived {
                            Button("Use for new entries by default") { makeDefault(editing) }
                        }
                        Toggle("Archived", isOn: $archived).disabled(isOnlyActive)
                    } footer: {
                        Text(isOnlyActive ? "You need at least one active account." : "Archived accounts are hidden from pickers. Their money still counts in your total.")
                    }
                    Section {
                        Button("Delete account", role: .destructive) { confirmDelete = true }
                            .disabled(usedCount > 0 || isOnlyActive)
                    } footer: {
                        Text(usedCount > 0 ? "An account with records can’t be deleted, because that would erase them. Archive it instead." : "")
                    }
                }
                }.listRowBackground(GlassRowBackground())
            }
            .scrollContentBackground(.hidden).monoScreen()
            .navigationTitle(editing == nil ? "New account" : "Edit account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
            .onAppear {
                if let e = editing {
                    name = e.name; kind = e.kind; currencyCode = e.currencyCode; archived = e.isArchived
                    openingText = Money.editable(e.openingCents, currency: e.currency)
                }
            }
            .confirmationDialog("Delete “\(editing?.name ?? "")”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete account", role: .destructive) {
                    guard let editing else { return }
                    context.delete(editing)
                    do { try context.save(); dismiss() } catch { errors.report(error, doing: "Couldn’t delete") }
                }
            } message: { Text("It has no records, so nothing else changes.") }
        }
        .presentationDetents([.large])
    }

    private func makeDefault(_ a: Account) {
        // Records are already stamped with their own account, so changing the default never moves existing money.
        let low = accounts.map(\.sortOrder).min() ?? 0
        a.sortOrder = low - 1
        do { try context.save(); Haptics.success(); dismiss() } catch { errors.report(error, doing: "Couldn’t change the default") }
    }

    private func save() {
        guard canSave else { return }
        if let e = editing {
            e.name = trimmed; e.kindRaw = kind.rawValue; e.openingCents = opening; e.isArchived = archived
            if usedCount == 0 { e.currencyCode = currencyCode }
        } else {
            let order = (accounts.map(\.sortOrder).max() ?? -1) + 1
            context.insert(Account(name: trimmed, kind: kind, currencyCode: currencyCode, openingCents: opening, sortOrder: order))
        }
        do { try context.save(); Haptics.success(); dismiss() } catch { errors.report(error, doing: "Couldn’t save") }
    }
}
