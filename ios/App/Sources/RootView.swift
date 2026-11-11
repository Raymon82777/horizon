import SwiftUI

enum Tab: String {
    case play, instances, settings
}

/// The launcher's tabs: Play, Instances (each instance's worlds, mods, packs, shaders and logs
/// are on its own page), Settings.
struct RootView: View {
    @AppStorage("tab") private var tab = Tab.play
    @StateObject private var installer = Installer()
    @StateObject private var accounts = Accounts()
    @StateObject private var instances = Instances()

    var body: some View {
        TabView(selection: $tab) {
            LauncherView(installer: installer, accounts: accounts)
                .tabItem { Label("Play", systemImage: "play.fill") }
                .tag(Tab.play)
            InstancesView()
                .tabItem { Label("Instances", systemImage: "square.stack.3d.up.fill") }
                .tag(Tab.instances)
            SettingsView(accounts: accounts, installer: installer)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .environmentObject(instances)
    }
}
