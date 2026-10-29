import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Backup & recovery: make backups, keep a history, protect them with a passphrase, save copies outside the app, and restore safely.
struct BackupCenterView: View {
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @AppStorage(AutoBackup.frequencyKey) private var frequency = "off"
    @AppStorage(AutoBackup.keepKey) private var keep = 10
    @AppStorage(AutoBackup.encryptKey) private var encrypt = false
    @AppStorage(AutoBackup.receiptsKey) private var includePhotos = true
    @AppStorage("lastBackupAt") private var lastExportAt = 0.0
    @Query private var txs: [TransactionRecord]

    @State private var history: [BackupVault.Entry] = []
    @State private var banner: (text: String, ok: Bool)?
    @State private var working = false
    @State private var detail: BackupVault.Entry?
    @State private var restore: RestoreSource?
    @State private var showImporter = false
    @State private var askPassphrase = false
    @State private var exportDoc: BackupDocument?
    @State private var exportName = "MONO-backup.monobackup"
    @State private var showExporter = false
    @State private var showWhere = false

    private var passphrase: String? { encrypt ? Keychain.get(account: AutoBackup.passphraseAccount) : nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let banner { Callout(text: banner.text, tone: banner.ok ? .info : .danger, symbol: banner.ok ? "checkmark.shield" : "exclamationmark.triangle") }
                statusCard
                autoCard
                historyCard
                restoreCard
                whereCard
            }
            .padding(.horizontal, Theme.gutter).padding(.vertical, 8).padding(.bottom, 28)
        }
        .monoScreen()
        .navigationTitle("Backup & recovery")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if working { ProgressView().controlSize(.large) } }
        .onAppear(perform: reload)
        .sheet(item: $detail) { e in EntryDetail(entry: e, onChange: reload, onRestore: { restore = RestoreSource(entry: e, data: nil) }, onExport: { export(e) }) }
        .sheet(item: $restore) { RestoreSheet(source: $0, onDone: { reload(); banner = ("Your data was restored.", true) }) }
        .sheet(isPresented: $askPassphrase) { PassphraseSheet { encrypt = true; reload() } onCancel: { if Keychain.get(account: AutoBackup.passphraseAccount) == nil { encrypt = false } } }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count < 200_000_000 else { banner = ("That file couldn’t be read.", false); return }
            restore = RestoreSource(entry: nil, data: data)
        }
        .fileExporter(isPresented: $showExporter, document: exportDoc, contentType: .data, defaultFilename: exportName) { result in
            exportDoc = nil
            switch result {
            case .success: lastExportAt = Date.now.timeIntervalSince1970; banner = ("Copy saved outside MONO.", true); Haptics.success()
            case .failure(let e): banner = ("Couldn’t save the copy: \(e.localizedDescription)", false)
            }
        }
    }

    // MARK: Status

    private func ago(_ d: Date) -> String { Calendar.current.isDateInToday(d) ? "Today \(d.formatted(date: .omitted, time: .shortened))" : d.formatted(date: .abbreviated, time: .shortened) }
    private func size(_ b: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) }

    private var statusCard: some View {
        let last = history.first { $0.kind != "safety" && $0.intact }
        let exported = lastExportAt > 0 ? Date(timeIntervalSince1970: lastExportAt) : nil
        let stale = BackupService.isBackupStale(lastBackup: exported, hasData: !txs.isEmpty)
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Status")
            statusRow("Last backup", last.map { "\(ago($0.createdAt)) · \(size($0.size))" } ?? "None yet", ok: last != nil)
            statusRow("Saved outside MONO", exported.map { ago($0) } ?? "Never", ok: !stale)
            if stale || exported == nil {
                Callout(text: "Backups kept inside MONO are deleted if you delete the app. Save a copy to Files or iCloud Drive so your data survives that.", tone: .warning, symbol: "externaldrive.badge.exclamationmark")
            }
            Button { backUp() } label: { Label("Back up now", systemImage: "externaldrive.badge.checkmark") }
                .buttonStyle(PrimaryButtonStyle()).disabled(working).accessibilityIdentifier("backUpNow")
            Button { saveCopy() } label: { Label("Save a copy to Files…", systemImage: "square.and.arrow.up").font(.subheadline.weight(.medium)) }
                .buttonStyle(PressableStyle()).foregroundStyle(Theme.accent).frame(maxWidth: .infinity)
        }
        .glass(padding: 18)
    }

    private func statusRow(_ l: String, _ v: String, ok: Bool) -> some View {
        HStack { Text(l).font(.subheadline).foregroundStyle(Theme.inkSecondary); Spacer()
            Image(systemName: ok ? "checkmark.circle" : "exclamationmark.circle").font(.footnote).foregroundStyle(ok ? Theme.accent : Theme.warning)
            Text(v).font(.subheadline).foregroundStyle(Theme.ink) }
    }

    // MARK: Automatic

    private var autoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Automatic backups")
            Picker("How often", selection: $frequency) { ForEach(AutoBackup.Frequency.allCases) { Text($0.label).tag($0.rawValue) } }.pickerStyle(.segmented)
            Picker("Keep the last", selection: $keep) { ForEach([3, 5, 10, 20], id: \.self) { Text("\($0) backups").tag($0) } }
            Hairline()
            Toggle(isOn: $includePhotos) { Label("Include receipt photos", systemImage: "photo") }.tint(Theme.accent)
            Hairline()
            Toggle(isOn: Binding(get: { encrypt }, set: { on in
                if on { if Keychain.get(account: AutoBackup.passphraseAccount) == nil { askPassphrase = true } else { encrypt = true } }
                else { encrypt = false }
            })) { Label("Encrypt backups", systemImage: "lock") }.tint(Theme.accent)
            if encrypt {
                Button("Change passphrase") { askPassphrase = true }.font(.footnote.weight(.medium)).foregroundStyle(Theme.accent).buttonStyle(PressableStyle())
            }
            Text(encrypt ? "Backups are locked with your passphrase. It’s kept in this iPhone’s Keychain so automatic backups can run, and it is never written into a backup file. To open a backup on another device you need the passphrase; MONO can’t recover it."
                         : "Automatic backups run the first time you open MONO after each period: iOS doesn’t let apps run on a schedule in the background.")
                .font(.footnote).foregroundStyle(Theme.inkSecondary)
        }
        .glass(padding: 18)
    }

    // MARK: History

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "History").padding(.bottom, 6)
            if history.isEmpty { Text("Backups you make will be listed here.").font(.subheadline).foregroundStyle(Theme.inkSecondary) }
            ForEach(Array(history.enumerated()), id: \.element.id) { i, e in
                Button { detail = e } label: {
                    HStack(spacing: 12) {
                        Image(systemName: e.intact ? (e.encrypted ? "lock.doc" : "doc") : "exclamationmark.triangle").foregroundStyle(e.intact ? Theme.accent : Theme.danger).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ago(e.createdAt)).font(.subheadline).foregroundStyle(Theme.ink)
                            Text(e.intact ? "\(kindLabel(e.kind)) · \(size(e.size)) · \(e.summary.transactions) transactions" : "Damaged: can’t be used")
                                .font(.caption).foregroundStyle(e.intact ? Theme.inkSecondary : Theme.danger)
                        }
                        Spacer(); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.inkTertiary)
                    }
                    .padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(PressableStyle())
                if i < history.count - 1 { Hairline() }
            }
        }
        .glass(padding: 18)
    }

    private func kindLabel(_ k: String) -> String { ["manual": "Manual", "auto": "Automatic", "safety": "Before a restore"][k] ?? "Backup" }

    private var restoreCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Restore")
            Text("Open a backup saved in Files, or an older MONO .json backup. You’ll see what’s inside and nothing changes until you confirm.")
                .font(.footnote).foregroundStyle(Theme.inkSecondary)
            Button { showImporter = true } label: { Label("Restore from a file…", systemImage: "arrow.counterclockwise").font(.subheadline.weight(.medium)) }
                .buttonStyle(PressableStyle()).foregroundStyle(Theme.accent)
        }
        .glass(padding: 18)
    }

    private var whereCard: some View {
        DisclosureGroup(isExpanded: $showWhere) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Backups made here are stored in MONO’s private storage on this iPhone, protected by iOS until you unlock it after a restart. They survive app updates but are deleted if you delete MONO, so keep a copy somewhere else.")
                Text("“Save a copy to Files” lets you choose where: iCloud Drive, your Mac, a USB drive. That’s your decision; MONO never uploads anything itself and needs no account.")
                Text("What’s included: transactions, accounts, categories, budgets, goals, subscriptions, receipts, and your settings and custom themes. Not included: the Face ID lock and other security settings.")
                Text("Every backup is checked after it is written and test-restored in memory before it counts as a success.")
            }.font(.footnote).foregroundStyle(Theme.inkSecondary).padding(.top, 6)
        } label: { SectionHeader(title: "Where backups are kept") }
        .tint(Theme.inkSecondary).glass(padding: 18)
    }

    // MARK: Actions

    private func reload() { history = BackupVault.history() }

    private func backUp() {
        working = true
        defer { working = false }
        do {
            let e = try BackupVault.create(context: context, kind: "manual", passphrase: passphrase)
            banner = ("Backup saved and verified: \(size(e.size)), \(e.summary.transactions) transactions. Restore test passed.", true)
            Haptics.success()
        } catch { banner = (error.localizedDescription, false); Haptics.warning() }
        reload()
    }

    private func saveCopy() {
        do {
            let entry = try history.first { $0.kind != "safety" && $0.intact } ?? BackupVault.create(context: context, kind: "manual", passphrase: passphrase)
            reload(); export(entry)
        } catch { banner = (error.localizedDescription, false) }
    }

    private func export(_ e: BackupVault.Entry) {
        guard let data = try? Data(contentsOf: e.url) else { banner = ("That backup couldn’t be read.", false); return }
        exportDoc = BackupDocument(data: data); exportName = e.name; detail = nil
        DispatchQueue.main.async { showExporter = true }
    }
}

