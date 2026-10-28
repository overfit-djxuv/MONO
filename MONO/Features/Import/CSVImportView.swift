import SwiftUI
import SwiftData

/// Column mapping and preview for a CSV file. Nothing is saved until "Add" is tapped, and importing only adds records.
struct CSVImportView: View {
    let records: [[String]]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @Query private var allExisting: [TransactionRecord]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @State private var accountID: UUID?
    @Query(sort: \MoneyCategory.sortOrder) private var categories: [MoneyCategory]

    @State private var mapping: CSVImport.Mapping
    @State private var createCategories = false
    @State private var plan = CSVImport.Plan()
    @State private var imported: Int?

    init(records: [[String]]) {
        self.records = records
        _mapping = State(initialValue: CSVImport.autoMapping(records))
    }

    private var targetAccounts: [Account] { accounts.filter { !$0.isArchived } }
    private var account: Account? { targetAccounts.first { $0.id == accountID } ?? AccountEngine.defaultAccount(accounts) }
    /// Duplicates are judged against the chosen account only.
    private var existing: [TransactionRecord] {
        let def = AccountEngine.defaultAccount(accounts)?.id
        return allExisting.filter { ($0.accountID ?? def) == account?.id }
    }

    private var columnNames: [String] {
        let width = records.map(\.count).max() ?? 0
        let header = mapping.hasHeader ? records.first : nil
        return (0..<width).map { i in
            let h = header.flatMap { $0.indices.contains(i) ? $0[i].trimmingCharacters(in: .whitespaces) : nil } ?? ""
            return h.isEmpty ? "Column \(i + 1)" : h
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let imported { done(imported) } else { form }
            }
            .scrollContentBackground(.hidden).monoScreen()
            .navigationTitle("Import CSV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(imported == nil ? "Cancel" : "Done") { dismiss() } }
                if imported == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add \(plan.rows.count)") { add() }.disabled(plan.rows.isEmpty)
                    }
                }
            }
            .onAppear(perform: recompute)
            .onChange(of: mapping) { _, _ in recompute() }
            .onChange(of: createCategories) { _, _ in recompute() }
        }
        .presentationDetents([.large])
    }

    private func done(_ n: Int) -> some View {
        EmptyState(symbol: "checkmark.circle", title: "Added \(n) \(n == 1 ? "transaction" : "transactions")",
                   message: "They’re in your Transactions list now. Back up again when you’re ready.")
    }

    private var form: some View {
        Form {
            Group {
            if targetAccounts.count > 1 {
                Section {
                    Picker("Import into", selection: Binding(get: { account?.id }, set: { accountID = $0; recompute() })) {
                        ForEach(targetAccounts) { Label("\($0.name) · \($0.currencyCode)", systemImage: $0.kind.symbol).tag(Optional($0.id)) }
                    }
                } footer: { Text("Amounts in the file are read as this account’s currency.") }
            }
            Section {
                Toggle("First row is a header", isOn: $mapping.hasHeader)
                columnPicker("Date", $mapping.date)
                Picker("Date format", selection: $mapping.dateFormat) {
                    ForEach(CSVImport.DateFormat.allCases) { Text($0.label).tag($0) }
                }
                columnPicker("Description", $mapping.title)
            } header: { Text("Columns") } footer: {
                Text("MONO guessed these from the file. Check the preview below and change anything that looks wrong.")
            }

            Section {
                Picker("Amounts", selection: $mapping.mode) {
                    ForEach(CSVImport.AmountMode.allCases) { Text($0.label).tag($0) }
                }
                switch mapping.mode {
                case .signed:
                    columnPicker("Amount", $mapping.amount)
                    Toggle("Positive amounts are expenses", isOn: $mapping.invertSigns)
                case .debitCredit:
                    columnPicker("Debit (money out)", $mapping.debit)
                    columnPicker("Credit (money in)", $mapping.credit)
                case .typeColumn:
                    columnPicker("Amount", $mapping.amount)
                    columnPicker("Type", $mapping.type)
                }
            } header: { Text("Amounts") }

            Section {
                columnPicker("Category", $mapping.category)
                columnPicker("Notes", $mapping.notes)
                if mapping.category != nil {
                    Toggle("Create categories that don’t exist", isOn: $createCategories)
                }
            } header: { Text("Optional") } footer: {
                Text(mapping.category == nil || !createCategories
                     ? "Rows whose category isn’t one of yours go in Other (or Other Income)."
                     : "New categories are added with a generic icon; you can change them later.")
            }

            Section("Preview") {
                summaryRow
                ForEach(plan.rows.prefix(5), id: \.line) { r in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title.isEmpty ? r.category : r.title).lineLimit(1)
                            Text("\(r.date.formatted(date: .abbreviated, time: .omitted)) · \(r.category)")
                                .font(.caption).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(Money.format(r.kind == .income ? r.cents : -r.cents, signed: true))
                            .font(.figure(15)).foregroundStyle(r.kind == .income ? Theme.income : Theme.ink)
                    }
                }
                if plan.rows.count > 5 {
                    Text("and \(plan.rows.count - 5) more").font(.footnote).foregroundStyle(Theme.inkTertiary)
                }
                if !plan.skipped.isEmpty {
                    DisclosureGroup("\(plan.skipped.count) \(plan.skipped.count == 1 ? "row" : "rows") skipped") {
                        ForEach(plan.skipped.prefix(20), id: \.line) { s in
                            Text("Line \(s.line): \(s.reason)").font(.footnote).foregroundStyle(Theme.inkSecondary)
                        }
                        if plan.skipped.count > 20 {
                            Text("and \(plan.skipped.count - 20) more").font(.footnote).foregroundStyle(Theme.inkTertiary)
                        }
                    }
                }
            }
            }.listRowBackground(GlassRowBackground())
        }
    }

    private var summaryRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(plan.rows.count) to add · \(Money.format(plan.income)) in · \(Money.format(plan.expense)) out")
                .font(.subheadline.weight(.medium))
            if plan.duplicates > 0 {
                Text("\(plan.duplicates) already in MONO (same day, amount and description), so they’ll be left out.")
                    .font(.footnote).foregroundStyle(Theme.inkSecondary)
            }
            if !plan.newCategories.isEmpty {
                Text("New categories: \(plan.newCategories.map(\.name).joined(separator: ", "))")
                    .font(.footnote).foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    private func columnPicker(_ label: String, _ selection: Binding<Int?>) -> some View {
        Picker(label, selection: selection) {
            Text("None").tag(Int?.none)
            ForEach(Array(columnNames.enumerated()), id: \.offset) { i, n in Text(n).tag(Int?.some(i)) }
        }
    }

    private func recompute() {
        plan = CSVImport.plan(records: records, mapping: mapping, existing: existing, categories: categories,
                              createMissingCategories: createCategories && mapping.category != nil)
    }

    private func add() {
        do {
            try CSVImport.apply(plan, categories: categories, accountID: account?.id, in: context)
            Haptics.success()
            imported = plan.rows.count
        } catch { errors.report(error, doing: "Couldn’t import") }
    }
}
