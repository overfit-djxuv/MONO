import SwiftUI

struct QuickActionsSettingsView: View {
    @State private var enabled = QuickActionSettings.enabled()

    var body: some View {
        Form {
            Group {
                Section {
                    ForEach(QuickAction.allCases) { a in
                        Toggle(isOn: Binding(get: { enabled.contains(a) }, set: { on in
                            QuickActionSettings.toggle(a, on: on); QuickActionSettings.publish(); enabled = QuickActionSettings.enabled()
                        })) { Label(a.title, systemImage: a.symbol) }.tint(Theme.accent)
                    }
                } header: { Text("Touch and hold the MONO icon") } footer: {
                    Text("iOS shows up to \(QuickActionSettings.maxShown) actions. They open MONO on the right screen, and wait for Face ID first if the lock is on. Nothing is recorded until you save.")
                }
                Section {
                    Label("Open the Shortcuts app and search for MONO to use these with Siri, the Action button or an automation.", systemImage: "square.stack.3d.up")
                        .font(.footnote).foregroundStyle(Theme.inkSecondary)
                } header: { Text("Shortcuts and Siri") } footer: {
                    Text("Shortcuts only open the app; they never read your balances aloud or share them.")
                }
            }.listRowBackground(GlassRowBackground())
        }
        .scrollContentBackground(.hidden).monoScreen()
        .navigationTitle("Quick actions").navigationBarTitleDisplayMode(.inline)
    }
}
