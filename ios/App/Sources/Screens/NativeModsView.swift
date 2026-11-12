import SwiftUI

/// The native mods on an instance's page. Native mods are Rust patches to the game, so they're
/// compiled on the Mac, all of them into one game the instances share (ios/native-build.py);
/// each instance turns each one on or off with the game's own switch (`mod.<id>:false` in its
/// horizon-mods.txt, Options → Mods in the game). A mod added here takes effect after the next
/// Mac build; an instance with every native mod off plays the standard game.
struct NativeModsView: View {
    let instanceID: String
    @EnvironmentObject private var instances: Instances
    @ObservedObject private var mac = MacBuild.shared
    @Environment(\.openURL) private var openURL
    @State private var confirmingBuild = false
    @State private var index: RegistryIndex?
    @State private var browsing = false
    @State private var removing: NativeModChoice?

    private var instance: Instance? { instances.list.first { $0.id == instanceID } }
    private var mods: [NativeModChoice] { instances.nativeMods }

    /// What the shared framework says was built in and left out.
    private var built: (mods: [String], leftOut: [(String, String)])? {
        guard instances.nativeBuilt, !mods.isEmpty,
              let url = Bundle.main.privateFrameworksURL?
                .appendingPathComponent("\(instances.nativeGameName).framework/native-mods.json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let ids = (json["mods"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let left = (json["left_out"] as? [[String: Any]] ?? []).compactMap { entry -> (String, String)? in
            guard let id = entry["id"] as? String else { return nil }
            return (id, entry["why"] as? String ?? "")
        }
        return (ids, left)
    }

    var body: some View {
        List {
            Section {
                status
            }
            if !mods.isEmpty, !instances.nativeBuilt || mac.status != nil {
                macBuildSection
            }
            Section {
                if mods.isEmpty {
                    Text("No native mods yet.").foregroundStyle(.secondary)
                }
                ForEach(mods) { mod in
                    if let project = index?.projects.first(where: { $0.id == mod.id && $0.kind == "native-mod" }) {
                        NavigationLink {
                            RegistryProjectPage(project: project,
                                                version: project.versions.first { $0.version == mod.version },
                                                action: .none)
                        } label: {
                            modRow(mod)
                        }
                        .swipeActions {
                            Button("Remove", systemImage: "trash", role: .destructive) { removing = mod }
                        }
                    } else {
                        modRow(mod)
                            .swipeActions {
                                Button("Remove", systemImage: "trash", role: .destructive) { removing = mod }
                            }
                    }
                }
                Button("Add native mods", systemImage: "plus") { browsing = true }
            } header: {
                Text("Native mods, shared by every instance")
            } footer: {
                Text("They're compiled once, on your Mac, into a game every instance shares; the switches say which ones run in \(instance?.name ?? "this instance"). The same switches are in the game: Options → Mods. Native mods aren't sandboxed: add only mods you trust.")
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
            NativeModPicker(chosen: mods) { project, version in add(project, version) }
        }
        .confirmationDialog(
            "Remove \(removing?.name ?? "") from every instance?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let mod = removing { instances.removeNativeMod(mod.id) }
            }
        } message: {
            Text("To keep it but not run it here, turn its switch off instead.")
        }
        .alert("Build on your Mac?", isPresented: $confirmingBuild) {
            Button("Build") { Task { await mac.start(instances.nativeMods) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your Mac builds the native mods into a new copy of the app. Plugged in or on the Mac's network, it installs it and reopens Horizon; otherwise you install it from Safari. Native mods aren't sandboxed: build only mods you trust.")
        }
        .task {
            // The mods' pages.
            if index == nil { index = try? await ModRegistry.load() }
        }
        .task(id: mac.building) {
            // Follows the Mac while this page is open: every 5 seconds while a build runs, every
            // 30 otherwise, so a build started elsewhere (the Mac, another device) shows up too.
            guard MacBuild.base != nil else { return }
            await mac.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(mac.building ? 5 : 30))
                await mac.refresh()
            }
        }
    }

