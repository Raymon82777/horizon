import SwiftUI
import UniformTypeIdentifiers

/// One instance's mods (on/off, update, remove), resource packs or shaders, or one world's data
/// packs, installed from Horizon's registry or Modrinth, or imported from the Files app. Shown on
/// the instance's page; `root` is the instance's folder (a world's folder for data packs).
struct PacksView: View {
    let root: URL
    let kind: RegistryKind
    @State private var items: [Item] = []
    @State private var enabled: Set<String> = []
    @State private var index: RegistryIndex?
    /// Newer 26.3 versions of Modrinth installs, by record key.
    @State private var modrinthUpdates: [String: Modrinth.Version] = [:]
    @State private var browsing = false
    @State private var browsingModrinth = false
    @State private var importing = false
    @State private var deleting: Item?
    @State private var busy: String?
    @State private var error: String?

    /// One installed file.
    struct Item: Identifiable, Hashable {
        let file: URL
        var id: URL { file }
        /// A mod's id (its manifest's), or the registry id that installed a pack.
        var modID: String?
        var name: String
        var version: String?
        var note: String?
        var registryID: String?
    }

    var body: some View {
            List {
                Section {
                    if kind.onModrinth {
                        Button {
                            browsingModrinth = true
                        } label: {
                            Label("Browse Modrinth", systemImage: "magnifyingglass")
                        }
                    }
                    Button {
                        browsing = true
                    } label: {
                        Label("Browse Horizon's registry", systemImage: kind.onModrinth ? "shippingbox" : "magnifyingglass")
                    }
                    let updates = items.filter { hasUpdate($0) }
                    if !updates.isEmpty {
                        Button {
                            Task { for item in updates { await update(item) } }
                        } label: {
                            Label("Update all (\(updates.count))", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(busy != nil)
                    }
                }
                Section {
                    if items.isEmpty {
                        Text("Nothing installed yet.").foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        row(item)
                    }
                } header: {
                    Text("Installed")
                } footer: {
                    Text(hint)
                }
                Section {
                    Button("Import from Files", systemImage: "square.and.arrow.down") { importing = true }
                }
            }
            .refreshable {
                await loadIndex(force: true)
                await checkModrinth()
            }
        .task(id: root) {
            await loadIndex(force: false)
            await checkModrinth()
        }
        .onAppear(perform: reload)
        .onChange(of: kind) { reload() }
        .onChange(of: root) { reload() }
        .sheet(isPresented: $browsing, onDismiss: reload) {
            RegistryBrowser(kind: kind, root: root, index: index)
        }
        .sheet(isPresented: $browsingModrinth, onDismiss: { reload(); Task { await checkModrinth() } }) {
            ModrinthBrowser(kind: kind, root: root)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: importTypes, allowsMultipleSelection: true) { result in
            do {
                for url in try result.get() { try importFile(url) }
            } catch { self.error = error.localizedDescription }
            reload()
        }
        .confirmationDialog(
            "Remove \(deleting?.name ?? "")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let item = deleting {
                    ModInstaller.remove(file: item.file, kind: kind, id: item.modID ?? item.registryID, root: root)
                }
                reload()
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private var hint: String {
        switch kind {
        case .mod: "Horizon content mods (.hmod): new blocks, items, recipes and more. Turned-on mods load when the game starts. Java mods (Fabric, Forge) and Horizon's native mods can't run on iPhone."
        case .resourcepack: "Turn packs on in the game: Options → Resource Packs."
        case .shader: "Horizon shader packs (.hshader). Pick one in the game's video settings."
        case .datapack: "This world's data packs. New ones turn on the next time the world opens; manage them in the game with /datapack. Horizon reads most of vanilla's data, so some packs may only partly work."
        }
    }

    private var importTypes: [UTType] {
        switch kind {
        case .mod: [.hmod]
        case .resourcepack: [.zip]
        case .shader: [.hshader, .zip]
        case .datapack: [.zip]
        }
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.headline)
                Text([item.version.map { "v\($0)" }, item.note].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(item.note?.hasPrefix("Taken down") == true ? .red : .secondary)
            }
            Spacer()
            if let newer = updateFor(item)?.version ?? item.registryID.flatMap({ modrinthUpdates[$0]?.versionNumber }) {
                Button("Update to \(newer)") { Task { await update(item) } }
                    .buttonStyle(.bordered)
                    .disabled(busy != nil)
            }
            if busy == item.registryID || (busy != nil && busy == item.modID) {
                ProgressView()
            }
            if kind == .mod, let id = item.modID {
                Toggle("On", isOn: Binding(
                    get: { enabled.contains(id) },
                    set: { on in
                        ModSwitches.set(id, on, root)
                        enabled = ModSwitches.enabled(root)
                    }))
                    .labelsHidden()
                    .disabled(item.note?.hasPrefix("Taken down") == true || item.note?.hasPrefix("Can't run") == true)
            }
        }
        .swipeActions {
            Button("Remove", systemImage: "trash", role: .destructive) { deleting = item }
        }
        .contextMenu {
            Button("Remove", systemImage: "trash", role: .destructive) { deleting = item }
        }
    }

    // MARK: Data

    private func reload() {
        let records = InstalledRecords.load(root)
        enabled = ModSwitches.enabled(root)
        items = GameFolders.entries(kind.folder(in: root))
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map { file in
                let record = records.first { $0.value.kind == kind.rawValue && $0.value.file == file.lastPathComponent }
                var item = Item(file: file, modID: nil, name: file.deletingPathExtension().lastPathComponent,
                                version: record?.value.version, note: nil, registryID: record?.key)
                if kind == .mod {
                    if let manifest = ModManifest.read(file) {
                        item.modID = manifest.id
                        item.name = manifest.name
                        item.version = manifest.version
                        if manifest.code == true { item.note = "Can't run on iPhone: it has code" }
                    } else if GameFolders.isDirectory(file) {
                        item.modID = file.lastPathComponent
                    }
                }
                if let record, record.value.fromModrinth {
                    item.name = record.value.title ?? item.name
                    item.note = "From Modrinth"
                } else if let record, let index, let reason = index.revocation(id: record.key, sha256: record.value.sha256) {
                    item.note = "Taken down: \(reason)"
                    if kind == .mod, let id = item.modID { ModSwitches.set(id, false, root) }
                } else if let project = registryProject(for: item) {
                    item.note = project.signed ? "From the registry, signed" : "From the registry"
                }
                return item
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        enabled = ModSwitches.enabled(root)
    }

    private func loadIndex(force: Bool) async {
        do {
            index = try await ModRegistry.load(force: force)
        } catch {
            if force { self.error = error.localizedDescription }
        }
        reload()
    }

    private func registryProject(for item: Item) -> RegistryProject? {
        guard let index, let id = item.registryID ?? item.modID else { return nil }
        return index.projects.first { $0.id == id && $0.kind == kind.rawValue }
    }

    /// A newer installable version than the installed one, for files the registry knows.
    private func updateFor(_ item: Item) -> RegistryVersion? {
        guard let index, let project = registryProject(for: item),
              let newest = ModRegistry.installable(project, in: index),
              let installed = item.version, newest.version != installed
        else { return nil }
        // Only something newer than what's installed counts.
        return newest.version.compare(installed, options: .numeric) == .orderedDescending ? newest : nil
    }

    private func hasUpdate(_ item: Item) -> Bool {
        updateFor(item) != nil || item.registryID.map { modrinthUpdates[$0] != nil } == true
    }

    /// Asks Modrinth, in one request, for newer 26.3 versions of what was installed from it.
    private func checkModrinth() async {
        guard kind.onModrinth else { return }
        let records = InstalledRecords.load(root).filter { $0.value.fromModrinth && $0.value.kind == kind.rawValue }
        let hashes = records.compactMap { $0.value.sha512 }
        guard let found = try? await Modrinth.updates(sha512: hashes, kind: kind) else { return }
        var updates: [String: Modrinth.Version] = [:]
        for (key, record) in records {
            if let sha = record.sha512, let newest = found[sha], newest.id != record.versionID {
                updates[key] = newest
            }
        }
        modrinthUpdates = updates
    }

    private func update(_ item: Item) async {
        if let key = item.registryID, let newer = modrinthUpdates[key] {
            busy = key
            defer { busy = nil }
            do {
                try await Modrinth.install(projectID: newer.projectID, title: item.name, newer, kind: kind, into: root)
                modrinthUpdates[key] = nil
            } catch { self.error = error.localizedDescription }
            reload()
            return
        }
        guard let project = registryProject(for: item), let index,
              let version = ModRegistry.installable(project, in: index) else { return }
        busy = project.id
        defer { busy = nil }
        do {
            let wasOn = item.modID.map { enabled.contains($0) } ?? true
            try await ModInstaller.install(project, version, into: root)
            if kind == .mod, !wasOn { ModSwitches.set(project.id, false, root) }
        } catch { self.error = error.localizedDescription }
        reload()
    }

    /// A file from the Files app: a mod is named after its manifest's id, as the game expects.
    private func importFile(_ source: URL) throws {
        if kind == .mod {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            guard let manifest = ModManifest.read(source) else {
                throw AuthError.message("\(source.lastPathComponent) isn't a Horizon content mod.")
            }
            let folder = kind.folder(in: root)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent("\(manifest.id).hmod")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
            ModSwitches.set(manifest.id, manifest.code != true, root)
        } else {
            _ = try GameFolders.importFile(source, into: kind.folder(in: root))
        }
    }
}

/// Horizon's registry, one kind at a time: search, a project's page, install.
struct RegistryBrowser: View {
    let kind: RegistryKind
    let root: URL
    @State var index: RegistryIndex?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var installing: String?
    @State private var installed: [String: InstalledRecord] = [:]
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if index == nil {
                    HStack { ProgressView(); Text("Reading the registry…") }
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
                ForEach(results) { project in
                    NavigationLink {
                        RegistryProjectPage(project: project, version: version(project), installed: installed[project.id],
                                            installing: installing == project.id) { install(project) }
                    } label: {
                        projectRow(project)
                    }
                }
            }
            .searchable(text: $query, prompt: "Search \(kind.title.lowercased())")
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task {
            installed = InstalledRecords.load(root)
            if index == nil {
                do { index = try await ModRegistry.load() } catch { self.error = error.localizedDescription }
            }
        }
        .alert("Couldn't install", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private var results: [RegistryProject] {
        guard let index else { return [] }
        let words = query.lowercased().split(separator: " ")
        return index.projects
            .filter { $0.kind == kind.rawValue && ModRegistry.installable($0, in: index) != nil }
            .filter { project in
                let text = "\(project.name) \(project.summary) \(project.id) \((project.authors ?? []).joined(separator: " "))".lowercased()
                return words.allSatisfy { text.contains($0) }
            }
            .sorted { ($0.downloads ?? 0) > ($1.downloads ?? 0) }
    }

    private func version(_ project: RegistryProject) -> RegistryVersion? {
        index.flatMap { ModRegistry.installable(project, in: $0) }
    }

    private func projectRow(_ project: RegistryProject) -> some View {
        HStack(spacing: 12) {
            ProjectIcon(url: project.icon, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(project.name).font(.headline)
                    if project.signed {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.caption)
                    }
                }
                Text(project.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text([(project.authors ?? []).joined(separator: ", "),
                      project.downloads.map { "\($0) downloads" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if installing == project.id {
                ProgressView()
            } else if let record = installed[project.id] {
                Text(record.version == version(project)?.version ? "Installed" : "Update")
                    .font(.caption.bold()).foregroundStyle(.green)
            } else {
                Button("Install") { install(project) }.buttonStyle(.bordered)
            }
        }
    }

    private func install(_ project: RegistryProject) {
        guard let version = version(project) else { return }
        installing = project.id
        Task {
            defer { installing = nil }
            do {
                try await ModInstaller.install(project, version, into: root)
                installed = InstalledRecords.load(root)
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// A registry project's page: description, details, install.
struct RegistryProjectPage: View {
    let project: RegistryProject
    let version: RegistryVersion?
    let installed: InstalledRecord?
    let installing: Bool
    let install: () -> Void

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    ProjectIcon(url: project.icon, size: 64)
                    VStack(alignment: .leading) {
                        Text(project.name).font(.title2.bold())
                        Text((project.authors ?? []).joined(separator: ", ")).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if installing {
                        ProgressView()
                    } else if let installed, installed.version == version?.version {
                        Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button(installed == nil ? "Install" : "Update", action: install).buttonStyle(.borderedProminent)
                    }
                }
                Text(project.summary)
            }
            if let description = project.description, !description.isEmpty {
                Section("About") {
                    Text((try? AttributedString(markdown: description,
                                                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                         ?? AttributedString(description))
                        .font(.callout)
                }
            }
            Section("Details") {
                if let version {
                    LabeledContent("Version", value: version.version)
                    LabeledContent("Size", value: GameFolders.format(version.file.size))
                    if let published = version.published { LabeledContent("Published", value: published) }
                }
                LabeledContent("Signed", value: project.signed ? "Yes, by its author" : "No (checked by its hash)")
                if let license = project.license { LabeledContent("License", value: license) }
                if let source = project.source.flatMap(URL.init(string:)) {
                    Link("Source code", destination: source)
                }
            }
            if let changelog = version?.changelog, !changelog.isEmpty {
                Section("What's new") { Text(changelog).font(.callout) }
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ProjectIcon: View {
    let url: String?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { image in
            image.resizable().interpolation(.none).scaledToFit()
        } placeholder: {
            Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: size * 0.2))
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
    }
}
