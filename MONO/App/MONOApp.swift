import SwiftUI
import SwiftData
import UserNotifications

@main
struct MONOApp: App {
    private let container: Result<ModelContainer, Error>

    init() {
        container = Result { try Persistence.makeContainer() }
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            switch container {
            case .success(let c):
                RootView().modelContainer(c)
            case .failure(let error):
                StoreFailureView(error: error)
            }
        }
    }
}

/// Shown instead of silently starting from an empty store, so a storage problem never looks like lost data.
struct StoreFailureView: View {
    let error: Error
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 34, weight: .light)).foregroundStyle(Theme.danger)
            Text("Couldn’t open your data").font(.title3.weight(.semibold))
            Text("MONO has not changed or deleted anything. Restart the app; if this continues, free up storage space or restore from a backup.")
                .font(.subheadline).foregroundStyle(Theme.inkSecondary).multilineTextAlignment(.center)
            Text(error.localizedDescription).font(.caption).foregroundStyle(Theme.inkTertiary).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}
