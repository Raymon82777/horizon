import SwiftUI

/// The launcher: what is installed, and Play. Sign-in, downloading the game and assembling its
/// resources come in later milestones (ios/ROADMAP.md).
struct LauncherView: View {
    @AppStorage("world") private var world = "New World"
    @AppStorage("seed") private var seed = ""
    @AppStorage("renderDistance") private var renderDistance = 8.0
    @AppStorage("creative") private var creative = true
    @State private var resourcesReady = false

    var body: some View {
        HStack(spacing: 32) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Horizon")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                Text("Minecraft: Java Edition 26.3, in Rust")
                    .foregroundStyle(.secondary)
                Label(resourcesReady ? "Resources prepared" : "No resources in Documents/resources",
                      systemImage: resourcesReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(resourcesReady ? .green : .orange)
                    .padding(.top, 8)
                if !resourcesReady {
                    Text("Copy prepared resources into the app's Documents/resources (Files app or devicectl).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 14) {
                TextField("World", text: $world)
                    .textFieldStyle(.roundedBorder)
                TextField("Seed (optional)", text: $seed)
                    .textFieldStyle(.roundedBorder)
                Toggle("Creative", isOn: $creative)
                VStack(alignment: .leading) {
                    Text("Render distance: \(Int(renderDistance)) chunks")
                    Slider(value: $renderDistance, in: 2...32, step: 1)
                }
                Button(action: play) {
                    Text("Play")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!resourcesReady)
            }
            .frame(width: 320)
        }
        .padding(32)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        let stamp = GameBridge.documents.appendingPathComponent("resources/horizon-prepare.json")
        resourcesReady = FileManager.default.fileExists(atPath: stamp.path)
    }

    private func play() {
        var args = ["--resources", "resources", "--home", ".", "--game-dir", ".",
                    "--world", world, "--render-distance", String(Int(renderDistance))]
        if !seed.isEmpty { args += ["--seed", seed] }
        if creative { args.append("--creative") }
        GameBridge.run(arguments: args)
    }
}
