import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @Query private var txs: [TransactionRecord]
    @AppStorage("openingBalanceCents") private var opening = 0
    @AppStorage("currencySymbol") private var symbol = "RM"
    @AppStorage("lastBackupAt") private var lastBackupAt = 0.0
    @AppStorage(AppLock.enabledKey) private var lockEnabled = false
    @AppStorage(Reminders.enabledKey) private var remindersEnabled = false
    @Query private var planned: [PlannedExpense]
    @Query private var monthBudgets: [MonthBudget]
    @Query private var limits: [BudgetLimit]
    @Environment(AppLock.self) private var lock

    @State private var openingText = ""
    @State private var exportURL: URL?
    @State private var backupDoc: BackupDocument?
    @State private var showBackupExporter = false
    @State private var lockMessage: String?
    @State private var showImporter = false
    @State private var importingCSV = false
    @State private var csvRecords: CSVRecords?
    @State private var pendingImport: BackupFile?
    @State private var importSummary = ""
    @State private var confirmErase = false
    @State private var confirmEraseFinal = false
    @State private var working = false
    @FocusState private var focusOpening: Bool

    var body: some View {
        Form {
            Group {
            Section {
                HStack {
                    Text("Opening balance")
                    TextField("0.00", text: $openingText)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).font(.figure(17))
                        .focused($focusOpening)
                        .onChange(of: openingText) { _, v in
                            let s = AmountField.sanitize(v)
                            if s != v { openingText = s }
                        }
                        .accessibilityIdentifier("openingBalance")
                }
                HStack {
                    Text("Currency symbol")
                    TextField("RM", text: $symbol).multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .onChange(of: symbol) { _, v in if v.count > 4 { symbol = String(v.prefix(4)) } }
                }
            } header: { Text("Money") } footer: {
                Text("Available cash = opening balance + income − expenses − money moved into goals. Enter what you have today and MONO tracks it from there.")
            }

            Section {
                NavigationLink { ThemeEditorView() } label: {
                    HStack(spacing: 12) {
                        HStack(spacing: -5) {
                            ForEach([Theme.bg, Theme.surface, Theme.primary, Theme.accent], id: \.self) { c in
                                Circle().fill(c).frame(width: 18, height: 18).overlay(Circle().strokeBorder(Theme.cardLine, lineWidth: 0.5))
                            }
                        }
                        Text("Theme")
                        Spacer()
                        Text(ThemeStore.shared.selected.name).foregroundStyle(Theme.inkSecondary)
                    }
                }
            } footer: { Text("Palettes, your own colours, light and dark, and Liquid Glass intensity.") }

            Section {
                NavigationLink { AppIconView() } label: {
                    HStack(spacing: 12) {
                        IconArtwork(name: AppIconChoice(alternateName: UIApplication.shared.alternateIconName).previewName, size: 30)
                        Text("App icon")
                        Spacer()
                        Text(AppIconChoice(alternateName: UIApplication.shared.alternateIconName).label).foregroundStyle(Theme.inkSecondary)
                    }
                }
                NavigationLink("Categories") { CategoriesView() }
                NavigationLink { RecurringView() } label: {
                    Label("Recurring transactions", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            Section {
                Toggle(isOn: Binding(get: { remindersEnabled }, set: { setReminders($0) })) {
                    Label("Reminders", systemImage: "bell")
                }
            } header: { Text("Notifications") } footer: {
                Text("A nudge the morning before and the day a planned expense is due, and when a month’s budget reaches 80% or goes over. Everything is scheduled on this iPhone.")
            }

            Section {
                Toggle(isOn: Binding(get: { lockEnabled }, set: { setLock($0) })) {
                    Label("Require Face ID", systemImage: "faceid")
                }
            } header: { Text("Security") } footer: {
                Text("MONO locks whenever you leave it and asks for Face ID, or your iPhone passcode if Face ID fails.")
            }

            Section {
                HStack {
                    Text("Last backup")
                    Spacer()
                    Text(lastBackupText).foregroundStyle(backupIsStale ? Theme.warning : Theme.inkSecondary)
                }
                Button { exportBackup() } label: { Label("Back up now", systemImage: "externaldrive") }
                if let exportURL {
                    ShareLink(item: exportURL) { Label("Share transactions file", systemImage: "square.and.arrow.up") }
                }
                Button { exportCSV() } label: { Label("Export transactions (CSV)", systemImage: "tablecells") }
                Button { importingCSV = true; showImporter = true } label: { Label("Import transactions (CSV)…", systemImage: "square.and.arrow.down") }
                Button { importingCSV = false; showImporter = true } label: { Label("Restore from backup…", systemImage: "arrow.counterclockwise") }
            } header: { Text("Backup") } footer: {
                Text("Back up now saves a file to Files or iCloud Drive; keep a copy somewhere other than this iPhone. Nothing is uploaded by MONO. Restoring replaces all current records.")
            }

            if let expiry = ProfileInfo.expiry {
                Section {
                    let status = ProfileInfo.status(expiry: expiry)
                    HStack {
                        Text("Signed until")
                        Spacer()
                        Text(expiry.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    HStack {
                        Text("Time left")
                        Spacer()
                        Text(profileLeftText(status)).foregroundStyle(status.isWarning ? Theme.warning : Theme.inkSecondary)
                    }
                } header: { Text("App installation") } footer: {
                    Text("This copy of MONO was installed with a free Apple ID and stops opening when this runs out. Your Mac renews it automatically; if it gets low, connect the iPhone and run the install again. Never delete the app: that deletes your data.")
                }
            }

            Section {
                Label("Works fully offline", systemImage: "wifi.slash")
                Label("No account, no bank connection, no analytics", systemImage: "lock")
                Label("Stored on this iPhone with iOS file protection", systemImage: "internaldrive")
            } header: { Text("Privacy") }
            .foregroundStyle(Theme.inkSecondary).font(.subheadline)

            Section {
                NavigationLink {
                    VersionHistoryView()
                } label: {
                    HStack {
                        Label("Version history", systemImage: "clock.arrow.circlepath")
                        Spacer()
                        Text("\(VersionHistory.current) (\(VersionHistory.build))").foregroundStyle(Theme.inkSecondary)
                    }
                }
            }

            Section {
                Button("Erase all data…", role: .destructive) { confirmErase = true }
            }
            }.listRowBackground(GlassRowBackground())
        }
        .scrollContentBackground(.hidden).monoScreen()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focusOpening = false } }
        }
        .onAppear { openingText = Money.editable(opening) }
        .onChange(of: focusOpening) { _, focused in if !focused { commitOpening() } }
        .onDisappear { commitOpening() }
        .fileExporter(isPresented: $showBackupExporter, document: backupDoc, contentType: .json,
                      defaultFilename: "MONO-backup-\(stamp())") { result in
            backupDoc = nil
            switch result {
            case .success: lastBackupAt = Date.now.timeIntervalSince1970; Haptics.success()
            case .failure(let e): errors.report(e, doing: "Couldn’t save backup")
            }
        }
        .alert("Can’t turn that on", isPresented: Binding(get: { lockMessage != nil }, set: { if !$0 { lockMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(lockMessage ?? "") }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importingCSV ? [.commaSeparatedText, .plainText] : [.json]) { result in
            if importingCSV { handleCSV(result) } else { handleImport(result) }
        }
        .sheet(item: $csvRecords) { CSVImportView(records: $0.rows) }
        .confirmationDialog("Replace all data with this backup?", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }),
                            titleVisibility: .visible) {
            Button("Replace everything", role: .destructive) { applyImport() }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: {
            Text("\(importSummary)\n\nYour current records on this iPhone will be deleted and cannot be recovered unless you made a backup.")
        }
        .confirmationDialog("Erase all data?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Continue", role: .destructive) { confirmEraseFinal = true }
        } message: { Text("This removes every transaction, budget, list and goal from this iPhone.") }
        .alert("Erase everything?", isPresented: $confirmEraseFinal) {
            Button("Erase", role: .destructive) {
                do { try Ledger.eraseEverything(in: context); openingText = ""; exportURL = nil; Haptics.warning() }
                catch { errors.report(error, doing: "Couldn’t erase data") }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Last chance — this cannot be undone.") }
        .overlay { if working { ProgressView().controlSize(.large) } }
    }

    private func commitOpening() {
        let cents = openingText.isEmpty ? 0 : (Money.parse(openingText) ?? opening)
        if cents != opening { opening = cents }
    }

    // MARK: Export

    private var lastBackup: Date? { lastBackupAt > 0 ? Date(timeIntervalSince1970: lastBackupAt) : nil }
    private var backupIsStale: Bool { BackupService.isBackupStale(lastBackup: lastBackup, hasData: !txs.isEmpty) }
    private var lastBackupText: String {
        guard let d = lastBackup else { return "Never" }
        return Calendar.current.isDateInToday(d) ? "Today" : d.formatted(.relative(presentation: .named))
    }

    private func profileLeftText(_ s: ProfileInfo.Status) -> String {
        switch s {
        case .expired: "Expired"
        case .ok(let d), .soon(let d): d == 0 ? "Less than a day" : "\(d) \(d == 1 ? "day" : "days")"
        }
    }

    private func setReminders(_ on: Bool) {
        guard on else {
            remindersEnabled = false
            Reminders.cancelAll()
            return
        }
        Task {
            guard await Reminders.requestAuthorization() else {
                lockMessage = "Notifications are off for MONO. Turn them on in Settings ▸ Notifications ▸ MONO, then try again."
                return
            }
            // Don't announce a month that is already over budget the moment this is switched on.
            let m = MonthKey(.now)
            Reminders.acknowledgeBudget(FinanceEngine.budgetSummary(
                month: m, totalLimit: monthBudgets.first { $0.monthKey == m.string }?.totalCents, limits: limits, transactions: txs))
            remindersEnabled = true
            await Reminders.syncPlanned(planned)
        }
    }

    private func setLock(_ on: Bool) {
        guard on else { lockEnabled = false; lock.clear(); return }
        if let why = AppLock.unavailableReason() { lockMessage = why; return }
        Task {
            if await AppLock.authenticate(reason: "Turn on the MONO lock") { lockEnabled = true }
        }
    }

    private func exportBackup() {
        commitOpening()
        do {
            let file = try BackupService.snapshot(context: context, openingBalanceCents: opening, currencySymbol: Money.symbol)
            backupDoc = BackupDocument(data: try BackupService.encode(file))
            showBackupExporter = true
        } catch { errors.report(error, doing: "Couldn’t create backup") }
    }

    private func exportCSV() {
        do {
            let all = try context.fetch(FetchDescriptor<TransactionRecord>())
            exportURL = try write(Data(BackupService.csv(transactions: all).utf8), name: "MONO-transactions-\(stamp()).csv")
            Haptics.success()
        } catch { errors.report(error, doing: "Couldn’t export") }
    }

    private func write(_ data: Data, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    private func stamp() -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: .now)
    }

    // MARK: Import

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let e): errors.report(e, doing: "Couldn’t open file")
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size < 50_000_000 else { throw BackupError.invalid("the file is unexpectedly large") }
                let file = try BackupService.decode(Data(contentsOf: url))
                importSummary = "Backup from \(file.exportedAt.short): \(file.transactions.count) transactions, \(file.goals.count) goals, \(file.shoppingItems.count) shopping items, \(file.budgetLimits.count) budget limits."
                pendingImport = file
            } catch { errors.report(error, doing: "Can’t restore") }
        }
    }

    private func handleCSV(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let e): errors.report(e, doing: "Couldn’t open file")
        case .success(let url):
            do { csvRecords = CSVRecords(rows: try CSVImport.load(from: url)) }
            catch { errors.report(error, doing: "Can’t import") }
        }
    }

    private func applyImport() {
        guard let file = pendingImport else { return }
        pendingImport = nil
        do {
            try BackupService.replaceAll(with: file, in: context)
            openingText = Money.editable(file.openingBalanceCents)
            Haptics.success()
        } catch { errors.report(error, doing: "Restore failed — your existing data was kept") }
    }
}

