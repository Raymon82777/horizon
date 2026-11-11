import SwiftUI

/// Launcher settings: the account, the game's resources, storage, and about.
struct SettingsView: View {
    @ObservedObject var accounts: Accounts
    @ObservedObject var installer: Installer
    @State private var usage: [(String, Int64)] = []
    @State private var rebuilding = false
    @State private var editingTouch = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    AccountView(accounts: accounts)
                    if !accounts.list.isEmpty {
                        Button("Add another account", systemImage: "person.badge.plus") { accounts.signIn() }
                            .disabled(!AuthConfig.configured || accounts.busy)
                    }
                }
                Section {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Memory and entitlements", systemImage: "memorychip")
                    }
                } header: {
                    Text("Diagnostics")
                }
                Section {
                    Button("Edit touch layout", systemImage: "hand.tap") { editingTouch = true }
                } header: {
                    Text("Controls")
                } footer: {
                    Text("Move and resize the on-screen buttons, and set the look speed. The game picks it up the next time you press Play.")
                }
                Section {
                    LabeledContent("Minecraft", value: "Java Edition 26.3")
                    LabeledContent("Resources", value: installer.state == .ready ? "Ready" : "Not built")
                    Button("Rebuild resources", systemImage: "hammer") { rebuilding = true }
                        .disabled(!(installer.state == .ready || installer.state == .canAssemble))
                    if let account = accounts.current {
                        Button("Check and repair game files", systemImage: "checkmark.shield") {
                            Task {
                                if (try? await accounts.owns(account)) == true {
                                    installer.download(then: false)
                                } else {
                                    installer.lastDownload = "\(account.name) doesn't own Minecraft: Java Edition."
                                }
                            }
                        }
                        .disabled(isBusy)
                    }
                    if case .downloading(let fraction, let step) = installer.state {
                        ProgressView(value: fraction) { Text(step).font(.caption) }
                    } else if let note = installer.lastDownload {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Game")
                } footer: {
                    Text("Checking compares every Minecraft file with Mojang's list and downloads any that are missing or damaged. Rebuilding redoes the game's resources from those files in a few seconds. Worlds aren't touched.")
                }
                Section("Storage") {
                    ForEach(usage, id: \.0) { name, bytes in
                        LabeledContent(name, value: GameFolders.format(bytes))
                    }
                }
                Section {
                    LabeledContent("Horizon for iOS", value: Bundle.main.version)
                    Link("Horizon on GitHub", destination: URL(string: "https://github.com/horizon-rust/horizon")!)
                    Link("This fork", destination: URL(string: "https://github.com/Raymon82777/horizon-ios")!)
                } header: {
                    Text("About")
                } footer: {
                    Text("Every file the game uses is in the Files app: On My iPhone → Horizon.")
                }
            }
            .navigationTitle("Settings")
        }
        .onAppear(perform: measure)
        .fullScreenCover(isPresented: $editingTouch) { TouchLayoutEditor() }
        .confirmationDialog("Rebuild the game's resources?", isPresented: $rebuilding, titleVisibility: .visible) {
            Button("Rebuild") { installer.rebuild() }
        }
    }

    private var isBusy: Bool {
        switch installer.state {
        case .downloading, .assembling: true
        default: false
        }
    }

    private func measure() {
        DispatchQueue.global(qos: .utility).async {
            let folders: [(String, URL)] = [
                ("Default instance's worlds", GameBridge.documents.appendingPathComponent("saves")),
                ("Other instances", GameBridge.documents.appendingPathComponent("instances")),
                ("Minecraft files", GameBridge.documents.appendingPathComponent("minecraft")),
                ("Game resources", GameBridge.documents.appendingPathComponent("resources")),

            ]
            let result = folders.map { ($0.0, GameFolders.size($0.1)) }
            DispatchQueue.main.async { usage = result }
        }
    }
}

extension Bundle {
    var version: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