// MARK: - A single backup

private struct EntryDetail: View {
    let entry: BackupVault.Entry
    var onChange: () -> Void
    var onRestore: () -> Void
    var onExport: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var checked: String?
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section {
                    row("Made", entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    row("Type", ["manual": "Manual", "auto": "Automatic", "safety": "Before a restore"][entry.kind] ?? "Backup")
                    row("Size", ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                    row("Protection", entry.encrypted ? "Encrypted with a passphrase" : "Not encrypted")
                    row("App version", entry.appVersion)
                    row("Inside", "\(entry.summary.transactions) transactions · \(entry.summary.accounts) accounts · \(entry.summary.goals) goals")
                    row("File", entry.name)
                }
                Section {
                    Button { check() } label: { Label("Check this backup", systemImage: "checkmark.shield") }
                    if let checked { Text(checked).font(.footnote).foregroundStyle(Theme.inkSecondary) }
                    if entry.intact {
                        Button { dismiss(); DispatchQueue.main.async(execute: onRestore) } label: { Label("Restore from this backup…", systemImage: "arrow.counterclockwise") }
                        Button { onExport() } label: { Label("Save a copy to Files…", systemImage: "square.and.arrow.up") }
                    }
                } footer: { Text("Checking confirms the file is complete and hasn’t been changed. Restoring always shows what’s inside first and saves your current data before replacing it.") }
                Section { Button("Delete this backup", role: .destructive) { confirmDelete = true } }
                }.listRowBackground(GlassRowBackground())
            }
            .scrollContentBackground(.hidden).monoScreen()
            .navigationTitle("Backup").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Delete this backup?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { BackupVault.delete(entry); onChange(); dismiss() }
            } message: { Text("Your current data isn’t affected.") }
        }
        .presentationDetents([.large])
    }

    private func row(_ l: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(l).foregroundStyle(Theme.inkSecondary); Spacer(); Text(v).multilineTextAlignment(.trailing).foregroundStyle(Theme.ink) }.font(.subheadline)
    }

    private func check() {
        guard let data = try? Data(contentsOf: entry.url) else { checked = "The file couldn’t be read."; return }
        do {
            let e = try BackupVault.readEnvelope(data)
            checked = e.encrypted ? "Complete and unchanged. It’s encrypted, so its contents are checked when you restore with the passphrase."
                                  : "Complete and unchanged, and it opens correctly."
            if !e.encrypted { _ = try BackupVault.open(data, passphrase: nil) }
        } catch { checked = error.localizedDescription }
    }
}

