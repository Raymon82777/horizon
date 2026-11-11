import SwiftUI

/// The launcher's Play tab: the game's files, the account, the selected instance, and Play
struct LauncherView: View {
    @EnvironmentObject private var instances: Instances
    @ObservedObject var installer: Installer
    @ObservedObject var accounts: Accounts
    @State private var launching = false
    @AppStorage("tab") private var tab = Tab.play
    /// A world's own Play button (on an instance's Worlds) asks for it here: straight into it.
    @AppStorage("quickPlay") private var quickPlay = ""

    var body: some View {
        HStack(spacing: 32) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Horizon")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                Text("Minecraft: Java Edition 26.3, in Rust")
                    .foregroundStyle(.secondary)
                status.padding(.top, 8)
                AccountView(accounts: accounts)
                    .padding(.top, 12)
                    .frame(maxWidth: 360, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 14) {
                Button { tab = .instances } label: {
                    HStack(spacing: 12) {
                        InstanceIcon(instance: instances.current, size: 40)
                        VStack(alignment: .leading) {
                            Text("Instance").font(.caption).foregroundStyle(.secondary)
                            Text(instances.current.name).font(.headline).foregroundStyle(.primary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Text("Opens the title screen: pick a world in Singleplayer, or join a server in Multiplayer. The game's own Options set render distance and everything else for this instance.")
                    .font(.caption).foregroundStyle(.secondary)
                Button { play() } label: {
                    Text("Play")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(installer.state != .ready || launching || accounts.busy)
            }
            .frame(width: 320)
        }
        .padding(32)
        .onAppear { installer.refresh() }
        .onAppear(perform: quickPlayIfAsked)
        .onChange(of: quickPlay) { quickPlayIfAsked() }
    }

    @ViewBuilder private var status: some View {
        switch installer.state {
        case .ready:
            Label("Resources ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .needsGame:
            Label("Minecraft 26.3 isn't installed", systemImage: "arrow.down.circle")
                .foregroundStyle(.orange)
            if let account = accounts.current {
                Button {
                    Task { await download(for: account) }
                } label: {
                    Label("Download Minecraft 26.3 (about 500 MB)", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                Text("From Mojang, for \(account.name), who owns the game. Wi-Fi recommended; keep Horizon open until it's done. It can stop and go on later.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Sign in with the Microsoft account that owns Minecraft: Java Edition to download it here, or copy versions/26.3 and assets/ into Horizon's minecraft folder in the Files app.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Check again") { installer.refresh() }
            }
        case .canAssemble:
            Label("Minecraft 26.3 found", systemImage: "shippingbox")
            Button("Build resources") { installer.assemble() }
                .buttonStyle(.bordered)
        case .assembling(let fraction):
            ProgressView(value: fraction) {
                Text("Building resources… \(Int(fraction * 100))%")
            }
            .frame(maxWidth: 360)
        case .downloading(let fraction, let step):
            ProgressView(value: fraction) {
                Text(step)
            } currentValueLabel: {
                Text("\(Int(fraction * 100))%")
            }
            .frame(maxWidth: 360)
        case .failed(let message):
            Label("Couldn't build resources", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
            // All of it, wrapped and selectable: the part that says why is often past a long path.
            Text(message).font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Button("Try again") { installer.refresh() }
        }
    }

    /// The owner gate: the Minecraft services are asked again before anything is downloaded.
    private func download(for account: Account) async {
        accounts.error = nil
        do {
            guard try await accounts.owns(account) else {
                accounts.error = "\(account.name) doesn't own Minecraft: Java Edition, so Horizon can't download it."
                return
            }
            installer.download()
        } catch {
            accounts.error = error.localizedDescription
        }
    }

    private func quickPlayIfAsked() {
        guard !quickPlay.isEmpty else { return }
        let world = quickPlay
        quickPlay = ""
        if installer.state == .ready, !launching { play(world: world) }
    }

    /// The title screen, or with `world` straight into that world (vanilla's quick play: only a
    /// world that exists).
    private func play(world: String? = nil) {
        // The instance's own folder; the resources are everyone's.
        let instance = instances.current
        var args = ["--resources", installer.resourcesDir.path,
                    "--home", instance.url.path, "--game-dir", instance.url.path]
        if let world { args += ["--quickPlaySingleplayer", world] }
        try? FileManager.default.createDirectory(at: instance.url, withIntermediateDirectories: true)
        instances.markPlayed()
        guard let account = accounts.current else {
            GameBridge.run(arguments: args)
            return
        }
        launching = true
        accounts.error = nil
        Task {
            defer { launching = false }
            do {
                let session = try await accounts.sessionFile(for: account)
                GameBridge.run(arguments: args + ["--session-file", session.path])
            } catch {
                accounts.error = error.localizedDescription
            }
        }
    }
}