    private func modRow(_ mod: NativeModChoice) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(mod.name).font(.headline)
                HStack(spacing: 6) {
                    Text("v\(mod.version)").foregroundStyle(.secondary)
                    if let built {
                        if built.mods.contains(mod.id) {
                            Label("Built in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if built.leftOut.contains(where: { $0.0 == mod.id }) {
                            Label("Left out", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    } else {
                        Label("Not built yet", systemImage: "desktopcomputer").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
            }
            Spacer()
            if let instance {
                Toggle("On in \(instance.name)", isOn: Binding(
                    get: { !ModSwitches.disabled(instance.url).contains(mod.id) },
                    set: { instances.setNativeOn(mod.id, $0, in: instance) }))
                    .labelsHidden()
            }
        }
    }

    @ViewBuilder private var macBuildSection: some View {
        Section {
            if let host = MacBuild.host {
                switch mac.status?.state {
                case "building"?:
                    HStack(spacing: 10) {
                        ProgressView()
                        VStack(alignment: .leading) {
                            Text("Building on your Mac…")
                            if let step = mac.status?.step {
                                Text(step).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let last = mac.status?.log?.last {
                        Text(last).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(2)
                    }
                case "done"?:
                    if let warning = mac.status?.warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let device = mac.status?.installed {
                        Label("Installed on \(device)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if let install = mac.status?.install.flatMap(URL.init(string:)) {
                        Button("Install the new build", systemImage: "arrow.down.app") { openURL(install) }
                        Text("Opens Safari: tap Install there. Worlds and settings are kept.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Build again", systemImage: "hammer") { confirmingBuild = true }
                case "failed"?:
                    Label("The last build failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    ForEach(Array((mac.status?.log ?? []).suffix(4).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(3)
                    }
                    Button("Try again", systemImage: "hammer") { confirmingBuild = true }
                default:
                    Button("Build on my Mac", systemImage: "hammer") { confirmingBuild = true }
                }
                if let error = mac.error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                Text("Builds on \(host) \(mac.viaTailscale ? "over Tailscale" : "on this network"). On the Mac, ios/build-server.py --trust-native-code must be running.")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text("To build on your Mac, install the app from it once (ios/install.sh).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Remote build")
        }
    }

    @ViewBuilder private var status: some View {
        let on = instance.map { instances.nativeOn(in: $0) } ?? []
        if mods.isEmpty {
            Label("Plays the standard game", systemImage: "cube")
        } else if on.isEmpty {
            Label("Every native mod is off here: plays the standard game", systemImage: "cube")
        } else if instances.nativeBuilt {
            // Not the seal: that one means "signed by its author" in the mod lists.
            Label("Built into the app: plays with \(on.count == 1 ? on[0].name : "\(on.count) native mods")",
                  systemImage: "hammer.circle.fill")
                .foregroundStyle(.green)
        } else {
            Label("Waiting for a Mac build", systemImage: "desktopcomputer")
                .foregroundStyle(.orange)
            Text("Build them on your Mac below, or connect the phone and run ios/install.sh --native there. Until then the instances play without native mods.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func add(_ project: RegistryProject, _ version: RegistryVersion) {
        instances.addNativeMod(NativeModChoice(id: project.id, name: project.name, version: version.version,
                                               sha256: version.file.sha256))
    }
}

/// The registry's native mods, to add to the shared list.
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
                    NavigationLink {
                        RegistryProjectPage(project: project, version: version, action: action(project, version))
                    } label: {
                        row(project, version)
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

    private func action(_ project: RegistryProject, _ version: RegistryVersion) -> ProjectAction {
        if chosen.contains(where: { $0.id == project.id && $0.version == version.version }) {
            return .done("Added")
        }
        return .button(chosen.contains { $0.id == project.id } ? "Update" : "Add") { add(project, version) }
    }

    private func row(_ project: RegistryProject, _ version: RegistryVersion) -> some View {
        HStack(spacing: 12) {
            ProjectIcon(url: project.icon, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(project.name).font(.headline)
                    if project.signed {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.caption)
                            .accessibilityLabel("Signed by its author")
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
