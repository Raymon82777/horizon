import SwiftUI

/// An instance's native mods: Horizon's registry's native mods (Rust patches to the game, so
/// compiled on the Mac: ios/install.sh builds each instance's set into its own game framework).
/// Choosing here takes effect after the next Mac build; until then the instance plays without them.
struct NativeModsView: View {
    let instanceID: String
    @EnvironmentObject private var instances: Instances
    @State private var index: RegistryIndex?
    @State private var query = ""
    @State private var browsing = false
    @State private var error: String?

    private var instance: Instance? { instances.list.first { $0.id == instanceID } }
    private var chosen: [NativeModChoice] { instance?.nativeMods ?? [] }

    /// What the framework this instance plays says was built in and left out.
    private var built: (mods: [String], leftOut: [(String, String)])? {
        guard let instance, instance.gameBuilt, !chosen.isEmpty,
              let url = Bundle.main.privateFrameworksURL?
                .appendingPathComponent("\(instance.gameName).framework/native-mods.json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let mods = (json["mods"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let left = (json["left_out"] as? [[String: Any]] ?? []).compactMap { entry -> (String, String)? in
            guard let id = entry["id"] as? String else { return nil }
            return (id, entry["why"] as? String ?? "")
        }
        return (mods, left)
    }

    var body: some View {
        List {
            Section {
                status
            }
            Section {
                if chosen.isEmpty {
                    Text("None chosen.").foregroundStyle(.secondary)
                }
                ForEach(chosen) { mod in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(mod.name).font(.headline)
                            Text("v\(mod.version)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let built {
                            if built.mods.contains(mod.id) {
                                Label("Built in", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                            } else if let why = built.leftOut.first(where: { $0.0 == mod.id }) {
                                Label("Left out", systemImage: "exclamationmark.triangle.fill").font(.caption)
                                    .foregroundStyle(.orange).help(why.1)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Remove", systemImage: "trash", role: .destructive) { remove(mod) }
                    }
                }
                Button("Add native mods", systemImage: "plus") { browsing = true }
            } header: {
                Text("Chosen for this instance")
            } footer: {
                Text("Native mods change the game's code, so each instance's set is compiled into its own copy of the game on your Mac. They aren't sandboxed: add only mods you trust.")
            }
            if let built, !built.leftOut.isEmpty {
                Section("Left out of the last build") {
                    ForEach(built.leftOut, id: \.0) { id, why in
                        VStack(alignment: .leading) {
                            Text(id).font(.headline)
                            Text(why).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $browsing) {
            NativeModPicker(chosen: chosen) { project, version in add(project, version) }
        }
    }

    @ViewBuilder private var status: some View {
        if chosen.isEmpty {
            Label("Plays the standard game", systemImage: "cube")
        } else if instance?.gameBuilt == true {
            Label("Built into the app: plays with these mods", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        } else {
            Label("Waiting for a Mac build", systemImage: "desktopcomputer")
                .foregroundStyle(.orange)
            Text("Connect the phone to your Mac and run ios/install.sh --native there. Until then this instance plays without its native mods.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func add(_ project: RegistryProject, _ version: RegistryVersion) {
        guard var instance else { return }
        var mods = instance.nativeMods ?? []
        mods.removeAll { $0.id == project.id }
        mods.append(NativeModChoice(id: project.id, name: project.name, version: version.version,
                                    sha256: version.file.sha256))
        instance.nativeMods = mods
        instances.update(instance)
    }

    private func remove(_ mod: NativeModChoice) {
        guard var instance else { return }
        instance.nativeMods = (instance.nativeMods ?? []).filter { $0.id != mod.id }
        instances.update(instance)
    }
}

/// The registry's native mods, to add to an instance.
struct NativeModPicker: View {
    let chosen: [NativeModChoice]
    let add: (RegistryProject, RegistryVersion) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var index: RegistryIndex?
    @State private var query = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if index == nil && error == nil {
                    HStack { ProgressView(); Text("Reading the registry…") }
                }
                if let error { Text(error).foregroundStyle(.red) }
                ForEach(results, id: \.0.id) { project, version in
                    HStack(spacing: 12) {
                        ProjectIcon(url: project.icon, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(project.name).font(.headline)
                                if project.signed {
                                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.caption)
                                }
                            }
                            Text(project.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text("v\(version.version)" + (project.downloads.map { " · \($0) downloads" } ?? ""))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if chosen.contains(where: { $0.id == project.id && $0.version == version.version }) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button(chosen.contains { $0.id == project.id } ? "Update" : "Add") { add(project, version) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search native mods")
            .navigationTitle("Native mods")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task {
            do { index = try await ModRegistry.load() } catch { self.error = error.localizedDescription }
        }
    }

    private var results: [(RegistryProject, RegistryVersion)] {
        guard let index else { return [] }
        let words = query.lowercased().split(separator: " ")
        return index.projects
            .filter { $0.kind == "native-mod" }
            .compactMap { project -> (RegistryProject, RegistryVersion)? in
                guard let version = project.versions.first(where: {
                    $0.game == ModRegistry.game && index.revocation(id: project.id, sha256: $0.file.sha256) == nil
                }) else { return nil }
                return (project, version)
            }
            .filter { project, _ in
                let text = "\(project.name) \(project.summary) \(project.id)".lowercased()
                return words.allSatisfy { text.contains($0) }
            }
            .sorted { ($0.0.downloads ?? 0) > ($1.0.downloads ?? 0) }
    }
}
