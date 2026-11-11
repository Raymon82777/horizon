import SwiftUI

/// The launcher: the game's resources (assembled on the device), world settings, and Play.
/// Signs in with Microsoft (Accounts); downloading the game comes next (ios/ROADMAP.md).
struct LauncherView: View {
    @AppStorage("world") private var world = "New World"
    @AppStorage("seed") private var seed = ""
    @AppStorage("renderDistance") private var renderDistance = 8.0
    @AppStorage("creative") private var creative = true
    @ObservedObject var installer: Installer
    @ObservedObject var accounts: Accounts
    @State private var launching = false
    @AppStorage("tab") private var tab = Tab.play

    private var worldExists: Bool {
        FileManager.default.fileExists(
            atPath: GameFolders.saves.appendingPathComponent(world).appendingPathComponent("level.dat").path)
    }

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
                if worldExists {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("World").font(.caption).foregroundStyle(.secondary)
                            Text(world).font(.headline)
                        }
                        Spacer()
                        Button("Change") { tab = .worlds }
                    }
                } else {
                    // A new world: its name, seed and mode apply once, when it's generated.
                    TextField("New world name", text: $world)
                        .textFieldStyle(.roundedBorder)
                    TextField("Seed (optional)", text: $seed)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Creative", isOn: $creative)
                }
                VStack(alignment: .leading) {
                    Text("Render distance: \(Int(renderDistance)) chunks")
                    Slider(value: $renderDistance, in: 2...32, step: 1)
                }
                Button(action: play) {
                    Text(worldExists ? "Play" : "Create & play")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(installer.state != .ready || launching || accounts.busy
                          || world.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .frame(width: 320)
        }
        .padding(32)
        .onAppear { installer.refresh() }
    }

    @ViewBuilder private var status: some View {
        switch installer.state {
        case .ready:
            Label("Resources ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .needsGame:
            Label("Minecraft 26.3 isn't installed", systemImage: "arrow.down.circle")
                .foregroundStyle(.orange)
            Text("For now, copy versions/26.3 and assets/ from a Minecraft folder into the app's Documents/minecraft (Files app or devicectl). Signing in and downloading comes next.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Check again") { installer.refresh() }
        case .canAssemble:
            Label("Minecraft 26.3 found", systemImage: "shippingbox")
            Button("Build resources") { installer.assemble() }
                .buttonStyle(.bordered)
        case .assembling(let fraction):
            ProgressView(value: fraction) {
                Text("Building resources… \(Int(fraction * 100))%")
            }
            .frame(maxWidth: 360)
        case .failed(let message):
            Label("Couldn't build resources", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
            Text(message).font(.footnote).foregroundStyle(.secondary)
            Button("Try again") { installer.refresh() }
        }
    }

    private func play() {
        var args = ["--resources", "resources", "--home", ".", "--game-dir", ".",
                    "--world", world, "--render-distance", String(Int(renderDistance))]
        if !worldExists {
            if !seed.isEmpty { args += ["--seed", seed] }
            if creative { args.append("--creative") }
        }
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
