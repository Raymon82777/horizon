import SwiftUI

/// Modrinth's resource packs or data packs: search, sort, a project's page, install into `root`
/// (an instance's folder, or a world's for data packs).
struct ModrinthBrowser: View {
    let kind: RegistryKind
    let root: URL
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @AppStorage("modrinthSort") private var sort = Modrinth.Sort.relevance
    /// Packs not marked for 26.3 too: many older resource packs still load.
    @AppStorage("modrinthEverything") private var everything = false
    @State private var hits: [Modrinth.Hit] = []
    @State private var loading = false
    @State private var more = true
    @State private var installing: String?
    @State private var installed: [String: InstalledRecord] = [:]
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(hits) { hit in
                    NavigationLink {
                        ModrinthProjectPage(hit: hit, kind: kind, root: root, everything: everything) {
                            installed = InstalledRecords.load(root)
                        }
                    } label: {
                        row(hit)
                    }
                    .onAppear { if hit == hits.last { Task { await load(reset: false) } } }
                }
                if loading {
                    HStack { ProgressView(); Text("Searching Modrinth…") }
                } else if hits.isEmpty {
                    ContentUnavailableView("Nothing found", systemImage: "magnifyingglass",
                                           description: Text(everything ? "Try other words."
                                               : "Try other words, or show packs made for other versions."))
                }
            }
            .searchable(text: $query, prompt: "Search Modrinth's \(kind.title.lowercased())")
            .navigationTitle("Modrinth · \(kind.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Menu {
                        Picker("Sort by", selection: $sort) {
                            ForEach(Modrinth.Sort.allCases) { Text($0.title).tag($0) }
                        }
                        Toggle("Show packs for other versions", isOn: $everything)
                    } label: {
                        Label("Sort and filter", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task { installed = InstalledRecords.load(root) }
        // A new search a moment after typing stops, or at once for a new sort or filter.
        .task(id: "\(query)|\(sort.rawValue)|\(everything)") {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await load(reset: true)
        }
        .alert("Couldn't reach Modrinth", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func row(_ hit: Modrinth.Hit) -> some View {
        HStack(spacing: 12) {
            ProjectIcon(url: hit.iconURL, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title).font(.headline)
                Text(hit.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text([hit.author, "\(hit.downloads.formatted(.number.notation(.compactName))) downloads",
                      hit.madeFor26 ? nil : "Not marked for \(ModRegistry.game)"]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if installed[Modrinth.recordKey(hit.projectID)] != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    private func load(reset: Bool) async {
        if loading || (!reset && !more) { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await Modrinth.search(query, kind: kind, sort: sort, everything: everything,
                                                 offset: reset ? 0 : hits.count)
            if reset { hits = page } else {
                let seen = Set(hits.map(\.id))
                hits += page.filter { !seen.contains($0.id) }
            }
            more = page.count == 30
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One Modrinth project: its description, pictures, the version Horizon would install.
struct ModrinthProjectPage: View {
    let hit: Modrinth.Hit
    let kind: RegistryKind
    let root: URL
    let everything: Bool
    let changed: () -> Void
    @State private var project: Modrinth.Project?
    @State private var versions: [Modrinth.Version]?
    @State private var installed: InstalledRecord?
    @State private var installing = false
    @State private var error: String?

    private var version: Modrinth.Version? { versions.flatMap { Modrinth.pick($0, everything: everything) } }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    ProjectIcon(url: hit.iconURL, size: 64)
                    VStack(alignment: .leading) {
                        Text(hit.title).font(.title2.bold())
                        if let author = hit.author { Text(author).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    action
                }
                Text(hit.description)
                if let note { Text(note).font(.footnote).foregroundStyle(.orange) }
            }
            if let gallery = project?.gallery, !gallery.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(gallery, id: \.self) { image in
                                AsyncImage(url: URL(string: image.url)) { $0.resizable().scaledToFill() } placeholder: {
                                    Color.secondary.opacity(0.2)
                                }
                                .frame(width: 240, height: 135)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
            }
            if let body = project?.body, !body.isEmpty {
                Section("About") {
                    Text((try? AttributedString(markdown: body,
                                                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                         ?? AttributedString(body))
                        .font(.callout)
                        .lineLimit(40)
                }
            }
            Section("Details") {
                if let version {
                    LabeledContent("Version", value: version.versionNumber)
                    LabeledContent("For Minecraft", value: version.gameVersions.suffix(4).joined(separator: ", "))
                    if let file = version.file { LabeledContent("Size", value: GameFolders.format(file.size)) }
                    LabeledContent("Published", value: String(version.datePublished.prefix(10)))
                }
                if let installed { LabeledContent("Installed", value: installed.version) }
                if let license = project?.license {
                    LabeledContent("License", value: license.name.flatMap { $0.isEmpty ? nil : $0 } ?? license.id)
                }
                if let url = URL(string: "\(Modrinth.site)/\(Modrinth.projectType(kind) ?? "project")/\(hit.slug)") {
                    Link("Open on Modrinth", destination: url)
                }
                if let source = project?.sourceURL.flatMap(URL.init(string:)) { Link("Source code", destination: source) }
            }
            if let changelog = version?.changelog, !changelog.isEmpty {
                Section("What's new") { Text(changelog).font(.callout).lineLimit(20) }
            }
        }
        .navigationTitle(hit.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert("Couldn't install", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    @ViewBuilder private var action: some View {
        if installing || versions == nil {
            ProgressView()
        } else if let version {
            if installed?.versionID == version.id {
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(installed == nil ? "Install" : "Update") { Task { await install(version) } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Why there's nothing to install, or a warning about what would be.
    private var note: String? {
        guard let versions else { return nil }
        guard let version else {
            return versions.isEmpty
                ? "This project has no \(kind == .datapack ? "data pack" : "resource pack") files."
                : "No version is marked for Minecraft \(ModRegistry.game). Turn on \"Show packs for other versions\" to install the newest anyway."
        }
        if !version.gameVersions.contains(ModRegistry.game) {
            return "Made for Minecraft \(version.gameVersions.last ?? "?"), not \(ModRegistry.game): it may load with missing or wrong parts."
        }
        return nil
    }

    private func load() async {
        installed = InstalledRecords.load(root)[Modrinth.recordKey(hit.projectID)]
        async let p = try? Modrinth.project(hit.projectID)
        do { versions = try await Modrinth.versions(hit.projectID, kind: kind) } catch {
            versions = []
            self.error = error.localizedDescription
        }
        project = await p
    }

    private func install(_ version: Modrinth.Version) async {
        installing = true
        defer { installing = false }
        do {
            try await Modrinth.install(projectID: hit.projectID, title: hit.title, version, kind: kind, into: root)
            installed = InstalledRecords.load(root)[Modrinth.recordKey(hit.projectID)]
            changed()
        } catch { self.error = error.localizedDescription }
    }
}
