import SwiftUI

enum Tab: String {
    case play, worlds, packs, logs, settings
}

/// The launcher's tabs, as a launcher app has them: Play, Worlds, Packs & mods, Logs, Settings.
struct RootView: View {
    @AppStorage("tab") private var tab = Tab.play
    @StateObject private var installer = Installer()
    @StateObject private var accounts = Accounts()

    var body: some View {
        TabView(selection: $tab) {
            LauncherView(installer: installer, accounts: accounts)
                .tabItem { Label("Play", systemImage: "play.fill") }
                .tag(Tab.play)
            WorldsView()
                .tabItem { Label("Worlds", systemImage: "globe") }
                .tag(Tab.worlds)
            PacksView()
                .tabItem { Label("Packs & mods", systemImage: "shippingbox") }
                .tag(Tab.packs)
            LogsView()
                .tabItem { Label("Logs", systemImage: "doc.text.magnifyingglass") }
                .tag(Tab.logs)
            SettingsView(accounts: accounts, installer: installer)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
    }
}