// MARK: - Passphrase

struct PassphraseSheet: View {
    var onSaved: () -> Void
    var onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var first = ""
    @State private var second = ""
    @State private var failed = false

    private var valid: Bool { first.count >= 8 && first == second }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section {
                    SecureField("Passphrase (8 or more characters)", text: $first)
                    SecureField("Type it again", text: $second)
                    if !second.isEmpty && first != second { Text("The two don’t match.").font(.footnote).foregroundStyle(Theme.danger) }
                } footer: {
                    Text("If you forget this passphrase, encrypted backups can’t be opened by anyone, including MONO. It’s kept in this iPhone’s Keychain so automatic backups work, and it is never stored inside a backup. Write it down somewhere safe.")
                }
                if failed { Section { Callout(text: "The passphrase couldn’t be saved in the Keychain.", tone: .danger) }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                }.listRowBackground(GlassRowBackground())
            }
            .scrollContentBackground(.hidden).monoScreen()
            .navigationTitle("Backup passphrase").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onCancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if Keychain.set(first, account: AutoBackup.passphraseAccount) { onSaved(); dismiss() } else { failed = true } }.disabled(!valid)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Restore

struct RestoreSource: Identifiable { let id = UUID(); let entry: BackupVault.Entry?; let data: Data? }

/// Shows what a backup contains, proves it restores, saves your current data first, and only then replaces it (after you confirm).
struct RestoreSheet: View {
    let source: RestoreSource
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors

    enum Phase { case loading, needsPassphrase, ready, restoring, finished, failed }
    @State private var phase = Phase.loading
    @State private var passphrase = ""
    @State private var message: String?
    @State private var opened: (envelope: BackupVault.Envelope?, file: BackupFile)?
    @State private var check: BackupVault.RestoreCheck?
    @State private var confirm = false