struct CategoriesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \MoneyCategory.sortOrder) private var categories: [MoneyCategory]
    @Query private var txs: [TransactionRecord]
    @State private var adding: TxKind?
    @State private var pendingDelete: MoneyCategory?

    var body: some View {
        List {
            Group {
            ForEach(TxKind.allCases) { kind in
                Section(kind == .expense ? "Expense" : "Income") {
                    ForEach(categories.filter { $0.kind == kind }) { c in
                        HStack(spacing: 12) {
                            CategoryGlyph(symbol: c.symbol, tint: Theme.inkSecondary)
                            Text(c.name)
                            Spacer()
                            if c.isDefault { Text("Default").font(.caption).foregroundStyle(Theme.inkTertiary) }
                        }
                        .swipeActions(edge: .trailing) {
                            if !c.isDefault { Button(role: .destructive) { pendingDelete = c } label: { Label("Delete", systemImage: "trash") } }
                        }
                    }
                    Button { adding = kind } label: { Label("Add category", systemImage: "plus").font(.subheadline) }
                }
            }
            }.listRowBackground(GlassRowBackground())
        }
        .scrollContentBackground(.hidden).monoScreen()
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $adding) { NewCategorySheet(kind: $0) { _ in } }
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { c in
            Button("Delete", role: .destructive) { context.delete(c); try? context.save() }
        } message: { c in
            let n = txs.filter { $0.category == c.name }.count
            Text(n > 0 ? "\(n) existing \(n == 1 ? "transaction keeps" : "transactions keep") this category name and stay in your totals." : "No transactions use it.")
        }
    }
}