    var body: some View {
        NavigationStack {
            Form {
                Group {
                switch phase {
                case .loading: Section { ProgressView() }
                case .needsPassphrase:
                    Section {
                        SecureField("Passphrase", text: $passphrase)
                        Button("Unlock backup") { load(with: passphrase) }.disabled(passphrase.isEmpty)
                        if let message { Text(message).font(.footnote).foregroundStyle(Theme.danger) }
                    } footer: { Text("This backup is encrypted. Enter the passphrase it was made with.") }
                case .ready, .restoring: ready
                case .finished:
                    Section { Callout(text: "Restored. Your data, settings and themes are back.", tone: .info, symbol: "checkmark.circle") }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                case .failed:
                    Section { Callout(text: message ?? "This backup can’t be restored.", tone: .danger) }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                }.listRowBackground(GlassRowBackground())
            }
            .scrollContentBackground(.hidden).monoScreen()
            .navigationTitle("Restore").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(phase == .finished ? "Done" : "Cancel") { dismiss() } } }
            .onAppear { load(with: Keychain.get(account: AutoBackup.passphraseAccount)) }
            .confirmationDialog("Replace everything in MONO?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Replace my data", role: .destructive) { perform() }
            } message: { Text("Your current transactions, accounts, goals and settings will be replaced by this backup. A safety copy of what you have now is saved first, so you can undo this from the history.") }
        }
        .presentationDetents([.large]).interactiveDismissDisabled(phase == .restoring)
    }

    @ViewBuilder private var ready: some View {
        if let file = opened?.file {
            Section {
                row("Made", opened?.envelope?.createdAt.formatted(date: .abbreviated, time: .shortened) ?? "older MONO backup")
                row("App version", opened?.envelope?.appVersion ?? "earlier than 1.9")
                row("Transactions", "\(file.transactions.count)"); row("Accounts", "\(file.accounts?.count ?? 1)")
                row("Goals", "\(file.goals.count)"); row("Subscriptions", "\(file.recurringRules?.count ?? 0)")
                if let r = file.receipts, !r.isEmpty { row("Receipts", "\(r.count)") }
                row("Settings and themes", file.preferences == nil ? "not included" : "included")
            } header: { Text("Inside this backup") }
            Section {
                if let check {
                    Label(check.ok ? "Restore test passed" : "Restore test failed", systemImage: check.ok ? "checkmark.shield" : "exclamationmark.triangle")
                        .foregroundStyle(check.ok ? Theme.accent : Theme.danger)
                    if !check.ok { Text(check.mismatches.joined(separator: "; ")).font(.footnote).foregroundStyle(Theme.danger) }
                }
            } footer: { Text("MONO restored this backup into a temporary database and compared the result, without touching your real data.") }
            Section {
                Button("Replace my data with this backup…", role: .destructive) { confirm = true }.disabled(phase == .restoring || !(check?.ok ?? false))
                if phase == .restoring { ProgressView() }
                if let message { Text(message).font(.footnote).foregroundStyle(Theme.danger) }
            } footer: { Text("Nothing changes until you confirm. Your current data is saved as a safety backup first.") }
        }
    }

    private func row(_ l: String, _ v: String) -> some View {
        HStack { Text(l).foregroundStyle(Theme.inkSecondary); Spacer(); Text(v).foregroundStyle(Theme.ink) }.font(.subheadline)
    }

    private func load(with pass: String?) {
        message = nil
        guard let data = source.data ?? source.entry.flatMap({ try? Data(contentsOf: $0.url) }) else { message = "The file couldn’t be read."; phase = .failed; return }
        do {
            let o = try BackupVault.open(data, passphrase: pass)
            opened = (o.envelope, o.file)
            check = BackupVault.testRestore(o.file)
            phase = .ready
        } catch BackupVault.VaultError.passphraseRequired { phase = .needsPassphrase }
        catch BackupVault.VaultError.wrongPassphrase { message = pass == nil || pass == passphrase ? "That passphrase doesn’t open this backup." : nil; phase = .needsPassphrase }
        catch { message = error.localizedDescription; phase = .failed }
    }

    private func perform() {
        guard let file = opened?.file else { return }
        phase = .restoring; message = nil
        do {
            // 1. Save what you have now. If this fails, nothing is replaced.
            let pass = UserDefaults.standard.bool(forKey: AutoBackup.encryptKey) ? Keychain.get(account: AutoBackup.passphraseAccount) : nil
            try BackupVault.create(context: context, kind: "safety", passphrase: pass)
            // 2. Replace; rolls back completely if anything fails.
            try BackupService.replaceAll(with: file, in: context)
            phase = .finished; Haptics.success(); onDone()
        } catch {
            phase = .ready; message = "Nothing was replaced. \(error.localizedDescription)"; Haptics.warning()
        }
    }
}
